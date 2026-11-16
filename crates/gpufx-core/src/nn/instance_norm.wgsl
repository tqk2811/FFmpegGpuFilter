// Instance normalization of gpufx-nn (see `instance_norm` in reference.rs): one workgroup per channel. Two
// passes over the plane, the mean then the variance around it (biased), then the normalized write with the
// optional per-channel gamma and beta (at wf[g_off + c], wf[b_off + c]).

struct P {
    c: u32,
    plane: u32,
    in_off: u32,
    out_off: u32,
    affine: u32,
    g_off: u32,
    b_off: u32,
    eps: f32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> src0: array<f32>;
@group(0) @binding(4) var<storage, read> wf: array<f32>;
@group(0) @binding(5) var<storage, read_write> dst: array<f32>;

var<workgroup> part: array<f32, 256>;

fn reduce(li: u32, v: f32) -> f32 {
    part[li] = v;
    workgroupBarrier();
    for (var s = 128u; s > 0u; s >>= 1u) {
        if (li < s) {
            part[li] += part[li + s];
        }
        workgroupBarrier();
    }
    let total = part[0];
    workgroupBarrier();
    return total;
}

@compute @workgroup_size(256)
fn main(@builtin(workgroup_id) wg: vec3u, @builtin(local_invocation_index) li: u32) {
    let c = wg.x;
    let base = p.in_off + c * p.plane;
    var s = 0.0;
    for (var i = li; i < p.plane; i += 256u) {
        s += src0[base + i];
    }
    let mean = reduce(li, s) / f32(p.plane);
    var q = 0.0;
    for (var i = li; i < p.plane; i += 256u) {
        let d = src0[base + i] - mean;
        q += d * d;
    }
    let var_ = reduce(li, q) / f32(p.plane);
    var k = inverseSqrt(var_ + p.eps);
    var b = -mean * k;
    if (p.affine != 0u) {
        let g = wf[p.g_off + c];
        k *= g;
        b = b * g + wf[p.b_off + c];
    }
    let ob = p.out_off + c * p.plane;
    for (var i = li; i < p.plane; i += 256u) {
        dst[ob + i] = src0[base + i] * k + b;
    }
}
