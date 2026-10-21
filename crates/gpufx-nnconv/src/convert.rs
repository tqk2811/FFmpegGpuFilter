//! ncnn (.param + .bin) to `gpufx-nn` model and weights.

use std::collections::{HashMap, HashSet};

use crate::model::*;
use crate::ncnn::{parse_param, Layer, Params};
use crate::{fail, Result};

const TAG_F16: u32 = 0x0130_6B47;
const TAG_F32: u32 = 0;
const ALIGN: usize = 256;

#[derive(Debug)]
pub struct Converted {
    pub model: Model,
    pub weights: Vec<u8>,
}

pub fn convert_ncnn(param: &str, bin: &[u8], name: &str) -> Result<Converted> {
    let layers = parse_param(param)?;
    let mut cx = Context { bin, cursor: 0, weights: Vec::new() };
    let mut aliases: HashMap<String, String> = HashMap::new();
    let mut produced: HashSet<String> = HashSet::new();
    let mut consumed: HashSet<String> = HashSet::new();
    let mut inputs = Vec::new();
    let mut ops: Vec<Op> = Vec::new();

    for layer in &layers {
        let ty = layer.ty.as_str();
        let (nin, nout) = (layer.inputs.len(), layer.outputs.len());
        match ty {
            "Input" => {
                layer.params.expect_only(&[0, 1, 2, 11]).map_err(|e| layer.err(e))?;
                arity(layer, 0, 1)?;
                let blob = &layer.outputs[0];
                if !produced.insert(blob.clone()) {
                    return Err(layer.err(format!("blob '{blob}' is produced twice")));
                }
                inputs.push(TensorRef { name: blob.clone() });
                continue;
            }
            "Split" => {
                layer.params.expect_only(&[]).map_err(|e| layer.err(e))?;
                arity(layer, 1, nout)?;
                let src = resolve(&aliases, &layer.inputs[0]);
                if !produced.contains(&src) {
                    return Err(layer.err(format!("input blob '{src}' is not produced by an earlier layer")));
                }
                for out in &layer.outputs {
                    if !produced.insert(out.clone()) {
                        return Err(layer.err(format!("blob '{out}' is produced twice")));
                    }
                    aliases.insert(out.clone(), src.clone());
                }
                continue;
            }
            _ => {}
        }
        if nout != 1 {
            return Err(layer.err(format!("{nout} outputs are not supported")));
        }
        let input_names: Vec<String> = layer.inputs.iter().map(|b| resolve(&aliases, b)).collect();
        for i in &input_names {
            if !produced.contains(i) {
                return Err(layer.err(format!("input blob '{i}' is not produced by an earlier layer")));
            }
        }
        let output = &layer.outputs[0];
        let p = &layer.params;
        let params = match ty {
            "Convolution" => OpParams::Conv2d(conv(layer, &mut cx)?),
            "Deconvolution" => OpParams::Deconv2d(deconv(layer, &mut cx)?),
            "ReLU" => {
                p.expect_only(&[0]).map_err(|e| layer.err(e))?;
                arity(layer, 1, 1)?;
                let slope = p.float(0, 0.0).map_err(|e| layer.err(e))?;
                OpParams::Activation(if slope == 0.0 { Activation::Relu } else { Activation::LeakyRelu { slope } })
            }
            "Sigmoid" => {
                p.expect_only(&[]).map_err(|e| layer.err(e))?;
                arity(layer, 1, 1)?;
                OpParams::Activation(Activation::Sigmoid)
            }
            "BinaryOp" => OpParams::Binary(binary(layer)?),
            "Eltwise" => {
                p.expect_only(&[0, -23301]).map_err(|e| layer.err(e))?;
                if nin < 2 {
                    return Err(layer.err("needs at least 2 inputs"));
                }
                let kind = match p.int(0, 0).map_err(|e| layer.err(e))? {
                    0 => EltwiseKind::Prod,
                    1 => EltwiseKind::Sum,
                    2 => EltwiseKind::Max,
                    v => return Err(layer.err(format!("unsupported op_type {v}"))),
                };
                let coeffs = p.float_array(-23301).map_err(|e| layer.err(e))?;
                if let Some(c) = &coeffs {
                    if c.len() != nin {
                        return Err(layer.err("coefficient count differs from the input count"));
                    }
                }
                OpParams::Eltwise(EltwiseParams { kind, coeffs })
            }
            "Concat" => {
                p.expect_only(&[0]).map_err(|e| layer.err(e))?;
                if nin < 2 {
                    return Err(layer.err("needs at least 2 inputs"));
                }
                if p.int(0, 0).map_err(|e| layer.err(e))? != 0 {
                    return Err(layer.err("only the channel axis (0) is supported"));
                }
                OpParams::Concat(ConcatParams { axis: 0 })
            }
            "Crop" => OpParams::Slice(crop(layer)?),
            "Interp" => OpParams::Resize(interp(layer)?),
            "PixelShuffle" => {
                p.expect_only(&[0, 1]).map_err(|e| layer.err(e))?;
                arity(layer, 1, 1)?;
                if p.int(1, 0).map_err(|e| layer.err(e))? != 0 {
                    return Err(layer.err("only mode 0 (channel-major) is supported"));
                }
                let factor = uint(p, 0, 1, layer)?;
                if factor == 0 {
                    return Err(layer.err("upscale_factor must be positive"));
                }
                OpParams::PixelShuffle(PixelShuffleParams { factor })
            }
            "rife.Warp" => {
                p.expect_only(&[]).map_err(|e| layer.err(e))?;
                arity(layer, 2, 1)?;
                OpParams::Warp(WarpParams { variant: "rife" })
            }
            "PReLU" => OpParams::Prelu(prelu(layer, &mut cx)?),
            "Clip" => OpParams::Clip(clip(layer)?),
            other => return fail(format!("layer '{}': unsupported layer type '{other}'", layer.name)),
        };
        if !produced.insert(output.clone()) {
            return Err(layer.err(format!("blob '{output}' is produced twice")));
        }
        consumed.extend(input_names.iter().cloned());
        ops.push(Op::new(&layer.name, input_names, output, params));
    }

    if cx.cursor != bin.len() {
        return fail(format!("weights file has {} bytes but the layers consume {}", bin.len(), cx.cursor));
    }
    let outputs: Vec<String> = ops.iter().map(|o| o.output.clone()).filter(|o| !consumed.contains(o)).collect();
    if outputs.is_empty() {
        return fail("the model has no output");
    }
    let model = Model {
        format: "gpufx-nn",
        version: 1,
        name: name.to_string(),
        used_for: Vec::new(),
        source: Source { kind: "ncnn" },
        weights: WeightsFile { file: "weights.bin" },
        inputs,
        outputs,
        ops,
    };
    Ok(Converted { model, weights: cx.weights })
}

