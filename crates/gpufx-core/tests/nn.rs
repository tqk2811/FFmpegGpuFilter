//! gpufx-nn on the GPU against the CPU reference executor of gpufx-nnconv (the golden semantics of every
//! op), on small graphs with odd sizes, plus RIFE on real frames (`#[ignore]`, needs the package and frames).
//! GPU tests are skipped without a device.

mod common;

use std::collections::HashMap;
use std::sync::Arc;

use gpufx_core::nn::{FrameInterp, InterpFrames, NnModel};
use gpufx_core::{ColorInfo, GpuContext, GpuFrame, Image, Matrix, PixelFormat, Range};
use gpufx_nnconv::reference::{Reference, Tensor};

fn gpu() -> Option<Arc<GpuContext>> {
    static CTX: std::sync::OnceLock<Option<Arc<GpuContext>>> = std::sync::OnceLock::new();
    CTX.get_or_init(|| match GpuContext::new(common::backend()) {
        Ok(ctx) => Some(ctx),
        Err(e) => {
            eprintln!("skipping: {e}");
            None
        }
    })
    .clone()
}

/// Deterministic values in [-1, 1) that f16 holds exactly (multiples of 1/64).
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> f32 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((self.0 >> 33) % 128) as f32 / 64.0 - 1.0
    }

    fn vec(&mut self, n: usize) -> Vec<f32> {
        (0..n).map(|_| self.next()).collect()
    }
}

/// f32 to f16 bits, for values f16 holds exactly (normal numbers and zero).
fn f16_bits(v: f32) -> u16 {
    if v == 0.0 {
        return 0;
    }
    let b = v.to_bits();
    let sign = ((b >> 16) & 0x8000) as u16;
    let exp = ((b >> 23) & 0xff) as i32 - 127 + 15;
    assert!((1..31).contains(&exp), "{v} is not a normal f16");
    sign | ((exp as u16) << 10) | ((b >> 13) & 0x3ff) as u16
}

/// `weights.bin` being built: blobs start at multiples of 256 bytes.
#[derive(Default)]
struct Weights(Vec<u8>);

