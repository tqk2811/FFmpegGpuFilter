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

// Blur of the two halves along x (gamma 2.2 light, gaussian weights, taps off the frame dropped).
// Each half has its own strength; they never come within reach of each other.
fn fetch(p: vec2f) -> vec4f {
    let c = textureSampleLevel(pages, smp, p, 0.0);
    return vec4f(pow(max(c.rgb, vec3f(0.0)), vec3f(2.2)), c.a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = params.progress * TIMELINE;
    var strength: f32;
    if (uv.x < 0.5) {
        strength = select(0.0, keyed(t, 1.2, 1.5, 0.0, 10.0, vec4f(0.42, 0.0, 0.999, 1.0)), t <= 1.5);
    } else {
        strength = keyed(t, 1.4, 1.7, 0.0, 10.0, vec4f(0.42, 0.0, 0.999, 1.0));
    }
    let s = blur_set(strength, 0.17015, axis_scale(0u));
    if (s.taps < 1e-5) {
        gpufx_write(id, textureSampleLevel(pages, smp, uv, 0.0));
        return;
    }
    var acc = fetch(uv);
    var wsum = 1.0;
    for (var i = 1; i <= 256; i++) {
        if (f32(i) > s.taps) { break; }
        let o = f32(i) * s.stride;
        let w = exp(-0.5 * o * o / (s.sigma * s.sigma));
        let lo = uv.x - o;
        let hi = uv.x + o;
        if (lo >= 0.0) {
            var p = uv;
            p.x = lo;
            acc += fetch(p) * w;
            wsum += w;
        }
        if (hi <= 1.0) {
            var p = uv;
            p.x = hi;
            acc += fetch(p) * w;
            wsum += w;
        }
    }
    acc /= wsum;
    gpufx_write(id, vec4f(pow(max(acc.rgb, vec3f(0.0)), vec3f(1.0 / 2.2)), acc.a));
}