fn resolve(aliases: &HashMap<String, String>, blob: &str) -> String {
    let mut cur = blob;
    while let Some(next) = aliases.get(cur) {
        cur = next;
    }
    cur.to_string()
}

fn arity(layer: &Layer, nin: usize, nout: usize) -> Result<()> {
    if layer.inputs.len() != nin || layer.outputs.len() != nout {
        return Err(layer.err(format!(
            "expected {nin} inputs and {nout} outputs, found {} and {}",
            layer.inputs.len(),
            layer.outputs.len()
        )));
    }
    Ok(())
}

fn uint(p: &Params, key: i32, default: i64, layer: &Layer) -> Result<u32> {
    let v = p.int(key, default).map_err(|e| layer.err(e))?;
    if v == -233 || v == -234 {
        return Err(layer.err(format!("parameter {key} = {v} (SAME padding) is not supported")));
    }
    u32::try_from(v).map_err(|_| layer.err(format!("parameter {key} = {v} is out of range")))
}

struct Context<'a> {
    bin: &'a [u8],
    cursor: usize,
    weights: Vec<u8>,
}

impl Context<'_> {
    fn take(&mut self, layer: &Layer, bytes: usize, padded: usize) -> Result<&[u8]> {
        let end = self.cursor.checked_add(padded).filter(|e| *e <= self.bin.len());
        let Some(end) = end else { return Err(layer.err("weights file ends too early")) };
        let data = &self.bin[self.cursor..self.cursor + bytes];
        self.cursor = end;
        Ok(data)
    }

    fn push(&mut self, data: &[u8], count: usize, dtype: Dtype) -> BlobRef {
        let offset = self.weights.len().div_ceil(ALIGN) * ALIGN;
        self.weights.resize(offset, 0);
        self.weights.extend_from_slice(data);
        BlobRef { offset: offset as u64, count: count as u64, dtype }
    }

    fn read_weight(&mut self, layer: &Layer, count: usize) -> Result<BlobRef> {
        let tag = u32::from_le_bytes(self.take(layer, 4, 4)?.try_into().expect("4 bytes"));
        let (dtype, size) = match tag {
            TAG_F16 => (Dtype::F16, 2),
            TAG_F32 => (Dtype::F32, 4),
            t => return Err(layer.err(format!("unsupported weight tag 0x{t:08x} (quantized weights)"))),
        };
        let bytes = count.checked_mul(size).ok_or_else(|| layer.err("weight count overflows"))?;
        let data = self.take(layer, bytes, bytes.next_multiple_of(4))?.to_vec();
        Ok(self.push(&data, count, dtype))
    }

    fn read_bias(&mut self, layer: &Layer, count: usize) -> Result<BlobRef> {
        let data = self.take(layer, count * 4, count * 4)?.to_vec();
        Ok(self.push(&data, count, Dtype::F32))
    }

    /// ncnn `ModelBin::load(n, 1)`: `n` raw f32, no type tag (PReLU slopes).
    fn read_f32_raw(&mut self, layer: &Layer, count: usize) -> Result<BlobRef> {
        let bytes = count.checked_mul(4).ok_or_else(|| layer.err("slope count overflows"))?;
        let data = self.take(layer, bytes, bytes)?.to_vec();
        Ok(self.push(&data, count, Dtype::F32))
    }
}

