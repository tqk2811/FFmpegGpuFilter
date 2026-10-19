//! WGSL of the gpufx-nn ops and their pipelines. The fixed ops are `.wgsl` files next to this one; the
//! convolutions are generated per kernel shape so that every loop over the kernel and the register block is
//! unrolled with constant indices (accumulators stay in registers).
//!
//! Every op shares one bind group layout: 0 the op parameters (uniform), 1 and 2 read-only tensors, 3 and 4
//! the weights (as `vec4<f32>` and as `f32`), 5 the output tensor.

use std::collections::HashMap;
use std::fmt::Write;
use std::sync::Arc;

use crate::shader_cache::{PipelineDesc, ShaderCache};

/// Bytes of the per-dispatch parameter slot in the uniform buffer.
pub(crate) const PARAM_SLOT: u64 = 256;

/// The register-blocked direct convolution of one kernel shape.
///
/// A workgroup is `tx x ty` threads and computes `ocb` output channels of a `tx * px` by `ty` output tile.
/// Each thread computes `px` pixels of one row (`tx` apart, so neighbouring threads touch neighbouring
/// addresses) for all `ocb` channels: `px * ocb / 4` `vec4` accumulators. Input channels are processed `cic` at
/// a time: the input tile they need and their weights are first copied to workgroup memory.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) struct ConvShape {
    pub kh: u32,
    pub kw: u32,
    pub sh: u32,
    pub sw: u32,
    pub dh: u32,
    pub dw: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) struct ConvConfig {
    pub tx: u32,
    pub ty: u32,
    pub px: u32,
    /// Output channels per workgroup, a multiple of 4. Also the block size of the weight layout.
    pub ocb: u32,
    pub cic: u32,
}

/// Workgroup memory budget in bytes (the WebGPU default limit is 16384).
const SHARED_BUDGET: u32 = 16384;

impl ConvConfig {
    fn tile(&self, s: &ConvShape) -> (u32, u32) {
        let ow = self.tx * self.px;
        let oh = self.ty;
        ((oh - 1) * s.sh + (s.kh - 1) * s.dh + 1, (ow - 1) * s.sw + (s.kw - 1) * s.dw + 1)
    }

    fn shared_bytes(&self, s: &ConvShape) -> u32 {
        let (th, tw) = self.tile(s);
        (self.cic * th * tw + self.cic * s.kh * s.kw * self.ocb) * 4
    }

    /// Output channels per workgroup for `cout` channels: the block size of the weight layout, fixed when the
    /// package is loaded.
    pub fn ocb(cout: u32) -> u32 {
        match cout {
            0..=8 => 8,
            9..=16 => 16,
            _ => 32,
        }
    }

    /// The configuration for an output of `w x h x cout`: the largest tile whose workgroup memory fits, unless
    /// it leaves too few workgroups to fill the GPU (small outputs), then a smaller one. Measured on an RTX
    /// 4060 Laptop: 2 pixels x 32 channels per thread beat 4 x 16 and 4 x 32 (register pressure).
    /// `GPUFX_NN_CONV=tx,ty,px,cic` puts a tile first, for tuning.
    pub fn choose(s: &ConvShape, ocb: u32, w: u32, h: u32, cout: u32) -> Option<ConvConfig> {
        let min_wg: u32 = std::env::var("GPUFX_NN_MINWG").ok().and_then(|v| v.parse().ok()).unwrap_or(64);
        let mut tiles = vec![(16, 8, 2), (8, 8, 2), (8, 4, 2), (4, 4, 2), (4, 4, 1)];
        let mut cics = vec![8, 4, 2, 1];
        if let Ok(v) = std::env::var("GPUFX_NN_CONV") {
            let n: Vec<u32> = v.split(',').filter_map(|x| x.trim().parse().ok()).collect();
            if n.len() == 4 && n[..3].iter().all(|&v| v > 0) {
                tiles.insert(0, (n[0], n[1], n[2]));
                cics.retain(|&c| c <= n[3].max(1));
            }
        }
        let fits = tiles.iter().filter_map(|&(tx, ty, px)| {
            cics.iter().map(|&cic| ConvConfig { tx, ty, px, ocb, cic }).find(|c| c.shared_bytes(s) <= SHARED_BUDGET)
        });
        let mut last = None;
        for c in fits {
            let groups = w.div_ceil(c.tx * c.px) * h.div_ceil(c.ty) * cout.div_ceil(ocb);
            if groups >= min_wg {
                return Some(c);
            }
            last = Some(c);
        }
        last
    }

