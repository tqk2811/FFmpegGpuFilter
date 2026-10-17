// Record Scratch, last pass: pinch the middle of the picture inward (edges stay put)
// as the clips swap, then let go.

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

// Pinch strength: 0 -> 0.16 -> 0.
fn pinch(x: f32) -> f32 {
    if (x <= 0.5 || x >= 1.0666667) { return 0.0; }
    if (x < 0.7333333) { return -segment(x, 0.5, 0.5777778, 0.6555556, 0.7333333, 0.0, 0.0, -16.0, -16.0) / 100.0; }
    return -segment(x, 0.7333333, 0.8444444, 0.9555556, 1.0666667, -16.0, -16.0, 0.0, 0.0) / 100.0;
}

// How much a point of the flat picture is pulled toward the centre.
fn shrink(p: vec2f, amount: f32) -> f32 {
    let u = p * 0.5 + 0.5;
    return mix(1.0, 0.25, amount * sin(u.x * 3.1415927) * sin(u.y * 3.1415927));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0);
    let amount = pinch(clock(t));
    var c: vec4f;
    if (amount <= 0.0001) {
        c = textureSampleLevel(smoothed, smp, uv, 0.0);
    } else {
        // Undo the pull: find the flat point that lands on this pixel.
        let dest = uv * 2.0 - 1.0;
        var p = dest;
        for (var i = 0; i < 12; i++) {
            p = dest / shrink(p, amount);
        }
        c = textureSampleLevel(smoothed, smp, clamp(p * 0.5 + 0.5, vec2f(0.0), vec2f(1.0)), 0.0);
    }
    gpufx_write(id, vec4f(c.rgb, 1.0));
}