struct Geometry {
    out_channels: u32,
    kernel: [u32; 2],
    stride: [u32; 2],
    dilation: [u32; 2],
    pad: [u32; 4],
    activation: Option<Activation>,
    weight_count: usize,
    bias: bool,
}

#[allow(clippy::manual_is_multiple_of)] // is_multiple_of needs Rust 1.90, the MSRV is 1.88
fn geometry(layer: &Layer, deconv: bool) -> Result<Geometry> {
    let p = &layer.params;
    arity(layer, 1, 1)?;
    let mut allowed = vec![0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 12, 13, 14, 15, 16, -23310];
    if deconv {
        allowed.extend([18, 19, 20, 21]);
    }
    p.expect_only(&allowed).map_err(|e| layer.err(e))?;
    if p.int(7, 1).map_err(|e| layer.err(e))? != 1 {
        return Err(layer.err("grouped convolution is not supported"));
    }
    let out_channels = uint(p, 0, 0, layer)?;
    let kw = uint(p, 1, 0, layer)?;
    let kh = uint(p, 11, kw as i64, layer)?;
    let dw = uint(p, 2, 1, layer)?;
    let dh = uint(p, 12, dw as i64, layer)?;
    let sw = uint(p, 3, 1, layer)?;
    let sh = uint(p, 13, sw as i64, layer)?;
    let left = uint(p, 4, 0, layer)?;
    let top = uint(p, 14, left as i64, layer)?;
    let right = uint(p, 15, left as i64, layer)?;
    let bottom = uint(p, 16, top as i64, layer)?;
    if [out_channels, kw, kh, dw, dh, sw, sh].contains(&0) {
        return Err(layer.err("channels, kernel, dilation and stride must be positive"));
    }
    let activation = match p.int(9, 0).map_err(|e| layer.err(e))? {
        0 => None,
        1 => Some(Activation::Relu),
        2 => {
            let slope = p.float_array(-23310).map_err(|e| layer.err(e))?.and_then(|a| a.first().copied());
            Some(Activation::LeakyRelu { slope: slope.ok_or_else(|| layer.err("leaky relu without a slope"))? })
        }
        4 => Some(Activation::Sigmoid),
        v => return Err(layer.err(format!("unsupported activation_type {v}"))),
    };
    let weight_count = uint(p, 6, 0, layer)? as usize;
    let kernel_size = out_channels as usize * kh as usize * kw as usize;
    if weight_count == 0 || weight_count % kernel_size != 0 {
        return Err(layer.err(format!("weight_data_size {weight_count} does not fit {out_channels} outputs and a {kh}x{kw} kernel")));
    }
    Ok(Geometry {
        out_channels,
        kernel: [kh, kw],
        stride: [sh, sw],
        dilation: [dh, dw],
        pad: [top, left, bottom, right],
        activation,
        weight_count,
        bias: p.int(5, 0).map_err(|e| layer.err(e))? != 0,
    })
}

