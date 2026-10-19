//! CPU reference executor of a gpufx-nn package: plain f32 math, `C x H x W` tensors.
//!
//! This is the golden implementation that pins the semantics of every op in `docs/NN_MODEL_FORMAT.md`; the
//! WGSL runtime has to agree with it. It favours clarity over speed (output channels run on scoped threads).

use std::collections::HashMap;
use std::io::Read;
use std::path::Path;

use serde_json::Value;

use crate::{fail, Result};

/// A `C x H x W` f32 tensor, channel planes one after the other.
#[derive(Clone, Debug, PartialEq)]
pub struct Tensor {
    pub c: usize,
    pub h: usize,
    pub w: usize,
    pub data: Vec<f32>,
}

impl Tensor {
    pub fn new(c: usize, h: usize, w: usize, data: Vec<f32>) -> Self {
        assert_eq!(data.len(), c * h * w, "tensor data length does not match {c}x{h}x{w}");
        Tensor { c, h, w, data }
    }

    pub fn zeros(c: usize, h: usize, w: usize) -> Self {
        Tensor { c, h, w, data: vec![0.0; c * h * w] }
    }

    pub fn filled(c: usize, h: usize, w: usize, v: f32) -> Self {
        Tensor { c, h, w, data: vec![v; c * h * w] }
    }

    fn plane_len(&self) -> usize {
        self.h * self.w
    }

    fn same_shape(&self, o: &Tensor) -> bool {
        self.c == o.c && self.h == o.h && self.w == o.w
    }

    fn shape(&self) -> String {
        format!("{}x{}x{}", self.c, self.h, self.w)
    }
}

/// IEEE half to single precision.
pub fn f16_to_f32(h: u16) -> f32 {
    let sign = ((h >> 15) & 1) as u32;
    let exp = ((h >> 10) & 0x1f) as u32;
    let frac = (h & 0x3ff) as u32;
    let bits = if exp == 0 {
        if frac == 0 {
            sign << 31
        } else {
            // subnormal: normalise
            let mut e = 127 - 15 + 1;
            let mut f = frac;
            while f & 0x400 == 0 {
                f <<= 1;
                e -= 1;
            }
            (sign << 31) | ((e as u32) << 23) | ((f & 0x3ff) << 13)
        }
    } else if exp == 0x1f {
        (sign << 31) | (0xff << 23) | (frac << 13)
    } else {
        (sign << 31) | ((exp + 127 - 15) << 23) | (frac << 13)
    };
    f32::from_bits(bits)
}

#[derive(Clone, Copy, Debug)]
enum Act {
    Relu,
    Leaky(f32),
    Sigmoid,
}

impl Act {
    fn apply(self, x: f32) -> f32 {
        match self {
            Act::Relu => x.max(0.0),
            Act::Leaky(s) => {
                if x >= 0.0 {
                    x
                } else {
                    s * x
                }
            }
            Act::Sigmoid => 1.0 / (1.0 + (-x).exp()),
        }
    }
}

#[derive(Clone, Copy, Debug)]
enum BinKind {
    Add,
    Sub,
    Mul,
    Div,
    Max,
    Min,
    Pow,
    Rsub,
    Rdiv,
}

#[derive(Clone, Copy, Debug)]
enum EltKind {
    Prod,
    Sum,
    Max,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Mode {
    Nearest,
    Bilinear,
    Bicubic,
}

struct ConvOp {
    cin: usize,
    cout: usize,
    k: [usize; 2],
    stride: [usize; 2],
    dil: [usize; 2],
    /// top, left, bottom, right
    pad: [usize; 4],
    output_pad: [usize; 2],
    act: Option<Act>,
    /// `[out][in][kh][kw]`
    w: Vec<f32>,
    b: Vec<f32>,
}

enum Kind {
    Conv(ConvOp),
    Deconv(ConvOp),
    Activation(Act),
    Binary { kind: BinKind, scalar: Option<f32> },
    Eltwise { kind: EltKind, coeffs: Option<Vec<f32>> },
    Concat,
    Slice { start: usize, end: Option<usize> },
    Resize { mode: Mode, scale: Option<[f32; 2]>, size: Option<[usize; 2]>, align_corners: bool },
    PixelShuffle(usize),
    Warp,
    Prelu { slope: Vec<f32> },
    Clip { min: f32, max: f32 },
}

struct RefOp {
    name: String,
    inputs: Vec<String>,
    output: String,
    kind: Kind,
}

/// A loaded package ready to run.
pub struct Reference {
    pub name: String,
    pub inputs: Vec<String>,
    pub outputs: Vec<String>,
    /// `io.json` as given (null when the package has none).
    pub io: Value,
    ops: Vec<RefOp>,
}

fn get<'a>(v: &'a Value, key: &str) -> Result<&'a Value> {
    match v.get(key) {
        Some(x) => Ok(x),
        None => fail(format!("missing \"{key}\"")),
    }
}

fn num_array<const N: usize>(v: &Value, key: &str) -> Result<[f64; N]> {
    let a = get(v, key)?.as_array().filter(|a| a.len() == N);
    let Some(a) = a else { return fail(format!("\"{key}\" must be an array of {N} numbers")) };
    let mut out = [0.0; N];
    for (o, x) in out.iter_mut().zip(a) {
        match x.as_f64() {
            Some(f) => *o = f,
            None => return fail(format!("\"{key}\" must be an array of {N} numbers")),
        }
    }
    Ok(out)
}

fn usize_array<const N: usize>(v: &Value, key: &str) -> Result<[usize; N]> {
    Ok(num_array::<N>(v, key)?.map(|f| f as usize))
}

fn usize_of(v: &Value, key: &str) -> Result<usize> {
    match get(v, key)?.as_u64() {
        Some(n) => Ok(n as usize),
        None => fail(format!("\"{key}\" must be an unsigned integer")),
    }
}

fn parse_act_value(v: &Value) -> Result<Option<Act>> {
    if v.is_null() {
        return Ok(None);
    }
    let ty = get(v, "type")?.as_str().unwrap_or("");
    Ok(Some(match ty {
        "relu" => Act::Relu,
        "leaky_relu" => Act::Leaky(get(v, "slope")?.as_f64().unwrap_or(0.0) as f32),
        "sigmoid" => Act::Sigmoid,
        _ => return fail(format!("unknown activation \"{ty}\"")),
    }))
}

