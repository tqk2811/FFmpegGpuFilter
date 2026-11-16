// The alpha of each model output pixel (`plane` of them, `c` channels at `in_off`) into `dst`: `mode` 0 the value
// clamped to [0, 1], 1 its sigmoid, 2 the softmax over the channels taken at channel `fg`.

struct P {
    plane: u32,
    c: u32,
    in_off: u32,
    mode: u32,
    fg: u32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> src: array<f32>;
@group(0) @binding(2) var<storage, read_write> dst: array<f32>;

@compute @workgroup_size(256)
fn main(@builtin(workgroup_id) wg: vec3u, @builtin(num_workgroups) nwg: vec3u, @builtin(local_invocation_index) li: u32) {
    let i = (wg.y * nwg.x + wg.x) * 256u + li;
    if (i >= p.plane) {
        return;
    }
    var a = 0.0;
    switch p.mode {
        case 1u: { a = 1.0 / (1.0 + exp(-src[p.in_off + p.fg * p.plane + i])); }
        case 2u: {
            var m = src[p.in_off + i];
            for (var k = 1u; k < p.c; k++) {
                m = max(m, src[p.in_off + k * p.plane + i]);
            }
            var s = 0.0;
            for (var k = 0u; k < p.c; k++) {
                s += exp(src[p.in_off + k * p.plane + i] - m);
            }
            a = exp(src[p.in_off + p.fg * p.plane + i] - m) / s;
        }
        default: { a = src[p.in_off + p.fg * p.plane + i]; }
    }
    dst[i] = clamp(a, 0.0, 1.0);
}