struct ConvBlobs {
    in_channels: u32,
    weight: BlobRef,
    bias: Option<BlobRef>,
}

fn blobs(layer: &Layer, cx: &mut Context, g: &Geometry) -> Result<ConvBlobs> {
    let weight = cx.read_weight(layer, g.weight_count)?;
    let bias = if g.bias { Some(cx.read_bias(layer, g.out_channels as usize)?) } else { None };
    let per_input = g.out_channels as usize * g.kernel[0] as usize * g.kernel[1] as usize;
    Ok(ConvBlobs { in_channels: (g.weight_count / per_input) as u32, weight, bias })
}

fn conv(layer: &Layer, cx: &mut Context) -> Result<ConvParams> {
    let g = geometry(layer, false)?;
    let b = blobs(layer, cx, &g)?;
    Ok(ConvParams {
        in_channels: b.in_channels,
        out_channels: g.out_channels,
        kernel: g.kernel,
        stride: g.stride,
        dilation: g.dilation,
        pad: g.pad,
        activation: g.activation,
        weight: b.weight,
        bias: b.bias,
    })
}

fn deconv(layer: &Layer, cx: &mut Context) -> Result<DeconvParams> {
    let g = geometry(layer, true)?;
    let p = &layer.params;
    if p.int(20, 0).map_err(|e| layer.err(e))? != 0 || p.int(21, 0).map_err(|e| layer.err(e))? != 0 {
        return Err(layer.err("a fixed output size is not supported"));
    }
    let opw = uint(p, 18, 0, layer)?;
    let oph = uint(p, 19, opw as i64, layer)?;
    let b = blobs(layer, cx, &g)?;
    Ok(DeconvParams {
        in_channels: b.in_channels,
        out_channels: g.out_channels,
        kernel: g.kernel,
        stride: g.stride,
        dilation: g.dilation,
        pad: g.pad,
        output_pad: [oph, opw],
        activation: g.activation,
        weight: b.weight,
        bias: b.bias,
    })
}