    /// The old fixed choice, kept for the shader validation test.
    #[cfg(test)]
    fn any(s: &ConvShape) -> Option<ConvConfig> {
        Self::choose(s, 32, 4096, 4096, 64)
    }
}

/// The configuration of transposed convolutions: one output pixel per thread, `ocb` channels per workgroup,
/// the weights of `cq` input channels at a time in workgroup memory.
pub(crate) const DECONV_WG: u32 = 64;
pub(crate) const DECONV_OCB: u32 = 8;

fn deconv_cq(s: &ConvShape) -> u32 {
    let per = s.kh * s.kw * DECONV_OCB * 4;
    (SHARED_BUDGET / per).clamp(1, 32)
}

const COMMON: &str = "
@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> src0: array<f32>;
@group(0) @binding(2) var<storage, read> src1: array<f32>;
@group(0) @binding(3) var<storage, read> wv: array<vec4f>;
@group(0) @binding(4) var<storage, read> wf: array<f32>;
@group(0) @binding(5) var<storage, read_write> dst: array<f32>;

// The activation of output channels co..co + 4: 0 none, 1 relu, 2 leaky relu (slope a), 3 sigmoid, 4 prelu
// (slopes at wf[soff + c], one shared slope when sn == 1), 5 clip to [a, b].
fn act(v: vec4f, kind: u32, a: f32, b: f32, soff: u32, sn: u32, co: u32) -> vec4f {
    switch kind {
        case 1u: { return max(v, vec4f(0.0)); }
        case 2u: { return select(a * v, v, v >= vec4f(0.0)); }
        case 3u: { return 1.0 / (1.0 + exp(-v)); }
        case 4u: {
            var s = vec4f(wf[soff]);
            if (sn != 1u) {
                // channels past the last (cout not a multiple of 4) are not written: read the last slope
                let l = sn - 1u;
                s = vec4f(wf[soff + min(co, l)], wf[soff + min(co + 1u, l)], wf[soff + min(co + 2u, l)], wf[soff + min(co + 3u, l)]);
            }
            return select(s * v, v, v >= vec4f(0.0));
        }
        case 5u: { return clamp(v, vec4f(a), vec4f(b)); }
        default: { return v; }
    }
}
";

const CONV_PARAMS: &str = "
struct P {
    cin: u32,
    ih: u32,
    iw: u32,
    cout: u32,
    oh: u32,
    ow: u32,
    pad_t: u32,
    pad_l: u32,
    in_off: u32,
    out_off: u32,
    res_off: u32,
    w_off: u32,
    b_off: u32,
    pre_act: u32,
    has_res: u32,
    post_act: u32,
    pre_slope: f32,
    post_slope: f32,
    pre_b: f32,
    post_b: f32,
    pre_soff: u32,
    pre_sn: u32,
    post_soff: u32,
    post_sn: u32,
}
";

