// Signal Glitch 2, pass 4: lay the smeared, jumping, slightly zoomed picture over a shifted copy of the sharp one.

const FRAMES: f32 = 19.0;
const COMP: f32 = 1280.0;
const SMOOTH = vec4f(0.33333333, 0.0, 0.66666667, 1.0);

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

// Shift of the back copy, comp pixels.
fn back_shift(f: f32) -> f32 {
    if (f < 5.0) { return 0.0; }
    if (f < 6.0) { return key(f, 5.0, 6.0, 0.0, -108.0, SMOOTH); }
    if (f < 7.0) { return key(f, 6.0, 7.0, -108.0, 182.0, SMOOTH); }
    return 182.0;
}

// Shift of the front picture, comp pixels.
fn front_shift(f: f32) -> f32 {
    if (f < 5.0) { return 0.0; }
    if (f < 6.0) { return key(f, 5.0, 6.0, 0.0, 164.0, SMOOTH); }
    if (f < 7.0) { return key(f, 6.0, 7.0, 164.0, -30.0, SMOOTH); }
    if (f < 8.0) { return key(f, 7.0, 8.0, -30.0, -9.0, SMOOTH); }
    if (f < 9.0) { return key(f, 8.0, 9.0, -9.0, 0.0, SMOOTH); }
    return 0.0;
}

// Zoom of the front picture (the source easing is kept as authored, overshoot and all).
fn front_zoom(f: f32) -> f32 {
    if (f < 7.0) { return 1.0; }
    if (f < 12.0) { return key(f, 7.0, 12.0, 1.0, 1.03, vec4f(0.33333333, 0.33333333, 0.33333333, 0.0)); }
    if (f < 17.0) { return key(f, 12.0, 17.0, 1.03, 1.0, vec4f(0.127999777, 0.127999777, 0.33333333, 0.0)); }
    return 1.0;
}

fn inside(q: vec2f) -> f32 {
    return select(0.0, 1.0, all(q >= vec2f(0.0)) && all(q <= vec2f(1.0)));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = clamp(params.progress, 0.0, 1.0);
    let f = p * FRAMES;
    var back = textureSampleLevel(split, smp, uv - vec2f(back_shift(f) / COMP, 0.0), 0.0);
    if (p > 0.5) { back = vec4f(0.0); }
    let q = vec2f(0.5) + (uv - vec2f(0.5)) / front_zoom(f) - vec2f(front_shift(f) / COMP, 0.0);
    var front = textureSampleLevel(smeared, smp, q, 0.0) * inside(q);
    if (p < 0.1) { front = vec4f(0.0); }
    gpufx_write(id, vec4f(mix(back.rgb, front.rgb, front.a), 1.0));
}