fn binary(layer: &Layer) -> Result<BinaryParams> {
    let p = &layer.params;
    p.expect_only(&[0, 1, 2]).map_err(|e| layer.err(e))?;
    let kind = match p.int(0, 0).map_err(|e| layer.err(e))? {
        0 => BinaryKind::Add,
        1 => BinaryKind::Sub,
        2 => BinaryKind::Mul,
        3 => BinaryKind::Div,
        4 => BinaryKind::Max,
        5 => BinaryKind::Min,
        6 => BinaryKind::Pow,
        7 => BinaryKind::Rsub,
        8 => BinaryKind::Rdiv,
        v => return Err(layer.err(format!("unsupported op_type {v}"))),
    };
    let with_scalar = p.int(1, 0).map_err(|e| layer.err(e))? != 0;
    if with_scalar {
        arity(layer, 1, 1)?;
        Ok(BinaryParams { kind, scalar: Some(p.float(2, 0.0).map_err(|e| layer.err(e))?) })
    } else {
        arity(layer, 2, 1)?;
        Ok(BinaryParams { kind, scalar: None })
    }
}

fn crop(layer: &Layer) -> Result<SliceParams> {
    let p = &layer.params;
    p.expect_only(&[-23309, -23310, -23311]).map_err(|e| layer.err(e))?;
    arity(layer, 1, 1)?;
    let get = |key| p.int_array(key).map_err(|e| layer.err(e));
    let (Some(starts), Some(ends), Some(axes)) = (get(-23309)?, get(-23310)?, get(-23311)?) else {
        return Err(layer.err("only the starts/ends/axes form of Crop is supported"));
    };
    if starts.len() != 1 || ends.len() != 1 || axes.len() != 1 {
        return Err(layer.err("only a Crop along one axis is supported"));
    }
    if axes[0] != 0 {
        return Err(layer.err(format!("only the channel axis (0) is supported, found {}", axes[0])));
    }
    let start = u32::try_from(starts[0]).map_err(|_| layer.err("negative start is not supported"))?;
    // -233 and INT_MAX mean "to the end" in ncnn.
    let end = match ends[0] {
        -233 | 2_147_483_647 => None,
        e => Some(u32::try_from(e).map_err(|_| layer.err("negative end is not supported"))?),
    };
    if end.is_some_and(|e| e <= start) {
        return Err(layer.err("empty slice"));
    }
    Ok(SliceParams { axis: 0, start, end })
}

fn interp(layer: &Layer) -> Result<ResizeParams> {
    let p = &layer.params;
    p.expect_only(&[0, 1, 2, 3, 4, 6]).map_err(|e| layer.err(e))?;
    arity(layer, 1, 1)?;
    let mode = match p.int(0, 0).map_err(|e| layer.err(e))? {
        1 => ResizeMode::Nearest,
        2 => ResizeMode::Bilinear,
        3 => ResizeMode::Bicubic,
        v => return Err(layer.err(format!("unsupported resize_type {v}"))),
    };
    let (oh, ow) = (uint(p, 3, 0, layer)?, uint(p, 4, 0, layer)?);
    let (scale, size) = if oh > 0 || ow > 0 {
        if oh == 0 || ow == 0 {
            return Err(layer.err("output height and width must be set together"));
        }
        (None, Some([oh, ow]))
    } else {
        let hs = p.float(1, 1.0).map_err(|e| layer.err(e))?;
        let ws = p.float(2, 1.0).map_err(|e| layer.err(e))?;
        if hs <= 0.0 || ws <= 0.0 {
            return Err(layer.err("scales must be positive"));
        }
        (Some([hs, ws]), None)
    };
    let align_corners = p.int(6, 0).map_err(|e| layer.err(e))? != 0;
    Ok(ResizeParams { mode, scale, size, align_corners })
}

fn prelu(layer: &Layer, cx: &mut Context) -> Result<PreluParams> {
    let p = &layer.params;
    p.expect_only(&[0]).map_err(|e| layer.err(e))?;
    arity(layer, 1, 1)?;
    // ncnn PReLU: param 0 is num_slope; the slopes are num_slope raw f32 (ModelBin type 1, no tag).
    let count = uint(p, 0, 0, layer)? as usize;
    if count == 0 {
        return Err(layer.err("num_slope must be positive"));
    }
    let slope = cx.read_f32_raw(layer, count)?;
    Ok(PreluParams { slope })
}