/// The epilogue of one `vec4` of output channels `co..co + 4` at output pixel `(ox, oy)`: bias, the
/// convolution's activation, the residual and the activation after it.
fn epilogue(out: &mut String, acc: &str, co: &str, pix: &str) {
    let _ = writeln!(out, "        {{");
    let _ = writeln!(out, "            let co = {co};");
    let _ = writeln!(
        out,
        "            var v = {acc} + vec4f(wf[p.b_off + co], wf[p.b_off + co + 1u], wf[p.b_off + co + 2u], wf[p.b_off + co + 3u]);"
    );
    let _ = writeln!(out, "            v = act(v, p.pre_act, p.pre_slope, p.pre_b, p.pre_soff, p.pre_sn, co);");
    let _ = writeln!(out, "            let o = p.out_off + co * plane + {pix};");
    let _ = writeln!(out, "            if (p.has_res != 0u) {{");
    let _ = writeln!(out, "                let r = p.res_off + co * plane + {pix};");
    let _ = writeln!(out, "                v += vec4f(src1[r], src1[r + plane], src1[r + 2u * plane], src1[r + 3u * plane]);");
    let _ = writeln!(out, "            }}");
    let _ = writeln!(out, "            v = act(v, p.post_act, p.post_slope, p.post_b, p.post_soff, p.post_sn, co);");
    let _ = writeln!(out, "            for (var j = 0u; j < 4u; j++) {{");
    let _ = writeln!(out, "                if (co + j < p.cout) {{ dst[o + j * plane] = v[j]; }}");
    let _ = writeln!(out, "            }}");
    let _ = writeln!(out, "        }}");
}