fn blob(v: &Value, weights: &[u8]) -> Result<Vec<f32>> {
    let offset = usize_of(v, "offset")?;
    let count = usize_of(v, "count")?;
    let dtype = get(v, "dtype")?.as_str().unwrap_or("");
    let size = match dtype {
        "f16" => 2,
        "f32" => 4,
        _ => return fail(format!("unknown dtype \"{dtype}\"")),
    };
    let Some(bytes) = weights.get(offset..).and_then(|b| b.get(..count * size)) else {
        return fail(format!("blob at {offset} of {count} {dtype} is outside weights.bin"));
    };
    Ok(if size == 2 {
        (0..count).map(|i| f16_to_f32(u16::from_le_bytes([bytes[i * 2], bytes[i * 2 + 1]]))).collect()
    } else {
        (0..count).map(|i| f32::from_le_bytes([bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], bytes[i * 4 + 3]])).collect()
    })
}

fn parse_conv(o: &Value, weights: &[u8], deconv: bool) -> Result<ConvOp> {
    let cin = usize_of(o, "in_channels")?;
    let cout = usize_of(o, "out_channels")?;
    let k = usize_array::<2>(o, "kernel")?;
    let w = blob(get(o, "weight")?, weights)?;
    if w.len() != cin * cout * k[0] * k[1] {
        return fail(format!("weight has {} elements, expected {}", w.len(), cin * cout * k[0] * k[1]));
    }
    let b = match o.get("bias") {
        Some(b) if !b.is_null() => blob(b, weights)?,
        _ => vec![0.0; cout],
    };
    if b.len() != cout {
        return fail(format!("bias has {} elements, expected {cout}", b.len()));
    }
    Ok(ConvOp {
        cin,
        cout,
        k,
        stride: usize_array::<2>(o, "stride")?,
        dil: usize_array::<2>(o, "dilation")?,
        pad: usize_array::<4>(o, "pad")?,
        output_pad: if deconv { usize_array::<2>(o, "output_pad")? } else { [0, 0] },
        act: parse_act_value(o.get("activation").unwrap_or(&Value::Null))?,
        w,
        b,
    })
}

fn parse_op(o: &Value, weights: &[u8]) -> Result<RefOp> {
    let kind_name = get(o, "op")?.as_str().unwrap_or("");
    let name = o.get("name").and_then(Value::as_str).unwrap_or("").to_string();
    let inputs: Vec<String> =
        get(o, "inputs")?.as_array().map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect()).unwrap_or_default();
    let output = get(o, "output")?.as_str().unwrap_or("").to_string();
    let kind = match kind_name {
        "conv2d" => Kind::Conv(parse_conv(o, weights, false)?),
        "deconv2d" => Kind::Deconv(parse_conv(o, weights, true)?),
        "activation" => match parse_act_value(o)? {
            Some(a) => Kind::Activation(a),
            None => return fail("activation without a type"),
        },
        "binary" => {
            let kind = match get(o, "kind")?.as_str().unwrap_or("") {
                "add" => BinKind::Add,
                "sub" => BinKind::Sub,
                "mul" => BinKind::Mul,
                "div" => BinKind::Div,
                "max" => BinKind::Max,
                "min" => BinKind::Min,
                "pow" => BinKind::Pow,
                "rsub" => BinKind::Rsub,
                "rdiv" => BinKind::Rdiv,
                k => return fail(format!("unknown binary kind \"{k}\"")),
            };
            let scalar = o.get("scalar").and_then(Value::as_f64).map(|f| f as f32);
            Kind::Binary { kind, scalar }
        }
        "eltwise" => {
            let kind = match get(o, "kind")?.as_str().unwrap_or("") {
                "prod" => EltKind::Prod,
                "sum" => EltKind::Sum,
                "max" => EltKind::Max,
                k => return fail(format!("unknown eltwise kind \"{k}\"")),
            };
            let coeffs =
                o.get("coeffs").and_then(Value::as_array).map(|a| a.iter().map(|c| c.as_f64().unwrap_or(0.0) as f32).collect::<Vec<_>>());
            Kind::Eltwise { kind, coeffs }
        }
        "concat" | "slice" => {
            if usize_of(o, "axis")? != 0 {
                return fail("only channel axis 0 is supported");
            }
            if kind_name == "concat" {
                Kind::Concat
            } else {
                let end = o.get("end").and_then(Value::as_u64).map(|e| e as usize);
                Kind::Slice { start: usize_of(o, "start")?, end }
            }
        }
        "resize" => {
            let mode = match get(o, "mode")?.as_str().unwrap_or("") {
                "nearest" => Mode::Nearest,
                "bilinear" => Mode::Bilinear,
                "bicubic" => Mode::Bicubic,
                m => return fail(format!("unknown resize mode \"{m}\"")),
            };
            let scale = match o.get("scale") {
                Some(s) if !s.is_null() => Some(num_array::<2>(o, "scale")?.map(|f| f as f32)),
                _ => None,
            };
            let size = match o.get("size") {
                Some(s) if !s.is_null() => Some(usize_array::<2>(o, "size")?),
                _ => None,
            };
            if scale.is_none() && size.is_none() {
                return fail("resize needs scale or size");
            }
            let align_corners = o.get("align_corners").and_then(Value::as_bool).unwrap_or(false);
            Kind::Resize { mode, scale, size, align_corners }
        }
        "pixel_shuffle" => Kind::PixelShuffle(usize_of(o, "factor")?),
        "warp" => Kind::Warp,
        "prelu" => Kind::Prelu { slope: blob(get(o, "slope")?, weights)? },
        "clip" => Kind::Clip {
            min: get(o, "min")?.as_f64().ok_or_else(|| crate::Error("\"min\" must be a number".into()))? as f32,
            max: get(o, "max")?.as_f64().ok_or_else(|| crate::Error("\"max\" must be a number".into()))? as f32,
        },
        k => return fail(format!("unknown op \"{k}\"")),
    };
    Ok(RefOp { name, inputs, output, kind })
}

impl Reference {
    /// Loads a single-model package from a directory or a `.zip`, or a bundle variant by `scale`.
    /// For a bundle, `scale` picks the variant; `None` on a bundle fails. For a single package, `scale`
    /// is ignored.
    pub fn load_variant(path: &Path, scale: Option<u64>) -> Result<Self> {
        if let Some(manifest) = crate::bundle::read_manifest(path)? {
            let variants =
                manifest.get("variants").and_then(Value::as_array).ok_or_else(|| crate::Error("bundle has no variants".into()))?;
            let want = scale.ok_or_else(|| crate::Error("the model is a bundle; a scale must be chosen".into()))?;
            let dir = variants
                .iter()
                .find(|v| v.get("scale").and_then(Value::as_u64) == Some(want))
                .and_then(|v| v.get("dir").and_then(Value::as_str))
                .ok_or_else(|| crate::Error(format!("bundle has no variant with scale {want}")))?;
            let files = crate::bundle::VariantFiles::load_from_bundle(path, dir)?;
            return Self::from_parts(&files.model_json, &files.weights, Some(&files.io_json));
        }
        Self::load(path)
    }