fn clip(layer: &Layer) -> Result<ClipParams> {
    let p = &layer.params;
    p.expect_only(&[0, 1]).map_err(|e| layer.err(e))?;
    arity(layer, 1, 1)?;
    let min = p.float(0, f32::MIN).map_err(|e| layer.err(e))?;
    let max = p.float(1, f32::MAX).map_err(|e| layer.err(e))?;
    if min > max {
        return Err(layer.err("min is greater than max"));
    }
    Ok(ClipParams { min, max })
}

#[cfg(test)]
mod tests {
    use super::*;

    const PARAM: &str = "\
7767517
10 11
Input in0 0 1 in0
Input in1 0 1 in1
Split sp 1 2 in0 a b
Convolution c0 1 1 a c 0=2 1=1 5=1 6=6 9=2 -23310=1,1.000000e-01
Crop cr 1 1 c d -23309=1,1 -23310=1,-233 -23311=1,0
BinaryOp bo 1 1 d e 0=2 1=1 2=2.000000e+00
Concat cc 2 1 b e f
Convolution c1 1 1 f g 0=1 1=1 11=3 4=1 6=15
rife.Warp w 2 1 in1 g out0
Sigmoid sg 1 1 out0 out1
";

    fn bin() -> Vec<u8> {
        let mut b = Vec::new();
        b.extend(TAG_F16.to_le_bytes());
        for h in [0x3C00u16, 0x4000, 0x4200, 0x4400, 0x4500, 0x4600] {
            b.extend(h.to_le_bytes());
        }
        b.extend(1.5f32.to_le_bytes());
        b.extend(2.5f32.to_le_bytes());
        b.extend(TAG_F32.to_le_bytes());
        for i in 0..15 {
            b.extend((i as f32).to_le_bytes());
        }
        b
    }

    #[test]
    fn converts_a_small_model() {
        let c = convert_ncnn(PARAM, &bin(), "tiny").unwrap();
        let v: serde_json::Value = serde_json::from_slice(&serde_json::to_vec(&c.model).unwrap()).unwrap();
        assert_eq!(v["format"], "gpufx-nn");
        assert_eq!(v["inputs"], serde_json::json!([{"name": "in0"}, {"name": "in1"}]));
        assert_eq!(v["outputs"], serde_json::json!(["out1"]));
        let ops = v["ops"].as_array().unwrap();
        assert_eq!(ops.len(), 7);
        // The Split is gone: c0 reads the model input directly.
        assert_eq!(ops[0]["op"], "conv2d");
        assert_eq!(ops[0]["inputs"], serde_json::json!(["in0"]));
        assert_eq!(ops[0]["in_channels"], 3);
        assert_eq!(ops[0]["activation"], serde_json::json!({"type": "leaky_relu", "slope": 0.1}));
        assert_eq!(ops[0]["weight"], serde_json::json!({"offset": 0, "count": 6, "dtype": "f16"}));
        assert_eq!(ops[0]["bias"], serde_json::json!({"offset": 256, "count": 2, "dtype": "f32"}));
        assert_eq!(ops[1]["op"], "slice");
        assert_eq!((ops[1]["start"].as_u64(), ops[1]["end"].is_null()), (Some(1), true));
        assert_eq!(ops[2], serde_json::json!({"op": "binary", "name": "bo", "inputs": ["d"], "output": "e", "kind": "mul", "scalar": 2.0}));
        assert_eq!(ops[3]["inputs"], serde_json::json!(["in0", "e"]));
        assert_eq!(ops[4]["kernel"], serde_json::json!([3, 1]));
        assert_eq!(ops[4]["pad"], serde_json::json!([1, 1, 1, 1]));
        assert_eq!(ops[4]["weight"], serde_json::json!({"offset": 512, "count": 15, "dtype": "f32"}));
        assert_eq!(ops[4]["bias"], serde_json::Value::Null);
        assert_eq!(ops[5]["op"], "warp");
        assert_eq!(ops[6]["type"], "sigmoid");
        // Blobs start on 256 bytes; the fp16 weights are stored as they are.
        assert_eq!(c.weights.len(), 512 + 60);
        assert_eq!(&c.weights[..4], &[0x00, 0x3C, 0x00, 0x40]);
        assert_eq!(&c.weights[12..256], &[0u8; 244][..]);
        assert_eq!(f32::from_le_bytes(c.weights[256..260].try_into().unwrap()), 1.5);
    }