/// With `f16`, the input tile, the weights in workgroup memory and the accumulators are `f16` (WGSL `enable f16`,
/// the device needs `SHADER_F16`; the input is clamped to the f16 range); bias, activations and the residual stay
/// `f32`. Accumulating in f32 costs ~55% more time on an RTX 4060 for ~10 dB, so the f16 path assumes the partial
/// sums stay well below 65504 (models on [0, 1] images such as Real-ESRGAN).
pub(crate) fn conv_source(s: &ConvShape, c: &ConvConfig, f16: bool) -> String {
    let (th, tw) = c.tile(s);
    let k = s.kh * s.kw;
    let ocb4 = c.ocb / 4;
    let nt = c.tx * c.ty;
    let tile_len = c.cic * th * tw;
    let wlen = c.cic * k * ocb4;
    let (ht, hv) = if f16 { ("f16", "vec4<f16>") } else { ("f32", "vec4f") };
    let mut o = String::new();
    if f16 {
        o.push_str("enable f16;\n");
    }
    o.push_str(CONV_PARAMS);
    o.push_str(COMMON);
    let _ = writeln!(o, "var<workgroup> tile: array<{ht}, {tile_len}>;");
    let _ = writeln!(o, "var<workgroup> wt: array<{hv}, {wlen}>;");
    let _ = writeln!(o, "@compute @workgroup_size({}, {})", c.tx, c.ty);
    o.push_str(
        "fn main(@builtin(workgroup_id) wg: vec3u, @builtin(local_invocation_id) lid: vec3u, @builtin(local_invocation_index) li: u32) {\n",
    );
    let _ = writeln!(o, "    let ox0 = wg.x * {}u;", c.tx * c.px);
    let _ = writeln!(o, "    let oy0 = wg.y * {}u;", c.ty);
    o.push_str("    let cob = wg.z;\n");
    let _ = writeln!(o, "    let ix0 = i32(ox0 * {}u) - i32(p.pad_l);", s.sw);
    let _ = writeln!(o, "    let iy0 = i32(oy0 * {}u) - i32(p.pad_t);", s.sh);
    o.push_str("    let iplane = p.ih * p.iw;\n");
    for a in 0..ocb4 {
        for q in 0..c.px {
            let _ = writeln!(o, "    var a{a}_{q} = {hv}(0.0);");
        }
    }
    let _ = writeln!(o, "    for (var ci0 = 0u; ci0 < p.cin; ci0 += {}u) {{", c.cic);
    o.push_str("        workgroupBarrier();\n");
    let _ = writeln!(o, "        for (var i = li; i < {tile_len}u; i += {nt}u) {{");
    let _ = writeln!(o, "            let ch = i / {}u;", th * tw);
    let _ = writeln!(o, "            let r = i % {}u;", th * tw);
    let _ = writeln!(o, "            let gy = iy0 + i32(r / {tw}u);");
    let _ = writeln!(o, "            let gx = ix0 + i32(r % {tw}u);");
    o.push_str("            var v = 0.0;\n");
    o.push_str("            if (ci0 + ch < p.cin && gx >= 0 && gy >= 0 && gx < i32(p.iw) && gy < i32(p.ih)) {\n");
    o.push_str("                v = src0[p.in_off + (ci0 + ch) * iplane + u32(gy) * p.iw + u32(gx)];\n");
    o.push_str("            }\n");
    if f16 {
        // beyond the f16 range the value would become infinite
        o.push_str("            tile[i] = f16(clamp(v, -65504.0, 65504.0));\n");
    } else {
        o.push_str("            tile[i] = v;\n");
    }
    o.push_str("        }\n");
    let _ = writeln!(o, "        let wbase = p.w_off + (cob * p.cin + ci0) * {}u;", k * ocb4);
    let _ = writeln!(o, "        let wvalid = min({}u, p.cin - ci0) * {}u;", c.cic, k * ocb4);
    let _ = writeln!(o, "        for (var i = li; i < {wlen}u; i += {nt}u) {{");
    o.push_str("            var w = vec4f(0.0);\n");
    o.push_str("            if (i < wvalid) { w = wv[wbase + i]; }\n");
    let _ = writeln!(o, "            wt[i] = {hv}(w);");
    o.push_str("        }\n");
    o.push_str("        workgroupBarrier();\n");
    let _ = writeln!(o, "        for (var ch = 0u; ch < {}u; ch++) {{", c.cic);
    let _ = writeln!(o, "            let tb = ch * {}u + lid.y * {}u * {tw}u + lid.x * {}u;", th * tw, s.sh, s.sw);
    let _ = writeln!(o, "            let wb = ch * {}u;", k * ocb4);
    for ky in 0..s.kh {
        for kx in 0..s.kw {
            let kk = ky * s.kw + kx;
            for q in 0..c.px {
                let off = ky * s.dh * tw + q * c.tx * s.sw + kx * s.dw;
                let _ = writeln!(o, "            let x{kk}_{q} = tile[tb + {off}u];");
            }
            for a in 0..ocb4 {
                let _ = writeln!(o, "            let w{kk}_{a} = wt[wb + {}u];", kk * ocb4 + a);
                for q in 0..c.px {
                    let _ = writeln!(o, "            a{a}_{q} = fma(w{kk}_{a}, {hv}(x{kk}_{q}), a{a}_{q});");
                }
            }
        }
    }
    o.push_str("        }\n");
    o.push_str("    }\n");
    o.push_str("    let plane = p.oh * p.ow;\n");
    o.push_str("    let oy = oy0 + lid.y;\n");
    o.push_str("    if (oy >= p.oh) { return; }\n");
    for q in 0..c.px {
        let _ = writeln!(o, "    let px{q} = ox0 + lid.x + {}u;", q * c.tx);
        let _ = writeln!(o, "    if (px{q} < p.ow) {{");
        for a in 0..ocb4 {
            epilogue(&mut o, &format!("vec4f(a{a}_{q})"), &format!("cob * {}u + {}u", c.ocb, a * 4), &format!("oy * p.ow + px{q}"));
        }
        o.push_str("    }\n");
    }
    o.push_str("}\n");
    o
}