    /// Loads a single-model package from a directory or a `.zip`.
    pub fn load(path: &Path) -> Result<Self> {
        if path.is_dir() {
            let read = |n: &str| std::fs::read(path.join(n));
            let io = read("io.json").ok();
            return Self::from_parts(&read("model.json")?, &read("weights.bin")?, io.as_deref());
        }
        let mut zip = zip::ZipArchive::new(std::fs::File::open(path)?)?;
        let mut read = |n: &str| -> Result<Option<Vec<u8>>> {
            match zip.by_name(n) {
                Ok(mut f) => {
                    let mut v = Vec::new();
                    f.read_to_end(&mut v)?;
                    Ok(Some(v))
                }
                Err(zip::result::ZipError::FileNotFound) => Ok(None),
                Err(e) => Err(e.into()),
            }
        };
        let Some(model) = read("model.json")? else { return fail("package has no model.json") };
        let Some(weights) = read("weights.bin")? else { return fail("package has no weights.bin") };
        let io = read("io.json")?;
        Self::from_parts(&model, &weights, io.as_deref())
    }

    pub fn from_parts(model_json: &[u8], weights: &[u8], io_json: Option<&[u8]>) -> Result<Self> {
        let m: Value = serde_json::from_slice(model_json)?;
        if get(&m, "format")?.as_str() != Some("gpufx-nn") || get(&m, "version")?.as_u64() != Some(1) {
            return fail("not a gpufx-nn version 1 model");
        }
        let names = |key: &str| -> Result<Vec<String>> {
            Ok(get(&m, key)?.as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default())
        };
        let inputs = get(&m, "inputs")?
            .as_array()
            .map(|a| a.iter().filter_map(|x| x.get("name").and_then(Value::as_str).map(String::from)).collect())
            .unwrap_or_default();
        let mut ops = Vec::new();
        for o in get(&m, "ops")?.as_array().map(Vec::as_slice).unwrap_or_default() {
            let op = parse_op(o, weights).map_err(|e| crate::Error(format!("op {}: {e}", o["name"].as_str().unwrap_or("?"))))?;
            ops.push(op);
        }
        Ok(Reference {
            name: m["name"].as_str().unwrap_or("").to_string(),
            inputs,
            outputs: names("outputs")?,
            io: match io_json {
                Some(b) => serde_json::from_slice(b)?,
                None => Value::Null,
            },
            ops,
        })
    }

    /// Runs the graph. `inputs` must hold every input tensor by name; the result holds the model outputs.
    pub fn run(&self, inputs: HashMap<String, Tensor>) -> Result<HashMap<String, Tensor>> {
        let mut t = inputs;
        for n in &self.inputs {
            if !t.contains_key(n) {
                return fail(format!("missing input tensor \"{n}\""));
            }
        }
        for op in &self.ops {
            let mut args: Vec<&Tensor> = Vec::new();
            for i in &op.inputs {
                match t.get(i) {
                    Some(x) => args.push(x),
                    None => return fail(format!("op {}: tensor \"{i}\" does not exist", op.name)),
                }
            }
            let out = exec(&op.kind, &args).map_err(|e| crate::Error(format!("op {}: {e}", op.name)))?;
            t.insert(op.output.clone(), out);
        }
        let mut res = HashMap::new();
        for o in &self.outputs {
            match t.remove(o) {
                Some(x) => {
                    res.insert(o.clone(), x);
                }
                None => return fail(format!("output \"{o}\" was not produced")),
            }
        }
        Ok(res)
    }
}

/// Runs `f(channel, plane)` for every `plane`-sized chunk of `out` on scoped threads.
fn par_planes(out: &mut [f32], plane: usize, f: impl Fn(usize, &mut [f32]) + Sync) {
    if plane == 0 || out.is_empty() {
        return;
    }
    let n = out.len() / plane;
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).min(n);
    if threads <= 1 {
        for (i, p) in out.chunks_mut(plane).enumerate() {
            f(i, p);
        }
        return;
    }
    let mut groups: Vec<Vec<(usize, &mut [f32])>> = (0..threads).map(|_| Vec::new()).collect();
    for (i, p) in out.chunks_mut(plane).enumerate() {
        groups[i % threads].push((i, p));
    }
    std::thread::scope(|s| {
        for g in groups {
            let f = &f;
            s.spawn(move || {
                for (i, p) in g {
                    f(i, p);
                }
            });
        }
    });
}

fn one<'a>(args: &[&'a Tensor]) -> Result<&'a Tensor> {
    match args {
        [a] => Ok(a),
        _ => fail(format!("expected 1 input, got {}", args.len())),
    }
}

fn exec(kind: &Kind, args: &[&Tensor]) -> Result<Tensor> {
    match kind {
        Kind::Conv(c) => conv2d(one(args)?, c),
        Kind::Deconv(c) => deconv2d(one(args)?, c),
        Kind::Activation(a) => {
            let x = one(args)?;
            Ok(Tensor::new(x.c, x.h, x.w, x.data.iter().map(|&v| a.apply(v)).collect()))
        }
        Kind::Binary { kind, scalar } => binary(args, *kind, *scalar),
        Kind::Eltwise { kind, coeffs } => eltwise(args, *kind, coeffs.as_deref()),
        Kind::Concat => {
            let Some(first) = args.first() else { return fail("concat without inputs") };
            let mut data = Vec::new();
            let mut c = 0;
            for a in args {
                if a.h != first.h || a.w != first.w {
                    return fail(format!("concat of {} and {}", first.shape(), a.shape()));
                }
                c += a.c;
                data.extend_from_slice(&a.data);
            }
            Ok(Tensor::new(c, first.h, first.w, data))
        }
        Kind::Slice { start, end } => {
            let x = one(args)?;
            let end = end.unwrap_or(x.c);
            if *start >= end || end > x.c {
                return fail(format!("slice [{start}, {end}) of {} channels", x.c));
            }
            let p = x.plane_len();
            Ok(Tensor::new(end - start, x.h, x.w, x.data[start * p..end * p].to_vec()))
        }
        Kind::Resize { mode, scale, size, align_corners } => resize(one(args)?, *mode, *scale, *size, *align_corners),
        Kind::PixelShuffle(r) => pixel_shuffle(one(args)?, *r),
        Kind::Warp => match args {
            [image, flow] => warp(image, flow),
            _ => fail("warp needs [image, flow]"),
        },
        Kind::Prelu { slope } => prelu(one(args)?, slope),
        Kind::Clip { min, max } => {
            let x = one(args)?;
            Ok(Tensor::new(x.c, x.h, x.w, x.data.iter().map(|&v| v.clamp(*min, *max)).collect()))
        }
    }
}

