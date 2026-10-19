// Elementwise ops of gpufx-nn: binary with broadcast (or a scalar), activations (also prelu and clip),
// weighted sum, copy (concat) and fill. One invocation per output element.

struct P {
    mode: u32,
    n: u32,
    out_off: u32,
    use_scalar: u32,
    oc: u32,
    oh: u32,
    ow: u32,
    a_off: u32,
    ac: u32,
    ah: u32,
    aw: u32,
    b_off: u32,
    bc: u32,
    bh: u32,
    bw: u32,
    scalar: f32,
    ca: f32,
    cb: f32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> src0: array<f32>;
@group(0) @binding(2) var<storage, read> src1: array<f32>;
@group(0) @binding(4) var<storage, read> wf: array<f32>;
@group(0) @binding(5) var<storage, read_write> dst: array<f32>;

fn at_a(c: u32, y: u32, x: u32) -> f32 {
    return src0[p.a_off + ((c % p.ac) * p.ah + y % p.ah) * p.aw + x % p.aw];
}

fn at_b(c: u32, y: u32, x: u32) -> f32 {
    return src1[p.b_off + ((c % p.bc) * p.bh + y % p.bh) * p.bw + x % p.bw];
}

@compute @workgroup_size(256)
fn main(@builtin(workgroup_id) wg: vec3u, @builtin(num_workgroups) nwg: vec3u, @builtin(local_invocation_index) li: u32) {
    let i = (wg.y * nwg.x + wg.x) * 256u + li;
    if (i >= p.n) {
        return;
    }
    if (p.mode == 14u) {
        dst[p.out_off + i] = p.scalar;
        return;
    }
    let plane = p.oh * p.ow;
    let c = i / plane;
    let r = i % plane;
    let y = r / p.ow;
    let x = r % p.ow;
    let a = at_a(c, y, x);
    var b = p.scalar;
    if ((p.use_scalar == 0u && p.mode <= 8u) || p.mode == 13u) {
        b = at_b(c, y, x);
    }
    var v = a;
    switch p.mode {
        case 0u: { v = a + b; }
        case 1u: { v = a - b; }
        case 2u: { v = a * b; }
        case 3u: { v = a / b; }
        case 4u: { v = max(a, b); }
        case 5u: { v = min(a, b); }
        case 6u: { v = pow(a, b); }
        case 7u: { v = b - a; }
        case 8u: { v = b / a; }
        case 9u: { v = a * p.ca; }
        case 10u: { v = max(a, 0.0); }
        case 11u: { v = select(p.scalar * a, a, a >= 0.0); }
        case 12u: { v = 1.0 / (1.0 + exp(-a)); }
        case 13u: { v = a * p.ca + b * p.cb; }
        // prelu: slopes at wf[b_off], bc of them (1: shared)
        case 15u: { v = select(wf[p.b_off + select(c, 0u, p.bc == 1u)] * a, a, a >= 0.0); }
        case 16u: { v = clamp(a, p.ca, p.cb); }
        default: { }
    }
    dst[p.out_off + i] = v;
}