/// Transposed convolution as a gather, split by output phase: a thread computes the `sh x sw` output pixels
/// `(by * sh + r, bx * sw + c)`. Output row `y` takes input row `i` through tap `ky` when
/// `y + pad_top - ky * dh = i * sh` (the scatter of `docs/NN_MODEL_FORMAT.md` turned around); with
/// `y = by * sh + r` that is `i = by + pad_top / sh + (r + pad_top % sh - ky * dh) / sh`, exact for the taps
/// whose numerator divides, so each phase uses a fixed set of taps known here (`rt`, `rl`: the pads modulo the
/// stride). The input values a thread needs are loaded once per input channel and shared by its phases.
pub(crate) fn deconv_source(s: &ConvShape, rt: u32, rl: u32) -> String {
    let k = s.kh * s.kw;
    let ocb4 = DECONV_OCB / 4;
    let cq = deconv_cq(s);
    let wlen = cq * k * ocb4;
    // per phase: the taps it uses and their input offsets (relative to the block)
    let taps = |phases: u32, res: u32, kn: u32, dil: u32, st: u32| -> Vec<Vec<(u32, i32)>> {
        (0..phases)
            .map(|r| {
                (0..kn)
                    .filter_map(|kk| {
                        let num = (r + res) as i32 - (kk * dil) as i32;
                        (num.rem_euclid(st as i32) == 0).then_some((kk, num.div_euclid(st as i32)))
                    })
                    .collect()
            })
            .collect()
    };
    let ty = taps(s.sh, rt, s.kh, s.dh, s.sh);
    let tx = taps(s.sw, rl, s.kw, s.dw, s.sw);
    let mut offs_y: Vec<i32> = ty.iter().flatten().map(|t| t.1).collect();
    let mut offs_x: Vec<i32> = tx.iter().flatten().map(|t| t.1).collect();
    for v in [&mut offs_y, &mut offs_x] {
        v.sort();
        v.dedup();
    }
    let name = |v: i32| if v < 0 { format!("m{}", -v) } else { format!("p{v}") };
    let mut o = String::new();
    o.push_str(CONV_PARAMS);
    o.push_str(COMMON);
    let _ = writeln!(o, "var<workgroup> wt: array<vec4f, {wlen}>;");
    let _ = writeln!(o, "@compute @workgroup_size({DECONV_WG})");
    o.push_str(
        "fn main(@builtin(workgroup_id) wg: vec3u, @builtin(num_workgroups) nwg: vec3u, @builtin(local_invocation_index) li: u32) {\n",
    );
    o.push_str("    let plane = p.oh * p.ow;\n");
    let _ = writeln!(o, "    let bw = (p.ow + {}u) / {}u;", s.sw - 1, s.sw);
    let _ = writeln!(o, "    let bh = (p.oh + {}u) / {}u;", s.sh - 1, s.sh);
    let _ = writeln!(o, "    let blk = (wg.y * nwg.x + wg.x) * {DECONV_WG}u + li;");
    o.push_str("    let cob = wg.z;\n");
    o.push_str("    let inside = blk < bw * bh;\n");
    o.push_str("    let by = blk / bw;\n");
    o.push_str("    let bx = blk % bw;\n");
    let _ = writeln!(o, "    let iy0 = i32(by + p.pad_t / {}u);", s.sh);
    let _ = writeln!(o, "    let ix0 = i32(bx + p.pad_l / {}u);", s.sw);
    o.push_str("    let iplane = p.ih * p.iw;\n");
    for v in &offs_y {
        let n = name(*v);
        let _ = writeln!(o, "    let ry{n} = iy0 + {v};");
        let _ = writeln!(o, "    let vy{n} = ry{n} >= 0 && ry{n} < i32(p.ih);");
    }
    for v in &offs_x {
        let n = name(*v);
        let _ = writeln!(o, "    let rx{n} = ix0 + {v};");
        let _ = writeln!(o, "    let vx{n} = rx{n} >= 0 && rx{n} < i32(p.iw);");
    }
    for r in 0..s.sh {
        for c in 0..s.sw {
            for a in 0..ocb4 {
                let _ = writeln!(o, "    var a{r}_{c}_{a} = vec4f(0.0);");
            }
        }
    }
    let _ = writeln!(o, "    for (var q0 = 0u; q0 < p.cin; q0 += {cq}u) {{");
    o.push_str("        workgroupBarrier();\n");
    let _ = writeln!(o, "        let wbase = p.w_off + (cob * p.cin + q0) * {}u;", k * ocb4);
    let _ = writeln!(o, "        let wvalid = min({cq}u, p.cin - q0) * {}u;", k * ocb4);
    let _ = writeln!(o, "        for (var i = li; i < {wlen}u; i += {DECONV_WG}u) {{");
    o.push_str("            var w = vec4f(0.0);\n");
    o.push_str("            if (i < wvalid) { w = wv[wbase + i]; }\n");
    o.push_str("            wt[i] = w;\n");
    o.push_str("        }\n");
    o.push_str("        workgroupBarrier();\n");
    o.push_str("        if (inside) {\n");
    let _ = writeln!(o, "            let qn = min({cq}u, p.cin - q0);");
    o.push_str("            for (var q = 0u; q < qn; q++) {\n");
    o.push_str("                let base = p.in_off + (q0 + q) * iplane;\n");
    let _ = writeln!(o, "                let wb = q * {}u;", k * ocb4);
    for vy in &offs_y {
        for vx in &offs_x {
            let (ny, nx) = (name(*vy), name(*vx));
            let _ = writeln!(o, "                var x{ny}_{nx} = 0.0;");
            let _ = writeln!(o, "                if (vy{ny} && vx{nx}) {{ x{ny}_{nx} = src0[base + u32(ry{ny}) * p.iw + u32(rx{nx})]; }}");
        }
    }
    for (r, tys) in ty.iter().enumerate() {
        for (c, txs) in tx.iter().enumerate() {
            for (ky, oy) in tys {
                for (kx, ox) in txs {
                    let kk = ky * s.kw + kx;
                    let x = format!("vec4f(x{}_{})", name(*oy), name(*ox));
                    for a in 0..ocb4 {
                        let _ = writeln!(o, "                a{r}_{c}_{a} = fma(wt[wb + {}u], {x}, a{r}_{c}_{a});", kk * ocb4 + a);
                    }
                }
            }
        }
    }
    o.push_str("            }\n");
    o.push_str("        }\n");
    o.push_str("    }\n");
    o.push_str("    if (!inside) { return; }\n");
    for r in 0..s.sh {
        for c in 0..s.sw {
            let _ = writeln!(o, "    let y{r}_{c} = by * {}u + {r}u;", s.sh);
            let _ = writeln!(o, "    let x{r}_{c} = bx * {}u + {c}u;", s.sw);
            let _ = writeln!(o, "    if (y{r}_{c} < p.oh && x{r}_{c} < p.ow) {{");
            for a in 0..ocb4 {
                epilogue(
                    &mut o,
                    &format!("a{r}_{c}_{a}"),
                    &format!("cob * {DECONV_OCB}u + {}u", a * 4),
                    &format!("y{r}_{c} * p.ow + x{r}_{c}"),
                );
            }
            o.push_str("    }\n");
        }
    }
    o.push_str("}\n");
    o
}