/// ncnn PReLU: `y = x >= 0 ? x : slope[c] * x`, with a shared slope when `slope.len() == 1`.
fn prelu(x: &Tensor, slope: &[f32]) -> Result<Tensor> {
    if slope.len() != 1 && slope.len() != x.c {
        return fail(format!("prelu slope has {} values, expected 1 or {}", slope.len(), x.c));
    }
    let p = x.plane_len();
    let mut out = x.clone();
    for c in 0..x.c {
        let s = if slope.len() == 1 { slope[0] } else { slope[c] };
        for v in &mut out.data[c * p..(c + 1) * p] {
            if *v < 0.0 {
                *v *= s;
            }
        }
    }
    Ok(out)
}

fn conv_out(i: usize, pad_a: usize, pad_b: usize, k: usize, dil: usize, stride: usize) -> Result<usize> {
    let span = dil * (k - 1) + 1;
    if i + pad_a + pad_b < span {
        return fail("convolution input is smaller than the kernel");
    }
    Ok((i + pad_a + pad_b - span) / stride + 1)
}

fn conv2d(x: &Tensor, c: &ConvOp) -> Result<Tensor> {
    if x.c != c.cin {
        return fail(format!("conv2d expects {} channels, got {}", c.cin, x.shape()));
    }
    let [kh, kw] = c.k;
    let [sh, sw] = c.stride;
    let [dh, dw] = c.dil;
    let [pt, pl, pb, pr] = c.pad;
    let oh = conv_out(x.h, pt, pb, kh, dh, sh)?;
    let ow = conv_out(x.w, pl, pr, kw, dw, sw)?;
    let (ih, iw) = (x.h as isize, x.w as isize);
    let mut out = Tensor::zeros(c.cout, oh, ow);
    par_planes(&mut out.data, oh * ow, |o, plane| {
        plane.fill(c.b[o]);
        for q in 0..c.cin {
            let src = &x.data[q * x.h * x.w..(q + 1) * x.h * x.w];
            for ky in 0..kh {
                for kx in 0..kw {
                    let wv = c.w[((o * c.cin + q) * kh + ky) * kw + kx];
                    // input column of output column xo is xo * sw + off
                    let off = (kx * dw) as isize - pl as isize;
                    let x_lo = if off >= 0 { 0 } else { ((-off) as usize).div_ceil(sw) };
                    let t = iw - 1 - off;
                    let x_hi = if t < 0 { 0 } else { ((t as usize) / sw + 1).min(ow) };
                    if x_lo >= x_hi {
                        continue;
                    }
                    for y in 0..oh {
                        let iy = (y * sh + ky * dh) as isize - pt as isize;
                        if iy < 0 || iy >= ih {
                            continue;
                        }
                        let row = &src[iy as usize * x.w..(iy as usize + 1) * x.w];
                        let dst = &mut plane[y * ow + x_lo..y * ow + x_hi];
                        let start = (x_lo * sw) as isize + off;
                        if sw == 1 {
                            let s = &row[start as usize..start as usize + dst.len()];
                            for (d, v) in dst.iter_mut().zip(s) {
                                *d += wv * v;
                            }
                        } else {
                            for (n, d) in dst.iter_mut().enumerate() {
                                *d += wv * row[start as usize + n * sw];
                            }
                        }
                    }
                }
            }
        }
        if let Some(a) = c.act {
            for v in plane.iter_mut() {
                *v = a.apply(*v);
            }
        }
    });
    Ok(out)
}

fn deconv_out(i: usize, pad_a: usize, pad_b: usize, k: usize, dil: usize, stride: usize, out_pad: usize) -> Result<usize> {
    let full = (i - 1) * stride + dil * (k - 1) + out_pad + 1;
    if full <= pad_a + pad_b {
        return fail("deconvolution output is empty");
    }
    Ok(full - pad_a - pad_b)
}

fn deconv2d(x: &Tensor, c: &ConvOp) -> Result<Tensor> {
    if x.c != c.cin {
        return fail(format!("deconv2d expects {} channels, got {}", c.cin, x.shape()));
    }
    let [kh, kw] = c.k;
    let [sh, sw] = c.stride;
    let [dh, dw] = c.dil;
    let [pt, pl, pb, pr] = c.pad;
    let oh = deconv_out(x.h, pt, pb, kh, dh, sh, c.output_pad[0])?;
    let ow = deconv_out(x.w, pl, pr, kw, dw, sw, c.output_pad[1])?;
    let mut out = Tensor::zeros(c.cout, oh, ow);
    par_planes(&mut out.data, oh * ow, |o, plane| {
        plane.fill(c.b[o]);
        for q in 0..c.cin {
            let src = &x.data[q * x.h * x.w..(q + 1) * x.h * x.w];
            for ky in 0..kh {
                for kx in 0..kw {
                    let wv = c.w[((o * c.cin + q) * kh + ky) * kw + kx];
                    for i in 0..x.h {
                        let y = (i * sh + ky * dh) as isize - pt as isize;
                        if y < 0 || y >= oh as isize {
                            continue;
                        }
                        for j in 0..x.w {
                            let xo = (j * sw + kx * dw) as isize - pl as isize;
                            if xo < 0 || xo >= ow as isize {
                                continue;
                            }
                            plane[y as usize * ow + xo as usize] += src[i * x.w + j] * wv;
                        }
                    }
                }
            }
        }
        if let Some(a) = c.act {
            for v in plane.iter_mut() {
                *v = a.apply(*v);
            }
        }
    });
    Ok(out)
}

fn binary(args: &[&Tensor], kind: BinKind, scalar: Option<f32>) -> Result<Tensor> {
    let a = *args.first().ok_or_else(|| crate::Error("binary without inputs".into()))?;
    let f = |a: f32, b: f32| match kind {
        BinKind::Add => a + b,
        BinKind::Sub => a - b,
        BinKind::Mul => a * b,
        BinKind::Div => a / b,
        BinKind::Max => a.max(b),
        BinKind::Min => a.min(b),
        BinKind::Pow => a.powf(b),
        BinKind::Rsub => b - a,
        BinKind::Rdiv => b / a,
    };
    match (scalar, args.len()) {
        (Some(s), 1) => Ok(Tensor::new(a.c, a.h, a.w, a.data.iter().map(|&v| f(v, s)).collect())),
        (None, 2) => {
            let b = args[1];
            // numpy style broadcast: a dimension of size 1 is repeated
            let dim = |x: usize, y: usize| {
                if x == y || y == 1 {
                    Some(x)
                } else if x == 1 {
                    Some(y)
                } else {
                    None
                }
            };
            let (Some(c), Some(h), Some(w)) = (dim(a.c, b.c), dim(a.h, b.h), dim(a.w, b.w)) else {
                return fail(format!("binary of {} and {}", a.shape(), b.shape()));
            };
            let at = |t: &Tensor, ci: usize, y: usize, x: usize| t.data[((ci % t.c) * t.h + y % t.h) * t.w + x % t.w];
            let mut data = Vec::with_capacity(c * h * w);
            for ci in 0..c {
                for y in 0..h {
                    for x in 0..w {
                        data.push(f(at(a, ci, y, x), at(b, ci, y, x)));
                    }
                }
            }
            Ok(Tensor::new(c, h, w, data))
        }
        _ => fail("binary takes one input with a scalar, or two inputs without"),
    }
}

