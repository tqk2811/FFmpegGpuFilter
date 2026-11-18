// Cross-correlation of two run-time tensors (Siamese trackers): src0 is the template `c x th x tw`, src1 the
// search `c x sh x sw`. Mode 0, pixelwise: out[i, y, x] = sum_k t[k, i] * s[k, y, x], one channel per template
// pixel i (row major), out the size of the search. Mode 1, depthwise: out[k, y, x] = sum_{i, j} t[k, i, j] *
// s[k, y + i, x + j], "valid" (oh = sh - th + 1). One invocation per output element; the sums run in the
// order of the CPU reference.

struct P {
    mode: u32,
    n: u32,
    out_off: u32,
    t_off: u32,
    s_off: u32,
    c: u32,
    th: u32,
    tw: u32,
    sh: u32,
    sw: u32,
    oh: u32,
    ow: u32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> src0: array<f32>;
@group(0) @binding(2) var<storage, read> src1: array<f32>;
@group(0) @binding(5) var<storage, read_write> dst: array<f32>;

@compute @workgroup_size(256)
fn main(@builtin(workgroup_id) wg: vec3u, @builtin(num_workgroups) nwg: vec3u, @builtin(local_invocation_index) li: u32) {
    let o = (wg.y * nwg.x + wg.x) * 256u + li;
    if (o >= p.n) {
        return;
    }
    let plane = p.oh * p.ow;
    let ch = o / plane;
    let r = o % plane;
    let y = r / p.ow;
    let x = r % p.ow;
    let tp = p.th * p.tw;
    let sp = p.sh * p.sw;
    var sum = 0.0;
    if (p.mode == 0u) {
        for (var k = 0u; k < p.c; k++) {
            sum += src0[p.t_off + k * tp + ch] * src1[p.s_off + k * sp + r];
        }
    } else {
        for (var i = 0u; i < p.th; i++) {
            for (var j = 0u; j < p.tw; j++) {
                sum += src0[p.t_off + ch * tp + i * p.tw + j] * src1[p.s_off + ch * sp + (y + i) * p.sw + x + j];
            }
        }
    }
    dst[p.out_off + o] = sum;
}