    #[test]
    fn rejects_bad_input() {
        let mut long = bin();
        long.push(0);
        assert!(convert_ncnn(PARAM, &long, "t").unwrap_err().0.contains("consume"));
        let short = bin()[..40].to_vec();
        assert!(convert_ncnn(PARAM, &short, "t").unwrap_err().0.contains("too early"));
        let mut bad_tag = bin();
        bad_tag[..4].copy_from_slice(&0x000D_4B38u32.to_le_bytes());
        assert!(convert_ncnn(PARAM, &bad_tag, "t").unwrap_err().0.contains("tag"));
        let unknown = PARAM.replace("Sigmoid", "Swish");
        assert!(convert_ncnn(&unknown, &bin(), "t").unwrap_err().0.contains("'Swish'"));
        let cropped = PARAM.replace("-23311=1,0", "-23311=1,1");
        assert!(convert_ncnn(&cropped, &bin(), "t").unwrap_err().0.contains("axis"));
    }

    #[test]
    fn fp16_data_is_padded_to_four_bytes_in_the_source() {
        let param = "7767517\n2 2\nInput in0 0 1 in0\nConvolution c 1 1 in0 out0 0=1 1=1 6=3\n";
        let mut b = Vec::new();
        b.extend(TAG_F16.to_le_bytes());
        b.extend([1, 0, 2, 0, 3, 0, 0, 0]); // 3 halves, 2 bytes of padding
        let c = convert_ncnn(param, &b, "t").unwrap();
        assert_eq!(c.weights, [1, 0, 2, 0, 3, 0]);
    }

    #[test]
    fn converts_prelu_and_clip() {
        // Input -> PReLU (2 slopes, raw f32) -> Clip
        let param = "7767517\n3 3\nInput in0 0 1 in0\nPReLU p 1 1 in0 a 0=2\nClip c 1 1 a out0 0=0.0 1=1.0\n";
        let mut bin = Vec::new();
        bin.extend(0.1f32.to_le_bytes());
        bin.extend(0.2f32.to_le_bytes());
        let c = convert_ncnn(param, &bin, "t").unwrap();
        let v: serde_json::Value = serde_json::from_slice(&serde_json::to_vec(&c.model).unwrap()).unwrap();
        let ops = v["ops"].as_array().unwrap();
        assert_eq!(ops[0]["op"], "prelu");
        assert_eq!(ops[0]["slope"], serde_json::json!({"offset": 0, "count": 2, "dtype": "f32"}));
        assert_eq!(ops[1], serde_json::json!({"op": "clip", "name": "c", "inputs": ["a"], "output": "out0", "min": 0.0, "max": 1.0}));
        // the slopes are stored as raw f32, no tag
        assert_eq!(f32::from_le_bytes(c.weights[..4].try_into().unwrap()), 0.1);
        assert_eq!(f32::from_le_bytes(c.weights[4..8].try_into().unwrap()), 0.2);

        // an unknown PReLU parameter still fails
        let bad = "7767517\n2 2\nInput in0 0 1 in0\nPReLU p 1 1 in0 out0 0=2 9=1\n";
        assert!(convert_ncnn(bad, &bin, "t").unwrap_err().0.contains("unsupported parameter"));
    }
}