fn eltwise(args: &[&Tensor], kind: EltKind, coeffs: Option<&[f32]>) -> Result<Tensor> {
    let a = *args.first().ok_or_else(|| crate::Error("eltwise without inputs".into()))?;
    if args.iter().any(|t| !t.same_shape(a)) {
        return fail("eltwise inputs differ in shape");
    }
    if let Some(c) = coeffs {
        if c.len() != args.len() {
            return fail("eltwise coeffs and inputs differ in count");
        }
    }
    let mut data = Vec::with_capacity(a.data.len());
    for i in 0..a.data.len() {
        let v = match kind {
            EltKind::Prod => args.iter().map(|t| t.data[i]).product(),
            EltKind::Sum => args.iter().enumerate().map(|(n, t)| t.data[i] * coeffs.map_or(1.0, |c| c[n])).sum(),
            EltKind::Max => args.iter().map(|t| t.data[i]).fold(f32::NEG_INFINITY, f32::max),
        };
        data.push(v);
    }
    Ok(Tensor::new(a.c, a.h, a.w, data))
}

/// Taps of one output coordinate along one axis: up to 4 source indices with weights (unused taps weigh 0).
#[derive(Clone, Copy)]
struct Taps {
    idx: [usize; 4],
    wt: [f32; 4],
}

fn axis_taps(mode: Mode, i: usize, o: usize, scale: Option<f32>, align_corners: bool) -> Vec<Taps> {
    const A: f32 = -0.75;
    let max = i - 1;
    (0..o)
        .map(|d| {
            let mut t = Taps { idx: [0; 4], wt: [0.0; 4] };
            if mode == Mode::Nearest {
                let s = if align_corners {
                    if o > 1 {
                        (d as f32 * max as f32 / (o - 1) as f32).round() as usize
                    } else {
                        0
                    }
                } else {
                    let ratio = scale.unwrap_or(o as f32 / i as f32);
                    (d as f32 / ratio).floor() as usize
                };
                t.idx[0] = s.min(max);
                t.wt[0] = 1.0;
                return t;
            }
            let src = if align_corners {
                if o > 1 {
                    d as f32 * max as f32 / (o - 1) as f32
                } else {
                    0.0
                }
            } else {
                (d as f32 + 0.5) * (i as f32 / o as f32) - 0.5
            };
            if mode == Mode::Bilinear {
                let s = src.clamp(0.0, max as f32);
                let mut x0 = s.floor() as usize;
                let mut f = s - x0 as f32;
                if x0 >= max {
                    x0 = max;
                    f = 0.0;
                }
                t.idx = [x0, (x0 + 1).min(max), 0, 0];
                t.wt = [1.0 - f, f, 0.0, 0.0];
            } else {
                let fl = src.floor();
                let f = src - fl;
                let clamp = |v: f32| v.clamp(0.0, max as f32) as usize;
                t.idx = [clamp(fl - 1.0), clamp(fl), clamp(fl + 1.0), clamp(fl + 2.0)];
                let c0 = ((A * (f + 1.0) - 5.0 * A) * (f + 1.0) + 8.0 * A) * (f + 1.0) - 4.0 * A;
                let c1 = ((A + 2.0) * f - (A + 3.0)) * f * f + 1.0;
                let g = 1.0 - f;
                let c2 = ((A + 2.0) * g - (A + 3.0)) * g * g + 1.0;
                t.wt = [c0, c1, c2, 1.0 - c0 - c1 - c2];
            }
            t
        })
        .collect()
}

fn resize(x: &Tensor, mode: Mode, scale: Option<[f32; 2]>, size: Option<[usize; 2]>, align_corners: bool) -> Result<Tensor> {
    let (oh, ow) = match (size, scale) {
        (Some([h, w]), _) => (h, w),
        (None, Some([sh, sw])) => ((x.h as f32 * sh).floor() as usize, (x.w as f32 * sw).floor() as usize),
        _ => return fail("resize needs scale or size"),
    };
    if oh == 0 || ow == 0 || x.h == 0 || x.w == 0 {
        return fail("resize to or from an empty image");
    }
    // nearest uses the user scale when given (floor(dst / scale)), else the real ratio
    let (sy, sx) = match (size, scale) {
        (None, Some([sh, sw])) => (Some(sh), Some(sw)),
        _ => (None, None),
    };
    let ty = axis_taps(mode, x.h, oh, sy, align_corners);
    let tx = axis_taps(mode, x.w, ow, sx, align_corners);
    let mut out = Tensor::zeros(x.c, oh, ow);
    par_planes(&mut out.data, oh * ow, |c, plane| {
        let src = &x.data[c * x.h * x.w..(c + 1) * x.h * x.w];
        for (y, a) in ty.iter().enumerate() {
            for (xo, b) in tx.iter().enumerate() {
                let mut acc = 0.0;
                for i in 0..4 {
                    if a.wt[i] == 0.0 {
                        continue;
                    }
                    let mut row = 0.0;
                    for j in 0..4 {
                        if b.wt[j] != 0.0 {
                            row += b.wt[j] * src[a.idx[i] * x.w + b.idx[j]];
                        }
                    }
                    acc += a.wt[i] * row;
                }
                plane[y * ow + xo] = acc;
            }
        }
    });
    Ok(out)
}

fn pixel_shuffle(x: &Tensor, r: usize) -> Result<Tensor> {
    if r == 0 || x.c / (r * r) * (r * r) != x.c {
        return fail(format!("pixel_shuffle factor {r} does not divide {} channels", x.c));
    }
    let oc = x.c / (r * r);
    let (oh, ow) = (x.h * r, x.w * r);
    let mut out = Tensor::zeros(oc, oh, ow);
    for c in 0..oc {
        for i in 0..r {
            for j in 0..r {
                let src = &x.data[(c * r * r + i * r + j) * x.h * x.w..][..x.h * x.w];
                for y in 0..x.h {
                    for xx in 0..x.w {
                        out.data[c * oh * ow + (y * r + i) * ow + xx * r + j] = src[y * x.w + xx];
                    }
                }
            }
        }
    }
    Ok(out)
}

