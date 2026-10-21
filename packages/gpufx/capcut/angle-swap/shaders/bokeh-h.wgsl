// Angle Swap: soften the picture horizontally before the bokeh pass; the reach grows with the
// bokeh strength (none at the ends).

// One cubic Bezier segment of a keyframed track: (x1, y1) and (x4, y4) are the
// keys, (x2, y2) and (x3, y3) the handles, all in (progress, value) space.
// The progress is solved by bisection, then the value is read off the curve.
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

// Bokeh strength: 0 -> 31.8 at the cut -> 0 (out of a full scale of 79).
fn bokeh_amount(t: f32) -> f32 {
    if (t <= 0.0 || t >= 1.0) { return 0.0; }
    if (t < 0.5) { return segment(t, 0.0, 0.5, 0.49995, 0.5, 0.0, 0.0, 31.8, 31.8); }
    return segment(t, 0.5, 0.50005, 0.5, 1.0, 31.8, 31.8, 0.0, 0.0);
}

fn bell(x: f32) -> f32 {
    return 0.39894 * exp(-0.5 * x * x / 16.0) / 4.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    let strength = pow(bokeh_amount(t) / 79.0, 0.35);
    let taps = 22.0 * strength * 0.7;
    let unit = vec2f(1.0, 0.0) / (globals.size / min(globals.size.x, globals.size.y) * 720.0);
    var sum = textureSampleLevel(bokeh_v, smp, uv, 0.0) * bell(0.0);
    var total = bell(0.0);
    for (var i = 1; i <= 32; i++) {
        let k = f32(i);
        if (k > taps) { break; }
        let w = bell(k / taps * 15.0);
        sum += (textureSampleLevel(bokeh_v, smp, uv + k * unit, 0.0) + textureSampleLevel(bokeh_v, smp, uv - k * unit, 0.0)) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(clamp(sum / total, vec4f(0.0), vec4f(1.0)).rgb, 1.0));
}
