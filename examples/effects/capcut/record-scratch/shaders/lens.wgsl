// Record Scratch: pincushion lens distortion that swells and relaxes with the move.

// One cubic Bezier segment of a keyframed track: (x1, y1) and (x4, y4) are the
// keys, (x2, y2) and (x3, y3) the handles, all in (time, value) space.
// The time is solved by bisection, then the value is read off the curve.
fn bez(q: f32, a: f32, b: f32, c: f32, d: f32) -> f32 {
    let p = 1.0 - q;
    return a * p * p * p + 3.0 * b * p * p * q + 3.0 * c * p * q * q + d * q * q * q;
}

fn segment(x: f32, x1: f32, x2: f32, x3: f32, x4: f32, y1: f32, y2: f32, y3: f32, y4: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 17; i++) {
        let mid = (lo + hi) * 0.5;
        if (bez(mid, x1, x2, x3, x4) > x) { hi = mid; } else { lo = mid; }
    }
    return bez((lo + hi) * 0.5, y1, y2, y3, y4);
}

// The animation clock: progress 0..1 maps onto 15/30 .. 32/30 s of the source timeline.
fn clock(t: f32) -> f32 {
    return mix(15.0 / 30.0, 32.0 / 30.0, t);
}

// Lens field of view in degrees: 0 -> 27 -> 0.
fn fov(x: f32) -> f32 {
    if (x <= 0.5 || x >= 1.0666667) { return 0.0; }
    if (x < 0.7333333) { return segment(x, 0.5, 0.6627962, 0.6555556, 0.7333333, 0.0, -0.0325047, 27.0, 27.0); }
    return segment(x, 0.7333333, 0.8242020, 0.8138584, 1.0666667, 27.0, 26.981857, 0.0609910, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    let f = clamp(fov(clock(t)), 0.0, 180.0) / 180.0;
    let k1 = 14.77 * pow(f, 10.0) + 2.7 * f * f * f;
    let k2 = 3.82 * pow(f, 2.54) + 0.529 * f;
    let d = uv - 0.5;
    let s = vec2f(d.x, d.y * globals.size.y / globals.size.x);
    let r2 = dot(s, s);
    let k = 1.0 / (1.0 + k1 * sqrt(r2) + k2 * r2);
    let q = 0.5 + d * k;
    var c = vec4f(0.0);
    if (k > 0.0 && all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
        c = textureSampleLevel(slid, smp, q, 0.0);
    }
    gpufx_write(id, c);
}
