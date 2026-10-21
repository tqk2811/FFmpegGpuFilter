// Signal Glitch 2, pass 1: pick the clip (a short crossfade at the midpoint) and pull its red, green and blue apart.

const FRAMES: f32 = 19.0;            // the animation is keyed on a 19-frame timeline
const SMOOTH = vec4f(0.33333333, 0.0, 0.66666667, 1.0);
const COMP: f32 = 1280.0;            // keyframe positions are in a 1280 px square

fn bezier_axis(a: f32, b: f32, t: f32) -> f32 {
    let s = 1.0 - t;
    return 3.0 * a * s * s * t + 3.0 * b * s * t * t + t * t * t;
}

// Keyframe easing: cubic Bezier (0,0)-(c.xy)-(c.zw)-(1,1), solved for x by bisection.
fn ease(c: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(c.x, c.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(c.y, c.w, 0.5 * (lo + hi));
}

fn key(f: f32, f0: f32, f1: f32, v0: f32, v1: f32) -> f32 {
    return mix(v0, v1, ease(SMOOTH, clamp((f - f0) / (f1 - f0), 0.0, 1.0)));
}

// Channel drift: rest -> a (frames 1..3) -> b (3..10) -> rest (10..18).
fn drift(f: f32, a: f32, b: f32) -> f32 {
    if (f < 1.0) { return 0.0; }
    if (f < 3.0) { return key(f, 1.0, 3.0, 0.0, a); }
    if (f < 10.0) { return key(f, 3.0, 10.0, a, b); }
    if (f < 18.0) { return key(f, 10.0, 18.0, b, 0.0); }
    return 0.0;
}

fn fold1(x: f32) -> f32 {
    let m = x - 2.0 * floor(x * 0.5);
    return select(m, 2.0 - m, m >= 1.0);
}

fn fold(q: vec2f) -> vec2f { return vec2f(fold1(q.x), fold1(q.y)); }

fn clip_at(q: vec2f, w: f32) -> vec3f {
    let a = textureSampleLevel(first, smp, q, 0.0).rgb;
    let b = textureSampleLevel(second, smp, q, 0.0).rgb;
    return mix(a, b, w);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let f = clamp(params.progress, 0.0, 1.0) * FRAMES;
    // The glitch peaks around frame 9.5; the clips trade places there over two frames.
    let w = smoothstep(8.5, 10.5, f);
    let off_r = vec2f(drift(f, 7.0, 14.0), 0.0) / COMP;
    let off_g = vec2f(0.0, -drift(f, 8.0, 17.0)) / COMP;
    let off_b = vec2f(drift(f, -14.0, -27.0), -drift(f, 8.0, 18.0)) / COMP;
    let r = clip_at(fold(uv - off_r), w).r;
    let g = clip_at(fold(uv - off_g), w).g;
    let b = clip_at(fold(uv - off_b), w).b;
    gpufx_write(id, vec4f(r, g, b, 1.0));
}
