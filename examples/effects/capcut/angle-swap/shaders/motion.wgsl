// Angle Swap: brighten toward the cut, then zoom and tilt the picture (the first clip
// pushes in to 135 % turning 10 degrees, the second settles from 65 % and -10 degrees)
// with 16-sample motion blur across one 30 fps frame and mirror-filled edges.

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

// Exposure in stops: 0 -> 0.5 at the cut -> 0.
fn exposure_curve(t: f32) -> f32 {
    if (t <= 0.0 || t >= 1.0) { return 0.0; }
    if (t < 0.5) { return segment(t, 0.0, 0.4628895, 0.49995, 0.5, 0.0, 0.0, 0.5, 0.5); }
    return segment(t, 0.5, 0.50005, 0.6412568, 1.0, 0.5, 0.5, 0.0, 0.0);
}

// First half: zoom 100 -> 135 % and tilt 0 -> 10 degrees, both easing in.
fn zoom_out_half(x: f32) -> f32 {
    if (x <= 0.0) { return 100.0; }
    if (x >= 0.5) { return 135.0; }
    return segment(x, 0.0, 0.5, 0.49995, 0.5, 100.0, 100.0, 135.0, 135.0);
}

fn tilt_out_half(x: f32) -> f32 {
    if (x <= 0.0) { return 0.0; }
    if (x >= 0.5) { return 10.0; }
    return segment(x, 0.0, 0.4666667, 0.4266667, 0.5, 0.0, 0.0, 10.0, 10.0);
}

// Second half: zoom 65 -> 100 % and tilt -10 -> 0 degrees, both easing out.
fn zoom_in_half(x: f32) -> f32 {
    if (x <= 0.5) { return 65.0; }
    if (x >= 1.0) { return 100.0; }
    return segment(x, 0.5, 0.525, 0.5, 1.0, 65.0, 65.0, 100.0, 100.0);
}

fn tilt_in_half(x: f32) -> f32 {
    if (x <= 0.5) { return -10.0; }
    if (x >= 1.0) { return 0.0; }
    return segment(x, 0.5, 0.5007964, 0.5, 1.0, -10.0, -10.0, 0.0, 0.0);
}

fn mirrored(uv: vec2f) -> vec3f {
    let m = abs((uv + 1.0) - 2.0 * floor((uv + 1.0) / 2.0) - 1.0);
    return textureSampleLevel(bokeh, smp, m, 0.0).rgb;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    let local = select(t, 0.0, t >= 1.0);
    let gain = pow(2.0, exposure_curve(t) / 2.2);
    let size = globals.size;
    let centre = size * 0.5;
    let p = uv * size - centre;
    var acc = vec3f(0.0);
    for (var i = 0; i < 16; i++) {
        let x = mix(local - 0.5 / 30.0, local + 0.5 / 30.0, f32(i) / 16.0);
        var zoom: f32;
        var tilt: f32;
        if (local <= 0.5) {
            zoom = zoom_out_half(x) * 0.01;
            tilt = tilt_out_half(x);
        } else {
            zoom = zoom_in_half(x) * 0.01;
            tilt = tilt_in_half(x);
        }
        let a = radians(tilt);
        let cs = cos(a);
        let sn = sin(a);
        let q = vec2f(cs * p.x + sn * p.y, -sn * p.x + cs * p.y) / zoom;
        acc += clamp(mirrored((q + centre) / size) * gain, vec3f(0.0), vec3f(1.0));
    }
    gpufx_write(id, vec4f(acc / 16.0, 1.0));
}