impl Weights {
    fn add(&mut self, vals: &[f32], f16: bool) -> String {
        self.0.resize(self.0.len().div_ceil(256) * 256, 0);
        let offset = self.0.len();
        for v in vals {
            if f16 {
                self.0.extend_from_slice(&f16_bits(*v).to_le_bytes());
            } else {
                self.0.extend_from_slice(&v.to_le_bytes());
            }
        }
        format!(r#"{{"offset":{offset},"count":{},"dtype":"{}"}}"#, vals.len(), if f16 { "f16" } else { "f32" })
    }
}

/// The JSON of a conv2d / deconv2d op with random weights.
#[allow(clippy::too_many_arguments)]
fn conv(
    w: &mut Weights,
    rng: &mut Rng,
    op: &str,
    name: &str,
    input: &str,
    cin: u32,
    cout: u32,
    k: [u32; 2],
    stride: [u32; 2],
    dil: [u32; 2],
    pad: [u32; 4],
    output_pad: [u32; 2],
    act: &str,
) -> String {
    let n = (cin * cout * k[0] * k[1]) as usize;
    let weight = w.add(&rng.vec(n).iter().map(|v| v * 0.5).collect::<Vec<_>>(), true);
    let bias = w.add(&rng.vec(cout as usize), false);
    let extra = if op == "deconv2d" { format!(r#","output_pad":[{},{}]"#, output_pad[0], output_pad[1]) } else { String::new() };
    format!(
        r#"{{"op":"{op}","name":"{name}","inputs":["{input}"],"output":"{name}","in_channels":{cin},"out_channels":{cout},
        "kernel":[{},{}],"stride":[{},{}],"dilation":[{},{}],"pad":[{},{},{},{}]{extra},"activation":{act},"weight":{weight},"bias":{bias}}}"#,
        k[0], k[1], stride[0], stride[1], dil[0], dil[1], pad[0], pad[1], pad[2], pad[3]
    )
}

fn op(kind: &str, name: &str, inputs: &[&str], params: &str) -> String {
    let ins: Vec<String> = inputs.iter().map(|i| format!("\"{i}\"")).collect();
    let sep = if params.is_empty() { "" } else { "," };
    format!(r#"{{"op":"{kind}","name":"{name}","inputs":[{}],"output":"{name}"{sep}{params}}}"#, ins.join(","))
}

fn model(inputs: &[&str], outputs: &[&str], ops: &[String]) -> String {
    let ins: Vec<String> = inputs.iter().map(|i| format!(r#"{{"name":"{i}"}}"#)).collect();
    let outs: Vec<String> = outputs.iter().map(|o| format!("\"{o}\"")).collect();
    format!(
        r#"{{"format":"gpufx-nn","version":1,"name":"test","source":{{"kind":"test"}},"weights":{{"file":"weights.bin"}},
        "inputs":[{}],"outputs":[{}],"ops":[{}]}}"#,
        ins.join(","),
        outs.join(","),
        ops.join(",\n")
    )
}

/// Runs the model on the GPU and on the CPU reference with random inputs of `shapes`; every output must agree.
fn check(ctx: &Arc<GpuContext>, json: &str, weights: &[u8], shapes: &[(&str, [u32; 3])], rng: &mut Rng) {
    let gpu = NnModel::from_parts(ctx.clone(), json.as_bytes(), weights, None).expect("gpu model");
    let cpu = Reference::from_parts(json.as_bytes(), weights, None).expect("cpu model");
    let plan = gpu.plan(shapes).expect("plan");
    let mut inputs = HashMap::new();
    for (name, [c, h, w]) in shapes {
        let data = rng.vec((c * h * w) as usize);
        plan.write_input(name, &data).unwrap();
        inputs.insert(name.to_string(), Tensor::new(*c as usize, *h as usize, *w as usize, data));
    }
    plan.run().unwrap();
    let want = cpu.run(inputs).expect("cpu run");
    for name in gpu.outputs() {
        let w = &want[name];
        let got = plan.read(name).unwrap();
        let t = plan.tensor(name).unwrap();
        assert_eq!((t.c as usize, t.h as usize, t.w as usize), (w.c, w.h, w.w), "shape of {name}");
        let mut worst = (0.0f32, 0usize);
        for (i, (g, c)) in got.iter().zip(&w.data).enumerate() {
            // equal covers infinities (division by zero)
            let err = if g == c { 0.0 } else { (g - c).abs() / (1.0 + c.abs()) };
            if err > worst.0 || err.is_nan() {
                worst = (err, i);
            }
        }
        assert!(worst.0 <= 2e-5, "{name}: error {} at {} (gpu {}, cpu {})", worst.0, worst.1, got[worst.1], w.data[worst.1]);
    }
}

#[test]
fn convolutions_match_the_reference() {
    let Some(ctx) = gpu() else { return };
    let (mut w, mut r) = (Weights::default(), Rng(1));
    let leaky = r#"{"type":"leaky_relu","slope":0.2}"#;
    let ops = vec![
        // 3x3 stride 1 with a residual add and an activation after it (fused), input channels not a multiple
        // of the chunk, output channels not a multiple of the block
        conv(&mut w, &mut r, "conv2d", "a", "x", 7, 20, [3, 3], [1, 1], [1, 1], [1, 1, 1, 1], [0, 0], leaky),
        conv(&mut w, &mut r, "conv2d", "b", "a", 20, 20, [3, 3], [1, 1], [1, 1], [1, 1, 1, 1], [0, 0], "null"),
        op("binary", "s", &["b", "a"], r#""kind":"add","scalar":null"#),
        op("activation", "t", &["s"], r#""type":"leaky_relu","slope":0.2"#),
        // stride 2, relu
        conv(&mut w, &mut r, "conv2d", "c", "t", 20, 5, [3, 3], [2, 2], [1, 1], [1, 1, 1, 1], [0, 0], r#"{"type":"relu"}"#),
        // 5x5 dilated, sigmoid, many output channels
        conv(&mut w, &mut r, "conv2d", "d", "x", 7, 37, [5, 5], [1, 1], [2, 2], [4, 4, 4, 4], [0, 0], r#"{"type":"sigmoid"}"#),
        // asymmetric kernel, stride and pad; 1x1
        conv(&mut w, &mut r, "conv2d", "e", "x", 7, 9, [3, 1], [1, 2], [1, 1], [1, 0, 2, 0], [0, 0], "null"),
        conv(&mut w, &mut r, "conv2d", "f", "e", 9, 4, [1, 1], [1, 1], [1, 1], [0, 0, 0, 0], [0, 0], "null"),
    ];
    let json = model(&["x"], &["c", "d", "f"], &ops);
    check(&ctx, &json, &w.0, &[("x", [7, 23, 37])], &mut r);
}

#[test]
fn deconvolutions_match_the_reference() {
    let Some(ctx) = gpu() else { return };
    let (mut w, mut r) = (Weights::default(), Rng(2));
    let ops = vec![
        conv(&mut w, &mut r, "deconv2d", "a", "x", 9, 13, [4, 4], [2, 2], [1, 1], [1, 1, 1, 1], [0, 0], "null"),
        conv(&mut w, &mut r, "deconv2d", "b", "x", 9, 6, [3, 3], [2, 2], [1, 1], [1, 1, 1, 1], [1, 1], r#"{"type":"relu"}"#),
        conv(&mut w, &mut r, "deconv2d", "c", "x", 9, 8, [2, 2], [2, 2], [1, 1], [0, 0, 0, 0], [0, 0], "null"),
        conv(&mut w, &mut r, "deconv2d", "d", "x", 9, 5, [3, 3], [1, 1], [1, 1], [1, 1, 1, 1], [0, 0], "null"),
        conv(&mut w, &mut r, "deconv2d", "e", "x", 9, 4, [3, 5], [3, 2], [2, 1], [2, 3, 1, 0], [1, 0], "null"),
    ];
    let json = model(&["x"], &["a", "b", "c", "d", "e"], &ops);
    check(&ctx, &json, &w.0, &[("x", [9, 11, 17])], &mut r);
}

#[test]
fn resizes_match_the_reference() {
    let Some(ctx) = gpu() else { return };
    let mut r = Rng(3);
    let rs = |name: &str, p: &str| op("resize", name, &["x"], p);
    let ops = vec![
        rs("a", r#""mode":"bilinear","scale":[0.5,0.5],"size":null,"align_corners":false"#),
        rs("b", r#""mode":"bilinear","scale":[2,4],"size":null,"align_corners":false"#),
        rs("c", r#""mode":"bilinear","scale":null,"size":[7,9],"align_corners":true"#),
        rs("d", r#""mode":"nearest","scale":[2,0.5],"size":null,"align_corners":false"#),
        rs("e", r#""mode":"nearest","scale":null,"size":[30,8],"align_corners":false"#),
        rs("f", r#""mode":"bicubic","scale":[2,2],"size":null,"align_corners":false"#),
        rs("g", r#""mode":"bilinear","scale":[0.125,0.125],"size":null,"align_corners":false"#),
    ];
    let json = model(&["x"], &["a", "b", "c", "d", "e", "f", "g"], &ops);
    check(&ctx, &json, &[0u8; 4], &[("x", [3, 13, 19])], &mut r);
}

#[test]
fn elementwise_and_layout_ops_match_the_reference() {
    let Some(ctx) = gpu() else { return };
    let mut r = Rng(4);
    let mut ops = Vec::new();
    for (k, kind) in ["add", "sub", "mul", "div", "max", "min", "rsub", "rdiv"].iter().enumerate() {
        // tensor x mask (broadcast over channels), and with a scalar
        ops.push(op("binary", &format!("b{k}"), &["x", "m"], &format!(r#""kind":"{kind}","scalar":null"#)));
        ops.push(op("binary", &format!("s{k}"), &["x"], &format!(r#""kind":"{kind}","scalar":1.5"#)));
    }
    ops.push(op("binary", "bc", &["v", "x"], r#""kind":"mul","scalar":null"#)); // 3x1x1 times 3xHxW
    ops.push(op("eltwise", "sum", &["x", "y"], r#""kind":"sum","coeffs":[1,4]"#));
    ops.push(op("eltwise", "prod", &["x", "y"], r#""kind":"prod","coeffs":null"#));
    ops.push(op("eltwise", "emax", &["x", "y"], r#""kind":"max","coeffs":null"#));
    ops.push(op("activation", "sig", &["x"], r#""type":"sigmoid""#));
    ops.push(op("activation", "relu", &["y"], r#""type":"relu""#));
    // concat of: a model input (copied), a slice view, an op output read only by the concat (written in place)
    ops.push(op("slice", "sl", &["y"], r#""axis":0,"start":1,"end":3"#));
    ops.push(op("binary", "tmp", &["y"], r#""kind":"mul","scalar":2"#));
    ops.push(op("concat", "cat", &["x", "sl", "tmp"], r#""axis":0"#));
    ops.push(op("slice", "tail", &["cat"], r#""axis":0,"start":5,"end":null"#));
    ops.push(op("activation", "tail2", &["tail"], r#""type":"leaky_relu","slope":0.1"#));
    ops.push(op("pixel_shuffle", "ps", &["cat"], r#""factor":2"#));
    ops.push(op("binary", "flow", &["f"], r#""kind":"mul","scalar":3"#));
    ops.push(op("warp", "wp", &["x", "flow"], r#""variant":"rife""#));
    let mut outs: Vec<String> = (0..8).flat_map(|k| [format!("b{k}"), format!("s{k}")]).collect();
    outs.extend(["bc", "sum", "prod", "emax", "sig", "relu", "tail2", "ps", "wp"].map(String::from));
    let outs: Vec<&str> = outs.iter().map(String::as_str).collect();
    let json = model(&["x", "y", "m", "v", "f"], &outs, &ops);
    let shapes = [("x", [3, 9, 14]), ("y", [3, 9, 14]), ("m", [1, 9, 14]), ("v", [3, 1, 1]), ("f", [2, 9, 14])];
    check(&ctx, &json, &[0u8; 4], &shapes, &mut r);
}

/// Intermediates that die early (so best-fit slot reuse has something to reuse), a conv + add + leaky_relu fused
/// and written in place into a concat, and a concat of a concat (nested in-place chain).
#[test]
fn chains_with_slot_reuse_and_nested_concats_match_the_reference() {
    let Some(ctx) = gpu() else { return };
    let (mut w, mut r) = (Weights::default(), Rng(6));
    let same = ([3, 3], [1, 1], [1, 1], [1, 1, 1, 1], [0, 0]);
    let c = |w: &mut Weights, r: &mut Rng, name: &str, input: &str, cin: u32, cout: u32, act: &str| {
        conv(w, r, "conv2d", name, input, cin, cout, same.0, same.1, same.2, same.3, same.4, act)
    };
    let one = |w: &mut Weights, r: &mut Rng, name: &str, input: &str, cin: u32, cout: u32| {
        conv(w, r, "conv2d", name, input, cin, cout, [1, 1], [1, 1], [1, 1], [0, 0, 0, 0], [0, 0], "null")
    };
    let ops = vec![
        c(&mut w, &mut r, "c1", "x", 5, 8, "null"),
        // fused: c2 + c1, then leaky_relu; the result is the first part of g1
        c(&mut w, &mut r, "c2", "c1", 8, 8, "null"),
        op("binary", "s", &["c2", "c1"], r#""kind":"add","scalar":null"#),
        op("activation", "t", &["s"], r#""type":"leaky_relu","slope":0.2"#),
        one(&mut w, &mut r, "p", "c1", 8, 4),
        op("concat", "g1", &["t", "p"], r#""axis":0"#),
        c(&mut w, &mut r, "q", "c1", 8, 6, r#"{"type":"relu"}"#),
        // g1 is read only by g2, so t and p end up in g2's buffer too
        op("concat", "g2", &["g1", "q"], r#""axis":0"#),
        // a chain of different sizes: each intermediate is read by the next op only
        c(&mut w, &mut r, "r1", "g2", 18, 6, "null"),
        c(&mut w, &mut r, "r2", "r1", 6, 10, r#"{"type":"sigmoid"}"#),
        one(&mut w, &mut r, "r3", "r2", 10, 3),
        c(&mut w, &mut r, "r4", "r3", 3, 12, "null"),
        op("concat", "g3", &["r4", "r3"], r#""axis":0"#),
        one(&mut w, &mut r, "o", "g3", 15, 4),
    ];
    let json = model(&["x"], &["o"], &ops);
    check(&ctx, &json, &w.0, &[("x", [5, 11, 17])], &mut r);
}

fn rgba_texture(ctx: &GpuContext, w: u32, h: u32, usage: wgpu::TextureUsages) -> wgpu::Texture {
    ctx.device().create_texture(&wgpu::TextureDescriptor {
        label: None,
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage,
        view_formats: &[],
    })
}

/// Two `encode` calls with different timesteps in one encoder and one submit: each output equals a run of its
/// own (the timestep must not be shared through the queue, which applies it at the submit).
#[test]
fn encodes_into_one_encoder_keep_their_own_timestep() {
    let Some(ctx) = gpu() else { return };
    let (mut w, mut r) = (Weights::default(), Rng(7));
    let ops = vec![
        op("concat", "cat", &["in0", "in1", "in2"], r#""axis":0"#),
        conv(&mut w, &mut r, "conv2d", "c", "cat", 7, 3, [1, 1], [1, 1], [1, 1], [0, 0, 0, 0], [0, 0], "null"),
    ];
    let json = model(&["in0", "in1", "in2"], &["c"], &ops);
    let io = r#"{"kind":"frame_interp","inputs":{"frame0":"in0","frame1":"in1","timestep":"in2"},"output":"c",
        "color":"rgb","range":[0,1],"pad_multiple":1,"pad_mode":"zero","output_clamp":[0,1]}"#;
    let (wd, ht) = (21u32, 13u32);
    let rgba: Vec<Vec<u8>> = (0..2).map(|_| (0..wd * ht * 4).map(|_| ((r.next() + 1.0) * 127.9) as u8).collect()).collect();
    let model = NnModel::from_parts(ctx.clone(), json.as_bytes(), &w.0, Some(io.as_bytes())).unwrap();
    let mut interp = FrameInterp::new(Arc::new(model)).unwrap();
    let ts = [0.25f32, 0.75];
    let want: Vec<Vec<u8>> = ts.iter().map(|&t| interp.interpolate(&view(&rgba[0], wd, ht), &view(&rgba[1], wd, ht), t).unwrap()).collect();
    assert_ne!(want[0], want[1], "the timestep should change the output");

    let (device, queue) = (ctx.device(), ctx.queue());
    let input = wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST;
    let frames: Vec<wgpu::Texture> = rgba
        .iter()
        .map(|d| {
            let tex = rgba_texture(&ctx, wd, ht, input);
            queue.write_texture(
                wgpu::TexelCopyTextureInfo { texture: &tex, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
                d,
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(wd * 4), rows_per_image: Some(ht) },
                wgpu::Extent3d { width: wd, height: ht, depth_or_array_layers: 1 },
            );
            tex
        })
        .collect();
    let outs: Vec<wgpu::Texture> =
        ts.iter().map(|_| rgba_texture(&ctx, wd, ht, wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC)).collect();
    let row = (wd * 4).div_ceil(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT) * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
    let readbacks: Vec<wgpu::Buffer> = ts
        .iter()
        .map(|_| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: None,
                size: row as u64 * ht as u64,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            })
        })
        .collect();
    let (a, b) = (frames[0].create_view(&Default::default()), frames[1].create_view(&Default::default()));
    let mut enc = device.create_command_encoder(&Default::default());
    for ((&t, out), rb) in ts.iter().zip(&outs).zip(&readbacks) {
        interp.encode(&mut enc, &a, &b, &out.create_view(&Default::default()), wd, ht, t).unwrap();
        enc.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo { texture: out, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
            wgpu::TexelCopyBufferInfo {
                buffer: rb,
                layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(row), rows_per_image: Some(ht) },
            },
            wgpu::Extent3d { width: wd, height: ht, depth_or_array_layers: 1 },
        );
    }
    queue.submit([enc.finish()]);
    for (k, rb) in readbacks.iter().enumerate() {
        let slice = rb.slice(..);
        slice.map_async(wgpu::MapMode::Read, |r| r.unwrap());
        device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
        let mut got = Vec::new();
        {
            let mapped = slice.get_mapped_range().unwrap();
            for y in 0..ht as usize {
                got.extend_from_slice(&mapped[y * row as usize..][..wd as usize * 4]);
            }
        }
        rb.unmap();
        assert_eq!(got, want[k], "output {k} (t = {})", ts[k]);
    }
}

/// The pre/post processing of `frame_interp` against gpufx-nnconv's `frames::interpolate`: odd size (padding and
/// crop), values pushed out of [0, 1] (clamp), rounding.
#[test]
fn frame_interp_matches_the_reference() {
    let Some(ctx) = gpu() else { return };
    let (mut w, mut r) = (Weights::default(), Rng(5));
    let ops = vec![
        op("concat", "cat", &["in0", "in1", "in2"], r#""axis":0"#),
        conv(&mut w, &mut r, "conv2d", "c", "cat", 7, 3, [3, 3], [2, 2], [1, 1], [1, 1, 1, 1], [0, 0], "null"),
        op("resize", "up", &["c"], r#""mode":"bilinear","scale":[2,2],"size":null,"align_corners":false"#),
        op("binary", "out0", &["up"], r#""kind":"mul","scalar":1.7"#),
    ];
    let json = model(&["in0", "in1", "in2"], &["out0"], &ops);
    let io = r#"{"kind":"frame_interp","inputs":{"frame0":"in0","frame1":"in1","timestep":"in2"},"output":"out0",
        "color":"rgb","range":[0,1],"pad_multiple":8,"pad_mode":"zero","output_clamp":[0,1]}"#;
    let (wd, ht) = (21u32, 13u32);
    let rgb: Vec<Vec<u8>> = (0..2).map(|_| (0..wd * ht * 3).map(|_| ((r.next() + 1.0) * 127.9) as u8).collect()).collect();
    let cpu = Reference::from_parts(json.as_bytes(), &w.0, Some(io.as_bytes())).unwrap();
    let frame = |d: &Vec<u8>| gpufx_nnconv::frames::Rgb8 { w: wd as usize, h: ht as usize, data: d.clone() };
    let want = gpufx_nnconv::frames::interpolate(&cpu, &frame(&rgb[0]), &frame(&rgb[1]), 0.3).unwrap();

    let model = NnModel::from_parts(ctx, json.as_bytes(), &w.0, Some(io.as_bytes())).unwrap();
    let mut interp = FrameInterp::new(Arc::new(model)).unwrap();
    let rgba: Vec<Vec<u8>> = rgb.iter().map(|d| d.chunks(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect()).collect();
    let got = interp.interpolate(&view(&rgba[0], wd, ht), &view(&rgba[1], wd, ht), 0.3).unwrap();
    let mut off = 0;
    for (i, p) in got.chunks(4).enumerate() {
        assert_eq!(p[3], 255);
        for (c, (&g, &w)) in p[..3].iter().zip(&want.data[i * 3..i * 3 + 3]).enumerate() {
            let d = (g as i32 - w as i32).abs();
            assert!(d <= 1, "pixel {i} channel {c}: gpu {g} cpu {w}");
            off += d;
        }
    }
    // a value sitting on a rounding edge may differ by one, rarely
    assert!(off <= 2, "{off} values differ by one");
    let clamped = want.data.iter().filter(|&&v| v == 0 || v == 255).count();
    assert!(clamped > 0, "the test should exercise the clamp");
}

fn view(data: &[u8], width: u32, height: u32) -> Image<'_> {
    Image { data, width, height, stride: width * 4 }
}

fn load_rgba(path: &std::path::Path) -> image::RgbaImage {
    image::open(path).unwrap_or_else(|e| panic!("{}: {e}", path.display())).to_rgba8()
}

fn psnr_rgb(a: &[u8], b: &image::RgbaImage) -> f64 {
    let b = b.as_raw();
    let mut sum = 0.0;
    let mut n = 0;
    for (p, q) in a.chunks(4).zip(b.chunks(4)) {
        for c in 0..3 {
            sum += (p[c] as f64 - q[c] as f64).powi(2);
            n += 1;
        }
    }
    let mse = sum / n as f64;
    if mse == 0.0 {
        f64::INFINITY
    } else {
        10.0 * (255.0f64 * 255.0 / mse).log10()
    }
}

/// RIFE v4.6 on the GPU against the CPU reference output of the same frames:
/// `GPUFX_RIFE_PKG=<rife-v4.6.zip> GPUFX_RIFE_TESTDIR=<dir with A_0.png A_2.png A_ref.png, same for B>`.
#[test]
#[ignore = "needs GPUFX_RIFE_PKG and GPUFX_RIFE_TESTDIR"]
fn rife_matches_the_cpu_reference() {
    let Some(ctx) = gpu() else { return };
    let pkg = std::env::var("GPUFX_RIFE_PKG").expect("GPUFX_RIFE_PKG");
    let dir = std::path::PathBuf::from(std::env::var("GPUFX_RIFE_TESTDIR").expect("GPUFX_RIFE_TESTDIR"));
    let model = NnModel::load(ctx.clone(), &pkg).unwrap();
    let mut interp = FrameInterp::new(Arc::new(model)).unwrap();
    for set in ["A", "B"] {
        let (a, b) = (load_rgba(&dir.join(format!("{set}_0.png"))), load_rgba(&dir.join(format!("{set}_2.png"))));
        let reference = load_rgba(&dir.join(format!("{set}_ref.png")));
        let out = interp.interpolate(&view(&a, a.width(), a.height()), &view(&b, b.width(), b.height()), 0.5).unwrap();
        let db = psnr_rgb(&out, &reference);
        eprintln!("{set}: {db:.2} dB against the CPU reference on {}", ctx.description());
        assert!(db > 50.0, "{set}: {db:.2} dB");
    }
}

// ---- InterpFrames (the stage behind the FFmpeg filter): the scene check ----

const FW: u32 = 64;
const FH: u32 = 16;

/// A frame_interp model of one 1x1 convolution (output is not a source frame), on frames of `FW`x`FH`.
fn interp_frames(ctx: &Arc<GpuContext>, scene: f32) -> InterpFrames {
    let (mut w, mut r) = (Weights::default(), Rng(7));
    let ops = vec![
        op("concat", "cat", &["in0", "in1", "in2"], r#""axis":0"#),
        conv(&mut w, &mut r, "conv2d", "c", "cat", 7, 3, [1, 1], [1, 1], [1, 1], [0, 0, 0, 0], [0, 0], "null"),
        op("binary", "out0", &["c"], r#""kind":"add","scalar":0.5"#),
    ];
    let json = model(&["in0", "in1", "in2"], &["out0"], &ops);
    let io = r#"{"kind":"frame_interp","inputs":{"frame0":"in0","frame1":"in1","timestep":"in2"},"output":"out0",
        "color":"rgb","range":[0,1],"pad_multiple":1,"pad_mode":"zero","output_clamp":[0,1]}"#;
    let m = NnModel::from_parts(ctx.clone(), json.as_bytes(), &w.0, Some(io.as_bytes())).unwrap();
    let mut fi = InterpFrames::new(ctx.clone(), Arc::new(m)).unwrap();
    fi.set_scene_threshold(scene).unwrap();
    fi
}

fn gpu_frame(ctx: &GpuContext, usage: wgpu::TextureUsages, data: Option<&[u8]>) -> GpuFrame {
    let tex = rgba_texture(ctx, FW, FH, usage);
    if let Some(data) = data {
        ctx.queue().write_texture(
            tex.as_image_copy(),
            data,
            wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(FW * 4), rows_per_image: Some(FH) },
            wgpu::Extent3d { width: FW, height: FH, depth_or_array_layers: 1 },
        );
    }
    let color = ColorInfo { matrix: Matrix::Bt709, range: Range::Full, ..Default::default() };
    GpuFrame { format: PixelFormat::Rgba, width: FW, height: FH, planes: vec![tex], color }
}

fn read_frame(ctx: &GpuContext, f: &GpuFrame) -> Vec<u8> {
    let buf = ctx.device().create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: (FW * FH * 4) as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let mut enc = ctx.device().create_command_encoder(&Default::default());
    enc.copy_texture_to_buffer(
        f.planes[0].as_image_copy(),
        wgpu::TexelCopyBufferInfo {
            buffer: &buf,
            layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(FW * 4), rows_per_image: None },
        },
        f.planes[0].size(),
    );
    ctx.queue().submit([enc.finish()]);
    buf.slice(..).map_async(wgpu::MapMode::Read, |r| r.unwrap());
    ctx.device().poll(wgpu::PollType::wait_indefinitely()).unwrap();
    let out = buf.slice(..).get_mapped_range().unwrap().to_vec();
    out
}

/// One call: `src` as the next source frame, the frames in between at `times`.
fn call(ctx: &Arc<GpuContext>, fi: &mut InterpFrames, src: &[u8], times: &[f32]) -> Result<Vec<Vec<u8>>, gpufx_core::Error> {
    let input = gpu_frame(ctx, wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST, Some(src));
    let outs: Vec<GpuFrame> =
        times.iter().map(|_| gpu_frame(ctx, wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC, None)).collect();
    fi.set_times(times)?;
    let mut enc = ctx.device().create_command_encoder(&Default::default());
    fi.encode_frames(&input, &outs, &mut enc)?;
    ctx.queue().submit([enc.finish()]);
    Ok(outs.iter().map(|o| read_frame(ctx, o)).collect())
}

/// A bright gradient and a black frame: a pair of them is a cut at any threshold used here.
fn bright() -> Vec<u8> {
    (0..FW * FH).flat_map(|i| [(190 + (i % FW) * 2) as u8, (200 + (i / FW) * 3) as u8, 220, 255]).collect()
}

fn black() -> Vec<u8> {
    [0u8, 0, 0, 255].repeat((FW * FH) as usize)
}

/// A frame of `f(x, y)` in [0, 1] on every channel (green and blue scaled down), RGBA8.
fn pattern(f: impl Fn(f64, f64) -> f64) -> Vec<u8> {
    (0..FW * FH)
        .flat_map(|i| {
            let v = f((i % FW) as f64, (i / FW) as f64).clamp(0.0, 1.0);
            [(v * 255.0).round() as u8, (v * 230.0).round() as u8, (v * 200.0).round() as u8, 255]
        })
        .collect()
}

/// The scene check of the official RIFE inference_video.py on the CPU: both frames to 32x32 as
/// F.interpolate(bilinear, align_corners=False) does (2x2 taps, no antialias), then ssim_matlab of
/// model/pytorch_msssim: an 11x11x11 gaussian (sigma 1.5) over the 32x32x3 volume with replicate padding,
/// C1 = 0.01^2, C2 = 0.03^2, the SSIM map averaged.
fn ssim_ref(a: &[u8], b: &[u8], w: u32, h: u32) -> f64 {
    const N: usize = 32;
    let down = |img: &[u8]| -> Vec<f64> {
        let coord = |o: usize, size: u32| {
            let s = ((o as f64 + 0.5) * size as f64 / N as f64 - 0.5).max(0.0);
            let i0 = (s as usize).min(size as usize - 1);
            (i0, (i0 + 1).min(size as usize - 1), s - i0 as f64)
        };
        let px = |x: usize, y: usize, c: usize| img[(y * w as usize + x) * 4 + c] as f64 / 255.0;
        let mut v = vec![0.0; 3 * N * N];
        for c in 0..3 {
            for oy in 0..N {
                let (y0, y1, ly) = coord(oy, h);
                for ox in 0..N {
                    let (x0, x1, lx) = coord(ox, w);
                    v[(c * N + oy) * N + ox] = (1.0 - ly) * ((1.0 - lx) * px(x0, y0, c) + lx * px(x1, y0, c))
                        + ly * ((1.0 - lx) * px(x0, y1, c) + lx * px(x1, y1, c));
                }
            }
        }
        v
    };
    let g: Vec<f64> = {
        let raw: Vec<f64> = (0..11).map(|k| (-((k - 5) as f64).powi(2) / 4.5).exp()).collect();
        let sum: f64 = raw.iter().sum();
        raw.iter().map(|v| v / sum).collect()
    };
    let at = |i: usize, k: usize, size: usize| (i as i64 + k as i64 - 5).clamp(0, size as i64 - 1) as usize;
    // The 3D window applied directly (not separated), as F.conv3d does.
    let blur = |v: &[f64]| -> Vec<f64> {
        let mut out = vec![0.0; v.len()];
        for c in 0..3 {
            for y in 0..N {
                for x in 0..N {
                    let mut s = 0.0;
                    for (kc, gc) in g.iter().enumerate() {
                        for (ky, gy) in g.iter().enumerate() {
                            for (kx, gx) in g.iter().enumerate() {
                                s += gc * gy * gx * v[(at(c, kc, 3) * N + at(y, ky, N)) * N + at(x, kx, N)];
                            }
                        }
                    }
                    out[(c * N + y) * N + x] = s;
                }
            }
        }
        out
    };
    let (x, y) = (down(a), down(b));
    let prod = |p: &[f64], q: &[f64]| -> Vec<f64> { p.iter().zip(q).map(|(p, q)| p * q).collect() };
    let (mu1, mu2) = (blur(&x), blur(&y));
    let (e11, e22, e12) = (blur(&prod(&x, &x)), blur(&prod(&y, &y)), blur(&prod(&x, &y)));
    let (c1, c2) = (0.01f64.powi(2), 0.03f64.powi(2));
    let sum: f64 = (0..x.len())
        .map(|i| {
            let (m1, m2) = (mu1[i], mu2[i]);
            let v1 = 2.0 * (e12[i] - m1 * m2) + c2;
            let v2 = (e11[i] - m1 * m1) + (e22[i] - m2 * m2) + c2;
            (2.0 * m1 * m2 + c1) * v1 / ((m1 * m1 + m2 * m2 + c1) * v2)
        })
        .sum();
    sum / x.len() as f64
}

/// Whether the pair `a` -> `b` is a cut at `threshold`: on a cut the frame at time 0.3 is `a` itself.
fn is_cut(ctx: &Arc<GpuContext>, threshold: f32, a: &[u8], b: &[u8]) -> bool {
    let mut fi = interp_frames(ctx, threshold);
    call(ctx, &mut fi, a, &[]).unwrap();
    let out = call(ctx, &mut fi, b, &[0.3]).unwrap().remove(0);
    let mut reference = interp_frames(ctx, 0.0);
    call(ctx, &mut reference, a, &[]).unwrap();
    let interpolated = call(ctx, &mut reference, b, &[0.3]).unwrap().remove(0);
    assert!(interpolated != a, "the model should not return a source frame");
    assert!(out == a || out == interpolated, "either the nearer source frame or the interpolated one");
    out == a
}

fn random_frame(r: &mut Rng) -> Vec<u8> {
    (0..FW * FH * 4).map(|i| if i % 4 == 3 { 255 } else { ((r.next() + 1.0) * 127.0) as u8 }).collect()
}

/// The GPU check against the CPU port of RIFE's: on pairs over the whole SSIM range, a threshold just above
/// the reference SSIM makes a cut and one just below does not.
#[test]
fn scene_check_matches_the_rife_ssim() {
    let Some(ctx) = gpu() else { return };
    let mut r = Rng(11);
    let (a, noise) = (random_frame(&mut r), random_frame(&mut r));
    let mut seen = Vec::new();
    for k in [0.05, 0.2, 0.4, 0.6, 0.8, 0.95] {
        let b: Vec<u8> = a.iter().zip(&noise).map(|(&p, &q)| (p as f64 * (1.0 - k) + q as f64 * k).round() as u8).collect();
        let s = ssim_ref(&a, &b, FW, FH);
        seen.push(s);
        assert!(is_cut(&ctx, (s + 0.002).min(1.0) as f32, &a, &b), "SSIM {s:.4}: a cut just above it");
        if s > 0.002 {
            assert!(!is_cut(&ctx, (s - 0.002) as f32, &a, &b), "SSIM {s:.4}: no cut just below it");
        }
    }
    assert!(seen.iter().any(|&s| s > 0.8) && seen.iter().any(|&s| s < 0.3), "the pairs span the range: {seen:?}");
}

/// Two different patterns of the same mean brightness (waves of another direction and period) are a cut. The
/// previous check (FFmpeg framerate's mean luma difference, in percent) scores this pair below its default
/// 20: it missed such cuts.
#[test]
fn same_brightness_different_content_is_a_cut() {
    let Some(ctx) = gpu() else { return };
    let tau = std::f64::consts::TAU;
    let a = pattern(|x, _| 0.5 + 0.2 * (x * tau / 16.0).sin());
    let b = pattern(|x, y| 0.5 + 0.2 * ((x + y) * tau / 6.0).cos());
    let luma = |p: &[u8]| p.chunks(4).map(|p| 0.299 * p[0] as f64 + 0.587 * p[1] as f64 + 0.114 * p[2] as f64).collect::<Vec<_>>();
    let (la, lb) = (luma(&a), luma(&b));
    let mean = |v: &[f64]| v.iter().sum::<f64>() / v.len() as f64;
    assert!((mean(&la) - mean(&lb)).abs() < 1.0, "same mean brightness");
    let mafd = la.iter().zip(&lb).map(|(p, q)| (p - q).abs()).sum::<f64>() / la.len() as f64 * 100.0 / 255.0;
    assert!(mafd < 20.0, "the old score {mafd:.2} would not have cut");
    let s = ssim_ref(&a, &b, FW, FH);
    assert!(s < 0.2, "SSIM {s:.4}");
    assert!(is_cut(&ctx, 0.2, &a, &b), "a cut at RIFE's 0.2");
}

/// A textured frame moved by a pixel is motion, not a cut.
#[test]
fn a_small_translation_is_not_a_cut() {
    let Some(ctx) = gpu() else { return };
    let tex =
        |dx: f64| move |x: f64, y: f64| 0.5 + 0.2 * ((x - dx) * 0.7).sin() * (y * 0.9).cos() + 0.15 * ((x - dx) * 0.23 + y * 0.31).sin();
    let (a, b) = (pattern(tex(0.0)), pattern(tex(1.0)));
    let s = ssim_ref(&a, &b, FW, FH);
    assert!(s > 0.5, "SSIM {s:.4}");
    assert!(!is_cut(&ctx, 0.2, &a, &b), "no cut at RIFE's 0.2");
}

#[test]
fn scene_threshold_is_an_ssim() {
    let Some(ctx) = gpu() else { return };
    let mut fi = interp_frames(&ctx, 1.0);
    assert!(fi.set_scene_threshold(1.5).is_err());
    assert!(fi.set_scene_threshold(-0.1).is_err());
    assert!(fi.set_scene_threshold(0.2).is_ok());
}

/// A first call that makes only a copy (time 1) has no pair; the first pair is then checked on its own.
#[test]
fn a_first_call_at_time_one_checks_no_pair() {
    let Some(ctx) = gpu() else { return };
    let (a, b) = (bright(), black());
    let mut fi = interp_frames(&ctx, 0.2);
    assert!(call(&ctx, &mut fi, &a, &[1.0]).unwrap()[0] == a, "time 1 is the source frame");
    assert!(call(&ctx, &mut fi, &b, &[0.3]).unwrap()[0] == a, "a cut repeats the nearer source frame");
    assert!(call(&ctx, &mut fi, &a, &[0.7]).unwrap()[0] == a, "a cut repeats the nearer source frame");
}

/// Calls without frames in between only move the previous frame: the next pair is checked on its own, so
/// bright -> black -> bright is a cut each way.
#[test]
fn pairs_without_frames_in_between_keep_the_previous_frame() {
    let Some(ctx) = gpu() else { return };
    let (a, b) = (bright(), black());
    let mut fi = interp_frames(&ctx, 0.2);
    call(&ctx, &mut fi, &a, &[]).unwrap();
    call(&ctx, &mut fi, &b, &[]).unwrap();
    assert!(call(&ctx, &mut fi, &a, &[0.3]).unwrap()[0] == b, "a cut: the nearer source frame");
}

/// After a reset the previous frame is gone: time below 1 fails, time 1 works, the next pair is checked.
#[test]
fn reset_forgets_the_previous_frame() {
    let Some(ctx) = gpu() else { return };
    let (a, b) = (bright(), black());
    let mut fi = interp_frames(&ctx, 0.2);
    call(&ctx, &mut fi, &a, &[]).unwrap();
    call(&ctx, &mut fi, &b, &[]).unwrap();
    assert!(fi.has_previous());
    fi.reset();
    assert!(!fi.has_previous());
    assert!(call(&ctx, &mut fi, &a, &[0.3]).is_err(), "no previous frame");
    assert!(call(&ctx, &mut fi, &a, &[1.0]).unwrap()[0] == a, "time 1 is the source frame");
    assert!(call(&ctx, &mut fi, &b, &[0.3]).unwrap()[0] == a, "a cut after a reset");
}