/// The fixed (not generated) kernels.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum Fixed {
    Ew,
    Resize,
    Warp,
    PixelShuffle,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum Kernel {
    Fixed(Fixed),
    Conv(ConvShape, ConvConfig),
    /// shape, pad top and left modulo the stride
    Deconv(ConvShape, u32, u32),
}

/// Pipelines of one device, made on first use.
pub(crate) struct Kernels {
    pub layout: wgpu::BindGroupLayout,
    pipeline_layout: wgpu::PipelineLayout,
    cache: Option<Arc<ShaderCache>>,
    /// Convolutions compute in f16 (see [`conv_source`]).
    pub f16: bool,
    pipelines: std::sync::Mutex<HashMap<Kernel, wgpu::ComputePipeline>>,
}

const fn storage(binding: u32, read_only: bool) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Storage { read_only },
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}

pub(crate) const fn uniform_entry(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Uniform,
            has_dynamic_offset: false,
            min_binding_size: wgpu::BufferSize::new(PARAM_SLOT),
        },
        count: None,
    }
}

/// The one bind group layout of every op (see the module comment).
const ENTRIES: [wgpu::BindGroupLayoutEntry; 6] =
    [uniform_entry(0), storage(1, true), storage(2, true), storage(3, true), storage(4, true), storage(5, false)];

