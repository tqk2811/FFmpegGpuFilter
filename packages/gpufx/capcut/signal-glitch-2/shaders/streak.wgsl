// Signal Glitch 2, pass 9: a strong horizontal streak blur through the middle of the glitch.

const FRAMES: f32 = 19.0;
const SIGMA: f32 = 4.0;

fn bezier_axis(a: f32, b: f32, t: f32) -> f32 {
    let s = 1.0 - t;
    return 3.0 * a * s * s * t + 3.0 * b * s * t * t + t * t * t;
}

fn ease(c: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(c.x, c.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(c.y, c.w, 0.5 * (lo + hi));
}

fn key(f: f32, f0: f32, f1: f32, v0: f32, v1: f32, c: vec4f) -> f32 {
    return mix(v0, v1, ease(c, clamp((f - f0) / (f1 - f0), 0.0, 1.0)));
}

// Streak length in taps; it only switches on after 30 % of the transition.
fn taps(p: f32) -> f32 {
    if (p <= 0.3) { return 0.0; }
    let f = p * FRAMES;
    if (f < 6.0) { return 42.0; }
    if (f < 10.0) { return key(f, 6.0, 10.0, 42.0, 78.551569, vec4f(0.296903274, -2e-9, 0.570930011, 1.226766679)); }
    if (f < 14.0) { return key(f, 10.0, 14.0, 78.551569, 42.777942, vec4f(0.298580691, 0.161233719, 0.628444409, 1.009894361)); }
    if (f < 17.0) { return key(f, 14.0, 17.0, 42.777942, 0.0, vec4f(0.303603707, 0.00030092, 0.635044125, 0.999999998)); }
    return 0.0;
}

fn bell(x: f32) -> f32 {
    return 0.39894 * exp(-0.5 * x * x / (SIGMA * SIGMA)) / SIGMA;
}

fn fold1(x: f32) -> f32 {
    let m = (x - 1.0) - 2.0 * floor((x - 1.0) * 0.5);
    return abs(m - 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let n = floor(taps(clamp(params.progress, 0.0, 1.0)));
    let centre = textureSampleLevel(bloomed, smp, uv, 0.0);
    if (n < 1.0) {
        gpufx_write(id, centre);
        return;
    }
    // One tap is 1/720 of the shorter side.
    let step_x = min(globals.size.x, globals.size.y) / (720.0 * globals.size.x);
    var w = bell(0.0);
    var sum = centre * w;
    var total = w;
    for (var i = 1; i <= 80; i++) {
        let k = f32(i);
        if (k > n) { break; }
        w = bell(k / n * 15.0);
        let a = textureSampleLevel(bloomed, smp, vec2f(fold1(uv.x + k * step_x), uv.y), 0.0);
        let b = textureSampleLevel(bloomed, smp, vec2f(fold1(uv.x - k * step_x), uv.y), 0.0);
        sum += (a + b) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, clamp(sum / total, vec4f(0.0), vec4f(1.0)));
}
