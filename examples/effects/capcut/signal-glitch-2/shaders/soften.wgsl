// Signal Glitch 2, pass 5: a quick horizontal Gaussian blur, averaged in linear light.

const FRAMES: f32 = 19.0;
const GAMMA: f32 = 2.2;
const TAPS_PER_SIGMA: f32 = 2.5;

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

// Blur reach in taps (one tap = 1/1000 of the frame's reference size).
fn reach(f: f32) -> f32 {
    if (f < 5.0) { return 0.0; }
    if (f < 6.0) { return key(f, 5.0, 6.0, 0.0, 41.0, vec4f(0.33333333, 0.0, 0.66666667, 1.0)); }
    if (f < 17.0) { return key(f, 6.0, 17.0, 41.0, 0.0, vec4f(0.142157033, -1.11e-7, 0.66666667, 1.0)); }
    return 0.0;
}

fn linear_at(x: f32, y: f32) -> vec3f {
    return pow(textureSampleLevel(layered, smp, vec2f(x, y), 0.0).rgb, vec3f(GAMMA));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let f = clamp(params.progress, 0.0, 1.0) * FRAMES;
    let n = reach(f);
    if (n < 1e-5) {
        gpufx_write(id, textureSampleLevel(layered, smp, uv, 0.0));
        return;
    }
    let size = globals.size;
    let base = max(min(size.x, size.y), max(size.x, size.y) * 0.5);
    let dx = base / size.x / 1000.0;
    let sigma = n * dx / TAPS_PER_SIGMA;
    var sum = linear_at(uv.x, uv.y);
    var total = 1.0;
    for (var i = 1; i <= 41; i++) {
        let k = f32(i);
        if (k > n) { break; }
        let x = k * dx;
        let w = exp(-0.5 * x * x / (sigma * sigma));
        // Taps that fall off the frame are dropped, not clamped.
        if (uv.x - x >= 0.0) { sum += w * linear_at(uv.x - x, uv.y); total += w; }
        if (uv.x + x <= 1.0) { sum += w * linear_at(uv.x + x, uv.y); total += w; }
    }
    gpufx_write(id, vec4f(pow(sum / total, vec3f(1.0 / GAMMA)), 1.0));
}
