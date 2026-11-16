// Max or average pooling of gpufx-nn (see `pool` in reference.rs): one invocation per output element. A window
// counts only the pixels inside the input; average with `include_pad` divides by the whole kernel. Global
// pooling is a window of the whole plane.

struct P {
    n: u32,
    ih: u32,
    iw: u32,
    oh: u32,
    ow: u32,
    kh: u32,
    kw: u32,
    sh: u32,
    sw: u32,
    pad_t: u32,
    pad_l: u32,
    is_max: u32,
    include_pad: u32,
    in_off: u32,
    out_off: u32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> src0: array<f32>;
@group(0) @binding(5) var<storage, read_write> dst: array<f32>;

@compute @workgroup_size(256)
fn main(@builtin(workgroup_id) wg: vec3u, @builtin(num_workgroups) nwg: vec3u, @builtin(local_invocation_index) li: u32) {
    let i = (wg.y * nwg.x + wg.x) * 256u + li;
    if (i >= p.n) {
        return;
    }
    let plane = p.oh * p.ow;
    let c = i / plane;
    let r = i % plane;
    let oy = r / p.ow;
    let ox = r % p.ow;
    let base = p.in_off + c * p.ih * p.iw;
    let y0 = i32(oy * p.sh) - i32(p.pad_t);
    let x0 = i32(ox * p.sw) - i32(p.pad_l);
    let ya = u32(max(y0, 0));
    let xa = u32(max(x0, 0));
    let yb = u32(min(y0 + i32(p.kh), i32(p.ih)));
    let xb = u32(min(x0 + i32(p.kw), i32(p.iw)));
    var acc = 0.0;
    var m = -3.402823e38;
    for (var y = ya; y < yb; y++) {
        for (var x = xa; x < xb; x++) {
            let v = src0[base + y * p.iw + x];
            acc += v;
            m = max(m, v);
        }
    }
    var v = m;
    if (p.is_max == 0u) {
        var d = f32((yb - ya) * (xb - xa));
        if (p.include_pad != 0u) {
            d = f32(p.kh * p.kw);
        }
        v = acc / max(d, 1.0);
    }
    dst[p.out_off + i] = v;
}
