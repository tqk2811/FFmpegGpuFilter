// Hard cut hidden under a burst of horizontal glitch: slide, streak displacement, red tritone and RGB split.

// Animation time covered by the whole transition, in seconds.
const SPAN: f32 = 1.0;
// The incoming clip replaces the outgoing one at this time.
const CUT_AT: f32 = 0.23333;
// Frame rate of the streak map animation.
const MAP_FPS: f32 = 30.0;

// Piecewise-linear key track: values `v` at times `k`, held before the first and after the last key.
fn track3(t: f32, k: vec3f, v: vec3f) -> f32 {
    if (t <= k.x) { return v.x; }
    if (t <= k.y) { return mix(v.x, v.y, (t - k.x) / (k.y - k.x)); }
    if (t <= k.z) { return mix(v.y, v.z, (t - k.y) / (k.z - k.y)); }
    return v.z;
}

fn ramp(t: f32, t0: f32, t1: f32, a: f32, b: f32) -> f32 {
    return mix(a, b, clamp((t - t0) / (t1 - t0), 0.0, 1.0));
}

// Whole-frame slide of the glitch (fraction of the width).
fn slide_amount(t: f32) -> f32 {
    if (t <= 0.3) { return track3(t, vec3f(0.233333, 0.266667, 0.3), vec3f(0.0, 0.52, 1.0)); }
    return ramp(t, 0.3, 0.333333, 1.0, 0.0);
}

// Strength of the streak displacement.
fn streak_amount(t: f32) -> f32 {
    if (t <= 0.233333) { return track3(t, vec3f(0.133333, 0.2, 0.233333), vec3f(1.0, -0.47, -0.49)); }
    if (t <= 0.3) { return track3(t, vec3f(0.233333, 0.266667, 0.3), vec3f(-0.49, 0.0, 0.03)); }
    return track3(t, vec3f(0.3, 0.333333, 0.433333), vec3f(0.03, 0.27, 0.0));
}

fn hash_u(x: u32) -> u32 {
    var h = x * 747796405u + 2891336453u;
    h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
    return (h >> 22u) ^ h;
}

fn hash01(a: u32, b: u32) -> f32 {
    return f32(hash_u(a ^ hash_u(b)) & 0xffffu) / 65535.0;
}

// Procedural streak map: thin horizontal bands broken into a few long segments.
// The first frames are a dim grey (small shifts), later frames are bright with dark streaks.
fn streak_map(uv: vec2f, t: f32) -> f32 {
    let frame = min(floor(t * MAP_FPS), 29.0);
    let late = frame >= 11.0;
    let seed = select(17u, 91u, late);
    // Band height varies between 1/240 and 1/48 of the frame.
    let coarse = u32(floor(uv.y * 48.0));
    let split = 1.0 + floor(hash01(coarse, seed) * 5.0);
    let row = coarse * 8u + u32(floor(fract(uv.y * 48.0) * split));
    let cut = mix(0.15, 0.85, hash01(row, seed + 3u));
    let seg = select(0u, 1u, uv.x > cut) + select(0u, 2u, uv.x > 0.92);
    let h = hash01(row * 4u + seg, seed + 7u);
    if (!late) { return 0.5 + 0.22 * (h - 0.5); }
    return 1.0 - 0.75 * h * h;
}

// Fold any coordinate back into [0, 1] by mirroring at every edge.
fn mirror1(x: f32) -> f32 {
    var m = x - 2.0 * floor(x * 0.5);
    if (m > 1.0) { m = 2.0 - m; }
    return clamp(m, 0.0, 1.0);
}

fn base_clip(uv: vec2f, t: f32) -> vec3f {
    if (t < CUT_AT) { return textureSampleLevel(first, smp, uv, 0.0).rgb; }
    return textureSampleLevel(second, smp, uv, 0.0).rgb;
}

// Slide, then streak displacement (both mirror-wrapped), then the tritone grade.
fn glitched(uv: vec2f, t: f32) -> vec3f {
    let shift = (streak_map(uv, t) - 0.5) * 2.0 * streak_amount(t);
    let x1 = mirror1(uv.x + shift);
    let x0 = mirror1(x1 + slide_amount(t));
    let c = base_clip(vec2f(x0, uv.y), t);
    let keep = track3(t, vec3f(0.133333, 0.166667, 0.433333), vec3f(1.0, 0.2, 1.0));
    let luma = dot(c, vec3f(0.299, 0.587, 0.114));
    let mid = vec3f(0.82353);
    let low = mix(vec3f(0.0), mid, clamp(luma / 0.5, 0.0, 1.0));
    let high = mix(mid, vec3f(1.0, 0.0, 0.0), clamp((luma - 0.5) / 0.5, 0.0, 1.0));
    let toned = select(low, high, luma >= 0.5);
    return mix(toned, c, keep);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let plain = base_clip(uv, t);
    // The glitch layer fades in over one frame from 0.1 s and is gone after 0.4333 s.
    let amount = ramp(t, 0.1, 0.133333, 0.0, 1.0);
    if (amount <= 0.0 || t >= 0.433333) { gpufx_write(id, vec4f(plain, 1.0)); return; }
    // RGB split: red and blue taken from opposite offsets, strongest mid-frame.
    let spread = ramp(t, 0.133333, 0.433333, 0.8, 0.0);
    let off = vec2f(spread * (1.0 - uv.x) * uv.x, 0.0);
    let g = glitched(uv, t);
    let r = glitched(clamp(uv + off, vec2f(0.0), vec2f(1.0)), t).r;
    let b = glitched(clamp(uv - off, vec2f(0.0), vec2f(1.0)), t).b;
    let fx = vec3f(r, g.g, b);
    gpufx_write(id, vec4f(mix(plain, fx, amount), 1.0));
}