/// RIFE warp, exactly the ncnn `warp.comp` shader.
fn warp(image: &Tensor, flow: &Tensor) -> Result<Tensor> {
    if flow.c < 2 || flow.h != image.h || flow.w != image.w {
        return fail(format!("warp of image {} with flow {}", image.shape(), flow.shape()));
    }
    let (w, h) = (image.w as i32, image.h as i32);
    let p = image.plane_len();
    let mut out = Tensor::zeros(image.c, image.h, image.w);
    par_planes(&mut out.data, p, |c, plane| {
        let img = &image.data[c * p..(c + 1) * p];
        for gy in 0..h {
            for gx in 0..w {
                let i = (gy * w + gx) as usize;
                let sx = gx as f32 + flow.data[i];
                let sy = gy as f32 + flow.data[p + i];
                let x0 = (sx.floor() as i32).clamp(0, w - 1);
                let y0 = (sy.floor() as i32).clamp(0, h - 1);
                let x1 = (sx.floor() as i32 + 1).clamp(0, w - 1);
                let y1 = (sy.floor() as i32 + 1).clamp(0, h - 1);
                let alpha = sx - x0 as f32;
                let beta = sy - y0 as f32;
                let at = |y: i32, x: i32| img[(y * w + x) as usize];
                let v4 = at(y0, x0) * (1.0 - alpha) + at(y0, x1) * alpha;
                let v5 = at(y1, x0) * (1.0 - alpha) + at(y1, x1) * alpha;
                plane[i] = v4 * (1.0 - beta) + v5 * beta;
            }
        }
    });
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn t(c: usize, h: usize, w: usize, d: &[f32]) -> Tensor {
        Tensor::new(c, h, w, d.to_vec())
    }

    #[allow(clippy::too_many_arguments)]
    fn conv(cin: usize, cout: usize, k: [usize; 2], stride: usize, pad: [usize; 4], w: &[f32], b: &[f32], act: Option<Act>) -> ConvOp {
        ConvOp { cin, cout, k, stride: [stride; 2], dil: [1, 1], pad, output_pad: [0, 0], act, w: w.to_vec(), b: b.to_vec() }
    }

    #[test]
    fn f16_decoding() {
        assert_eq!(f16_to_f32(0x3c00), 1.0);
        assert_eq!(f16_to_f32(0xc000), -2.0);
        assert_eq!(f16_to_f32(0x0000), 0.0);
        assert!(f16_to_f32(0x8000).is_sign_negative());
        assert_eq!(f16_to_f32(0x7bff), 65504.0);
        assert_eq!(f16_to_f32(0x0001), 2.0f32.powi(-24));
        assert_eq!(f16_to_f32(0x03ff), 1023.0 * 2.0f32.powi(-24));
        assert_eq!(f16_to_f32(0x0400), 2.0f32.powi(-14));
        assert_eq!(f16_to_f32(0x7c00), f32::INFINITY);
        assert!(f16_to_f32(0x7e00).is_nan());
        assert_eq!(f16_to_f32(0x3555), 0.333_251_95);
    }

    #[test]
    fn conv_3x3_pad1() {
        let x = t(1, 3, 3, &[1., 2., 3., 4., 5., 6., 7., 8., 9.]);
        let c = conv(1, 1, [3, 3], 1, [1; 4], &[1.0; 9], &[0.5], None);
        let y = conv2d(&x, &c).unwrap();
        assert_eq!((y.h, y.w), (3, 3));
        // corner 1+2+4+5, top edge 1+2+3+4+5+6, left edge 1+2+4+5+7+8, centre 45
        assert_eq!(y.data, [12.5, 21.5, 16.5, 27.5, 45.5, 33.5, 24.5, 39.5, 28.5]);
    }

    #[test]
    fn conv_stride2_asymmetric_pad_relu_and_layout() {
        // 4x4 ramp, 2x2 kernel [1,0;0,-1] stride 2, no pad -> x[2i][2j] - x[2i+1][2j+1]
        let d: Vec<f32> = (0..16).map(|v| v as f32).collect();
        let x = t(1, 4, 4, &d);
        let c = conv(1, 1, [2, 2], 2, [0; 4], &[1., 0., 0., -1.], &[0.0], Some(Act::Relu));
        let y = conv2d(&x, &c).unwrap();
        assert_eq!(y.data, [0.0; 4]); // -5 each, relu -> 0
        let c = conv(1, 1, [2, 2], 2, [0; 4], &[-1., 0., 0., 1.], &[0.0], None);
        assert_eq!(conv2d(&x, &c).unwrap().data, [5.0; 4]);
        // pad [top, left, bottom, right] = [1,0,0,0] on 2x2 input, 1x1 kernel: output 3x2 with a zero first row
        let c = conv(1, 1, [1, 1], 1, [1, 0, 0, 0], &[2.0], &[1.0], None);
        let y = conv2d(&t(1, 2, 2, &[1., 2., 3., 4.]), &c).unwrap();
        assert_eq!((y.h, y.w), (3, 2));
        assert_eq!(y.data, [1., 1., 3., 5., 7., 9.]);
        // weight layout [out][in]: out0 = 10*in0 + 20*in1, out1 = 30*in0 + 40*in1
        let c = conv(2, 2, [1, 1], 1, [0; 4], &[10., 20., 30., 40.], &[0., 0.], None);
        let y = conv2d(&t(2, 1, 1, &[1., 2.]), &c).unwrap();
        assert_eq!(y.data, [50., 110.]);
    }

    fn deconv(cin: usize, cout: usize, k: usize, stride: usize, pad: usize, w: &[f32], b: &[f32]) -> ConvOp {
        let mut c = conv(cin, cout, [k, k], stride, [pad; 4], w, b, None);
        c.output_pad = [0, 0];
        c
    }

    #[test]
    fn deconv_stride2_k4_p1() {
        // 1x1 input, weights 0..16: output 2x2 is the kernel taps (1,1) (1,2) (2,1) (2,2)
        let w: Vec<f32> = (0..16).map(|v| v as f32).collect();
        let y = deconv2d(&t(1, 1, 1, &[1.0]), &deconv(1, 1, 4, 2, 1, &w, &[0.0])).unwrap();
        assert_eq!((y.h, y.w), (2, 2));
        assert_eq!(y.data, [5., 6., 9., 10.]);
        // 2x2 input, all-ones kernel: output 4x4. Output row o = 2i + ky - 1 with ky in 0..4 takes the input
        // rows {0} {0,1} {0,1} {1} for o = 0..4 (same for columns); every tap weighs 1.
        let x = t(1, 2, 2, &[1., 2., 3., 4.]);
        let y = deconv2d(&x, &deconv(1, 1, 4, 2, 1, &[1.0; 16], &[0.5])).unwrap();
        assert_eq!((y.h, y.w), (4, 4));
        let d = &x.data;
        let sets: [&[usize]; 4] = [&[0], &[0, 1], &[0, 1], &[1]];
        let mut want = Vec::new();
        for rs in sets {
            for cs in sets {
                want.push(0.5 + rs.iter().flat_map(|&i| cs.iter().map(move |&j| d[i * 2 + j])).sum::<f32>());
            }
        }
        assert_eq!(y.data, want);
        assert_eq!(y.data[0], 1.5);
        assert_eq!(y.data[10], 10.5); // (2,2) = 1+2+3+4
        assert_eq!(y.data[15], 4.5);
    }

    #[test]
    fn deconv_weight_layout_is_out_in() {
        // 1x1 kernel, in=2 out=1: out = 1*in0 + 2*in1  ([out][in])
        let y = deconv2d(&t(2, 1, 1, &[10., 100.]), &deconv(2, 1, 1, 1, 0, &[1., 2.], &[0.])).unwrap();
        assert_eq!(y.data, [210.0]);
        // in=1 out=2: out0 = 1*in, out1 = 2*in
        let y = deconv2d(&t(1, 1, 1, &[10.]), &deconv(1, 2, 1, 1, 0, &[1., 2.], &[0., 0.])).unwrap();
        assert_eq!(y.data, [10., 20.]);
    }

    #[test]
    fn resize_bilinear_up_and_down() {
        let up = resize(&t(1, 1, 2, &[0., 1.]), Mode::Bilinear, Some([2.0, 2.0]), None, false).unwrap();
        assert_eq!((up.h, up.w), (2, 4));
        assert_eq!(up.data, [0., 0.25, 0.75, 1., 0., 0.25, 0.75, 1.]);
        let down = resize(&t(1, 1, 4, &[0., 1., 2., 3.]), Mode::Bilinear, Some([1.0, 0.5]), None, false).unwrap();
        assert_eq!(down.data, [0.5, 2.5]);
        // size form, align corners: 0..3 -> 7 samples
        let ac = resize(&t(1, 1, 4, &[0., 3., 6., 9.]), Mode::Bilinear, None, Some([1, 7]), true).unwrap();
        for (i, v) in ac.data.iter().enumerate() {
            assert!((v - 1.5 * i as f32).abs() < 1e-6, "{:?}", ac.data);
        }
        // the ratio is in / out, not 1 / scale: 5 * 0.5 floors to 2, src = (d + .5) * 2.5 - .5
        let odd = resize(&t(1, 1, 5, &[0., 1., 2., 3., 4.]), Mode::Bilinear, Some([1.0, 0.5]), None, false).unwrap();
        assert_eq!(odd.data, [0.75, 3.25]);
    }

    #[test]
    fn resize_nearest() {
        let up = resize(&t(1, 1, 2, &[5., 7.]), Mode::Nearest, Some([1.0, 2.0]), None, false).unwrap();
        assert_eq!(up.data, [5., 5., 7., 7.]);
        let down = resize(&t(1, 1, 4, &[1., 2., 3., 4.]), Mode::Nearest, Some([1.0, 0.5]), None, false).unwrap();
        assert_eq!(down.data, [1., 3.]);
    }

    #[test]
    fn pixel_shuffle_order() {
        let y = pixel_shuffle(&t(4, 1, 1, &[0., 1., 2., 3.]), 2).unwrap();
        assert_eq!((y.c, y.h, y.w), (1, 2, 2));
        assert_eq!(y.data, [0., 1., 2., 3.]);
        // 2 output channels, 1x2 input: channel c uses inputs c*4 + i*2 + j
        let d: Vec<f32> = (0..16).map(|v| v as f32).collect();
        let y = pixel_shuffle(&t(8, 1, 2, &d), 2).unwrap();
        assert_eq!((y.c, y.h, y.w), (2, 2, 4));
        // c0: i=0,j=0 -> in ch 0 = [0,1]; i=0,j=1 -> ch 1 = [2,3]; i=1,j=0 -> ch 2 = [4,5]; i=1,j=1 -> ch 3 = [6,7]
        assert_eq!(&y.data[..8], [0., 2., 1., 3., 4., 6., 5., 7.]);
    }

    #[test]
    fn prelu_per_channel_and_shared() {
        // two channels, per-channel slopes 0.1 and 0.5; positives pass through
        let x = t(2, 1, 2, &[-2., 3., -4., 5.]);
        let y = prelu(&x, &[0.1, 0.5]).unwrap();
        assert_eq!(y.data, [-0.2, 3.0, -2.0, 5.0]);
        // a shared slope applies to every channel
        let y = prelu(&x, &[0.25]).unwrap();
        assert_eq!(y.data, [-0.5, 3.0, -1.0, 5.0]);
        // a slope count that is neither 1 nor the channel count fails
        assert!(prelu(&x, &[0.1, 0.2, 0.3]).is_err());
        // exec path
        let out = exec(&Kind::Prelu { slope: vec![0.5] }, &[&x]).unwrap();
        assert_eq!(out.data, [-1.0, 3.0, -2.0, 5.0]);
    }

    #[test]
    fn clip_min_max() {
        let x = t(1, 1, 4, &[-1., 0.25, 0.5, 2.]);
        let y = exec(&Kind::Clip { min: 0.0, max: 1.0 }, &[&x]).unwrap();
        assert_eq!(y.data, [0.0, 0.25, 0.5, 1.0]);
    }

    #[test]
    fn resize_bicubic_scale_matches_ncnn() {
        // bicubic upscale of a 1x4 row by 2x; ncnn A = -0.75, half-pixel centres, border clamped.
        let x = t(1, 1, 4, &[0., 1., 2., 3.]);
        let up = resize(&x, Mode::Bicubic, Some([1.0, 2.0]), None, false).unwrap();
        assert_eq!((up.h, up.w), (1, 8));
        // reference values computed from the ncnn bicubic coefficient formula
        let want = [-0.10546875, 0.19140625, 0.66796875, 1.296875, 1.703125, 2.3320313, 2.8085938, 3.1054688];
        for (g, w) in up.data.iter().zip(want) {
            assert!((g - w).abs() < 1e-4, "{:?}", up.data);
        }
        // bicubic downscale by 0.5 (as the animevideov3 x2 tail does); ratio is in/out, not 1/scale
        let down = resize(&x, Mode::Bicubic, Some([1.0, 0.5]), None, false).unwrap();
        assert_eq!((down.h, down.w), (1, 2));
        let want = [0.40625, 2.59375];
        for (g, w) in down.data.iter().zip(want) {
            assert!((g - w).abs() < 1e-4, "{:?}", down.data);
        }
    }

    #[test]
    fn warp_fractional_and_out_of_range() {
        let img = t(1, 2, 2, &[0., 1., 2., 3.]);
        // fx = 0.5, fy = 0
        let flow = t(2, 2, 2, &[0.5, 0.5, 0.5, 0.5, 0., 0., 0., 0.]);
        assert_eq!(warp(&img, &flow).unwrap().data, [0.5, 1.0, 2.5, 3.0]);
        // fx = 0, fy = 0.25: (0,0) -> 0.5, (1,0) -> 1.5, bottom row clamps to itself
        let flow = t(2, 2, 2, &[0., 0., 0., 0., 0.25, 0.25, 0.25, 0.25]);
        assert_eq!(warp(&img, &flow).unwrap().data, [0.5, 1.5, 2.0, 3.0]);
        // far outside: clamp to the edge pixel
        let flow = t(2, 2, 2, &[-5., -5., -5., -5., -7., -7., -7., -7.]);
        assert_eq!(warp(&img, &flow).unwrap().data, [0.0; 4]);
        let flow = t(2, 2, 2, &[9., 9., 9., 9., 9., 9., 9., 9.]);
        assert_eq!(warp(&img, &flow).unwrap().data, [3.0; 4]);
        // two image channels share the flow
        let img2 = t(2, 1, 2, &[0., 1., 10., 20.]);
        let flow = t(2, 1, 2, &[1., 1., 0., 0.]);
        assert_eq!(warp(&img2, &flow).unwrap().data, [1., 1., 20., 20.]);
    }

    #[test]
    fn binary_eltwise_concat_slice_activation() {
        let a = t(1, 1, 2, &[2., 4.]);
        let b = t(1, 1, 2, &[10., 8.]);
        let run = |k, s: Option<f32>, args: &[&Tensor]| binary(args, k, s).unwrap().data;
        assert_eq!(run(BinKind::Rsub, Some(10.0), &[&a]), [8., 6.]);
        assert_eq!(run(BinKind::Rdiv, Some(8.0), &[&a]), [4., 2.]);
        assert_eq!(run(BinKind::Sub, Some(1.0), &[&a]), [1., 3.]);
        assert_eq!(run(BinKind::Div, Some(2.0), &[&a]), [1., 2.]);
        assert_eq!(run(BinKind::Pow, Some(2.0), &[&a]), [4., 16.]);
        assert_eq!(run(BinKind::Rsub, None, &[&a, &b]), [8., 4.]);
        assert_eq!(run(BinKind::Rdiv, None, &[&a, &b]), [5., 2.]);
        assert_eq!(run(BinKind::Max, None, &[&a, &b]), [10., 8.]);
        assert_eq!(run(BinKind::Min, None, &[&a, &b]), [2., 4.]);
        assert!(binary(&[&a], BinKind::Add, None).is_err());
        // a one channel operand is repeated over the channels of the other (RIFE final blend)
        let two = t(2, 1, 2, &[1., 2., 3., 4.]);
        let mask = t(1, 1, 2, &[10., 100.]);
        assert_eq!(binary(&[&two, &mask], BinKind::Mul, None).unwrap().data, [10., 200., 30., 400.]);
        assert_eq!(binary(&[&mask, &two], BinKind::Rsub, None).unwrap().data, [-9., -98., -7., -96.]);
        assert!(binary(&[&two, &t(3, 1, 2, &[0.; 6])], BinKind::Add, None).is_err());
        assert_eq!(eltwise(&[&a, &b], EltKind::Sum, Some(&[1.0, 4.0])).unwrap().data, [42., 36.]);
        assert_eq!(eltwise(&[&a, &b], EltKind::Prod, None).unwrap().data, [20., 32.]);
        assert_eq!(eltwise(&[&a, &b], EltKind::Max, None).unwrap().data, [10., 8.]);
        let cat = exec(&Kind::Concat, &[&a, &b]).unwrap();
        assert_eq!((cat.c, cat.data.clone()), (2, vec![2., 4., 10., 8.]));
        assert_eq!(exec(&Kind::Slice { start: 1, end: None }, &[&cat]).unwrap().data, [10., 8.]);
        assert_eq!(exec(&Kind::Slice { start: 0, end: Some(1) }, &[&cat]).unwrap().data, [2., 4.]);
        let x = t(1, 1, 3, &[-2., 0., 3.]);
        assert_eq!(exec(&Kind::Activation(Act::Leaky(0.5)), &[&x]).unwrap().data, [-1., 0., 3.]);
        assert_eq!(exec(&Kind::Activation(Act::Relu), &[&x]).unwrap().data, [0., 0., 3.]);
        assert_eq!(exec(&Kind::Activation(Act::Sigmoid), &[&x]).unwrap().data[1], 0.5);
    }

    #[test]
    fn package_graph_end_to_end() {
        // y = leaky(conv1x1(x)) with an f16 weight (2.0) and an f32 bias (-1.0), then rsub 10
        let mut weights = vec![0u8; 256 + 4];
        weights[..2].copy_from_slice(&0x4000u16.to_le_bytes());
        weights[256..260].copy_from_slice(&(-1.0f32).to_le_bytes());
        let model = json!({
            "format": "gpufx-nn", "version": 1, "name": "t", "source": {"kind": "ncnn"},
            "weights": {"file": "weights.bin"}, "inputs": [{"name": "x"}], "outputs": ["z"],
            "ops": [
              {"op": "conv2d", "name": "c", "inputs": ["x"], "output": "y", "in_channels": 1, "out_channels": 1,
               "kernel": [1, 1], "stride": [1, 1], "dilation": [1, 1], "pad": [0, 0, 0, 0],
               "activation": {"type": "leaky_relu", "slope": 0.1},
               "weight": {"offset": 0, "count": 1, "dtype": "f16"}, "bias": {"offset": 256, "count": 1, "dtype": "f32"}},
              {"op": "binary", "name": "b", "inputs": ["y"], "output": "z", "kind": "rsub", "scalar": 10.0}
            ]
        });
        let r = Reference::from_parts(model.to_string().as_bytes(), &weights, None).unwrap();
        let out = r.run(HashMap::from([("x".to_string(), t(1, 1, 3, &[-1., 0.5, 2.]))])).unwrap();
        // conv: -3 -> -0.3, 0, 3 ; rsub: 10 - v
        let z = &out["z"].data;
        for (g, w) in z.iter().zip([10.3, 10.0, 7.0]) {
            assert!((g - w).abs() < 1e-5, "{z:?}");
        }
        assert!(r.run(HashMap::new()).is_err());
    }
}
