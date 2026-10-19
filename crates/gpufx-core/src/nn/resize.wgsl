// Resize nearest / bilinear / bicubic; the taps of each axis are computed as the CPU reference does
// (gpufx-nnconv src/reference.rs, axis_taps).

struct P {
    // pixels of one output plane
    n: u32,
    c: u32,
    ih: u32,
    iw: u32,
    oh: u32,
    ow: u32,
    in_off: u32,
    out_off: u32,
    mode: u32,
    align: u32,
    // user scale for nearest (0 when the size was given)
    sy: f32,
    sx: f32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> src0: array<f32>;
@group(0) @binding(5) var<storage, read_write> dst: array<f32>;

struct Taps {
    idx: vec4u,
    wt: vec4f,
}

fn taps(d: u32, i: u32, o: u32, scale: f32) -> Taps {
    var t: Taps;
    t.idx = vec4u(0u);
    t.wt = vec4f(0.0);
    let mx = i - 1u;
    if (p.mode == 0u) {
        var s = 0u;
        if (p.align != 0u) {
            if (o > 1u) {
                s = u32(floor(f32(d) * f32(mx) / f32(o - 1u) + 0.5));
            }
        } else {
            var ratio = f32(o) / f32(i);
            if (scale > 0.0) {
                ratio = scale;
            }
            s = u32(floor(f32(d) / ratio));
        }
        t.idx.x = min(s, mx);
        t.wt.x = 1.0;
        return t;
    }
    var src = 0.0;
    if (p.align != 0u) {
        if (o > 1u) {
            src = f32(d) * f32(mx) / f32(o - 1u);
        }
    } else {
        src = (f32(d) + 0.5) * (f32(i) / f32(o)) - 0.5;
    }
    if (p.mode == 1u) {
        let s = clamp(src, 0.0, f32(mx));
        var x0 = u32(floor(s));
        var f = s - f32(x0);
        if (x0 >= mx) {
            x0 = mx;
            f = 0.0;
        }
        t.idx = vec4u(x0, min(x0 + 1u, mx), 0u, 0u);
        t.wt = vec4f(1.0 - f, f, 0.0, 0.0);
        return t;
    }
    let a = -0.75;
    let fl = floor(src);
    let f = src - fl;
    let m = f32(mx);
    t.idx = vec4u(vec4f(clamp(fl - 1.0, 0.0, m), clamp(fl, 0.0, m), clamp(fl + 1.0, 0.0, m), clamp(fl + 2.0, 0.0, m)));
    let c0 = ((a * (f + 1.0) - 5.0 * a) * (f + 1.0) + 8.0 * a) * (f + 1.0) - 4.0 * a;
    let c1 = ((a + 2.0) * f - (a + 3.0)) * f * f + 1.0;
    let g = 1.0 - f;
    let c2 = ((a + 2.0) * g - (a + 3.0)) * g * g + 1.0;
    t.wt = vec4f(c0, c1, c2, 1.0 - c0 - c1 - c2);
    return t;
}

@compute @workgroup_size(256)
fn main(@builtin(workgroup_id) wg: vec3u, @builtin(num_workgroups) nwg: vec3u, @builtin(local_invocation_index) li: u32) {
    let o = (wg.y * nwg.x + wg.x) * 256u + li;
    if (o >= p.n) {
        return;
    }
    let y = o / p.ow;
    let x = o % p.ow;
    // the taps are the same for every channel
    let ty = taps(y, p.ih, p.oh, p.sy);
    let tx = taps(x, p.iw, p.ow, p.sx);
    let iplane = p.ih * p.iw;
    for (var c = 0u; c < p.c; c++) {
        let base = p.in_off + c * iplane;
        var acc = 0.0;
        for (var a = 0; a < 4; a++) {
            if (ty.wt[a] == 0.0) {
                continue;
            }
            let row = base + ty.idx[a] * p.iw;
            var r = 0.0;
            for (var b = 0; b < 4; b++) {
                if (tx.wt[b] != 0.0) {
                    r += tx.wt[b] * src0[row + tx.idx[b]];
                }
            }
            acc += ty.wt[a] * r;
        }
        dst[p.out_off + c * p.n + o] = acc;
    }
}
