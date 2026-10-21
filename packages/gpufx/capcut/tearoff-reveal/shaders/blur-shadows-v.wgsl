// Tearoff Reveal: a perforated strip is torn down the middle of the first clip, then the two halves peel away to the sides, uncovering the second clip.

// The whole animation runs on a 1.73333 s timeline driven by `progress`.
const TIMELINE: f32 = 1.73332;

// Cubic Bezier easing through (0,0), (c.x,c.y), (c.z,c.w), (1,1): x is solved by bisection.
fn ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
        let m = 0.5 * (lo + hi);
        let n = 1.0 - m;
        let bx = 3.0 * n * n * m * c.x + 3.0 * n * m * m * c.z + m * m * m;
        if (bx > x) { hi = m; } else { lo = m; }
    }
    let s = 0.5 * (lo + hi);
    let n = 1.0 - s;
    return 3.0 * n * n * s * c.y + 3.0 * n * s * s * c.w + s * s * s;
}

// Value moving from a to b between times t0 and t1 along the curve, held outside that span.
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, ease(x, c));
}

// Separable gaussian blur as the timeline sets it: an intensity and a quality give the
// radius, the tap count and the tap spacing (in 0..1 of the short side).
struct BlurSet { taps: f32, stride: f32, sigma: f32 };

fn blur_set(intensity: f32, quality: f32, axis_scale: f32) -> BlurSet {
    var base: f32;
    if (intensity <= 30.0) {
        base = (0.5 * intensity + 2.0) * 0.78;
    } else if (intensity <= 100.0) {
        base = (0.5 * intensity + 10.0) * 0.66;
    } else if (intensity <= 200.0) {
        base = (0.25 * intensity + 50.0) * 0.7;
    } else {
        base = (0.125 * intensity + 80.0) * 0.8;
    }
    if (base < 2.0) { base = floor(base + 0.5); }
    let qk = quality * 2.0 - 1.0;
    let qf = select(qk * 2.0 + 1.0, pow(10.0, qk), qk < 0.0);
    let radius = axis_scale * intensity / 1000.0;
    var s: BlurSet;
    s.taps = select(base * qf, 0.0, intensity <= 0.01);
    s.stride = radius / max(s.taps, 1e-5);
    s.sigma = max(radius / 2.5, 1e-6);
    return s;
}

// Scale from the short-side normalisation to this axis (x: 0, y: 1).
fn axis_scale(axis: u32) -> f32 {
    let w = globals.size.x;
    let h = globals.size.y;
    let base = max(min(w, h), max(w, h) * 0.5);
    return select(base / w, base / h, axis == 1u);
}

// Blur of the three shadow masks along y, each channel with its own animated strength.
fn blur_channel(uv: vec2f, ch: u32, s: BlurSet) -> f32 {
    let c0 = textureSampleLevel(shadows_h, smp, uv, 0.0)[ch];
    if (s.taps < 1e-5) { return c0; }
    var acc = c0;
    var wsum = 1.0;
    for (var i = 1; i <= 256; i++) {
        if (f32(i) > s.taps) { break; }
        let o = f32(i) * s.stride;
        let w = exp(-0.5 * o * o / (s.sigma * s.sigma));
        let lo = uv.y - o;
        let hi = uv.y + o;
        if (lo >= 0.0) {
            var p = uv;
            p.y = lo;
            acc += textureSampleLevel(shadows_h, smp, p, 0.0)[ch] * w;
            wsum += w;
        }
        if (hi <= 1.0) {
            var p = uv;
            p.y = hi;
            acc += textureSampleLevel(shadows_h, smp, p, 0.0)[ch] * w;
            wsum += w;
        }
    }
    return acc / wsum;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = params.progress * TIMELINE;
    let k = axis_scale(1u);
    var right_strength: f32;
    if (t < 1.433333) {
        right_strength = keyed(t, 1.266667, 1.433333, 12.0, 37.0, vec4f(0.311773, 0.086006, 0.704632, 0.450508));
    } else {
        right_strength = keyed(t, 1.433333, 1.7, 37.0, 180.0, vec4f(0.474838, 0.247097, 0.825579, 0.57024));
    }
    let right_quality = keyed(t, 1.266667, 1.7, 0.4, 0.0, vec4f(0.89, 0.092857, 0.999, 1.0));
    var left_strength: f32;
    if (t < 1.233333) {
        left_strength = keyed(t, 1.066667, 1.233333, 20.0, 35.0, vec4f(0.225594, 0.0, 0.716903, 0.255409));
    } else {
        left_strength = keyed(t, 1.233333, 1.5, 35.0, 180.0, vec4f(0.585941, 0.255082, 0.887093, 0.535595));
    }
    let left_quality = keyed(t, 1.066667, 1.5, 0.4, 0.0, vec4f(0.89, 0.1, 0.999, 1.0));
    let r = blur_channel(uv, 0u, blur_set(right_strength, right_quality, k));
    let g = blur_channel(uv, 1u, blur_set(left_strength, left_quality, k));
    let b = blur_channel(uv, 2u, blur_set(30.0, 0.20418, k));
    gpufx_write(id, vec4f(r, g, b, 1.0));
}