pub(crate) fn storage_entry(binding: u32, read_only: bool) -> wgpu::BindGroupLayoutEntry {
    storage(binding, read_only)
}

/// The pipeline of `source` (entry point `main`) through the device's shader cache, so D3D12 keeps the DXIL
/// of these large shaders on disk when `GPUFX_SHADER_CACHE` is set (DXC takes seconds per convolution).
pub(crate) fn compute_pipeline(
    device: &wgpu::Device,
    cache: Option<&ShaderCache>,
    label: &str,
    layout: &wgpu::PipelineLayout,
    entries: &[wgpu::BindGroupLayoutEntry],
    source: String,
) -> wgpu::ComputePipeline {
    let module = naga::front::wgsl::parse_str(&source).unwrap_or_else(|e| panic!("{label}: {}", e.emit_to_string(&source)));
    let desc = PipelineDesc { label, layout, entries, entry: "main" };
    ShaderCache::compute_pipeline(cache, device, &desc, module, &["nn", "main", &source], None)
}

impl Kernels {
    pub fn new(device: &wgpu::Device, cache: Option<Arc<ShaderCache>>, f16: bool) -> Self {
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("gpufx nn"), entries: &ENTRIES });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("gpufx nn"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        Kernels { layout, pipeline_layout, cache, f16, pipelines: Default::default() }
    }

    /// The pipeline of `kernel`, compiled on first use.
    pub fn get(&self, device: &wgpu::Device, kernel: Kernel) -> wgpu::ComputePipeline {
        let mut map = self.pipelines.lock().unwrap_or_else(|e| e.into_inner());
        map.entry(kernel)
            .or_insert_with(|| {
                let (label, source) = match kernel {
                    Kernel::Fixed(Fixed::Ew) => ("gpufx nn ew", include_str!("ew.wgsl").to_string()),
                    Kernel::Fixed(Fixed::Resize) => ("gpufx nn resize", include_str!("resize.wgsl").to_string()),
                    Kernel::Fixed(Fixed::Warp) => ("gpufx nn warp", include_str!("warp.wgsl").to_string()),
                    Kernel::Fixed(Fixed::PixelShuffle) => ("gpufx nn pixel_shuffle", include_str!("pixel_shuffle.wgsl").to_string()),
                    Kernel::Conv(s, c) => ("gpufx nn conv", conv_source(&s, &c, self.f16)),
                    Kernel::Deconv(s, rt, rl) => ("gpufx nn deconv", deconv_source(&s, rt, rl)),
                };
                compute_pipeline(device, self.cache.as_deref(), label, &self.pipeline_layout, &ENTRIES, source)
            })
            .clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(src: &str) {
        let module = naga::front::wgsl::parse_str(src).unwrap_or_else(|e| panic!("{}\n{src}", e.emit_to_string(src)));
        naga::valid::Validator::new(naga::valid::ValidationFlags::all(), naga::valid::Capabilities::SHADER_FLOAT16)
            .validate(&module)
            .unwrap_or_else(|e| panic!("{e:?}"));
    }

    #[test]
    fn generated_shaders_validate() {
        for (k, s) in [(3, 1), (3, 2), (1, 1), (5, 1), (7, 2)] {
            let shape = ConvShape { kh: k, kw: k, sh: s, sw: s, dh: 1, dw: 1 };
            let c = ConvConfig::any(&shape).unwrap();
            parse(&conv_source(&shape, &c, false));
            parse(&conv_source(&shape, &c, true));
            for r in 0..s {
                parse(&deconv_source(&shape, r, (r + 1) % s));
            }
        }
        for src in [
            include_str!("ew.wgsl"),
            include_str!("resize.wgsl"),
            include_str!("warp.wgsl"),
            include_str!("pixel_shuffle.wgsl"),
            include_str!("upscale_in.wgsl"),
            include_str!("upscale_out.wgsl"),
        ] {
            parse(src);
        }
    }
}
