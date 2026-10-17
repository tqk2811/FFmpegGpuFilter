// Frame Swipe, pass 1: the outgoing clip slowly pushes in and slides off to the left, then the incoming clip settles back from a zoom.

// Composition clock: progress 0..1 covers two seconds of keyframes.
const SPAN: f32 = 1.99999;
const SMOOTH: vec4f = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

// Eased 0..1 for a cubic-bezier curve from (0, 0) to (1, 1) with handles (h.x, h.y) and (h.z, h.w).
fn bezier_ease(u: f32, h: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let m = 0.5 * (lo + hi);
        let r = 1.0 - m;
        let x = 3.0 * r * r * m * h.x + 3.0 * r * m * m * h.z + m * m * m;
        if (x > u) { hi = m; } else { lo = m; }
    }
    let s = 0.5 * (lo + hi);
    let r = 1.0 - s;
    return 3.0 * r * r * s * h.y + 3.0 * r * s * s * h.w + s * s * s;
}

// A keyframed value: v0 until t0, v1 from t1 on, eased in between.
fn track(t: f32, t0: f32, t1: f32, v0: f32, v1: f32, h: vec4f) -> f32 {
    if (t < t0) { return v0; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, bezier_ease((t - t0) / (t1 - t0), h));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    var colour = vec3f(0.0);
    if (t < 1.0) {
        // Outgoing clip: zoom 102 -> 130 %, and from 0.8 s a slide of 286 / 784 of the width to the left.
        let zoom = track(t, 0.0, 0.959993, 102.0, 130.0, SMOOTH) * 0.01;
        let shift = (track(t, 0.8, 1.080013, 392.0, 106.0, SMOOTH) - 392.0) / 784.0;
        let src = (uv - vec2f(0.5 + shift, 0.5)) / zoom + 0.5;
        // Outside the moved picture there is nothing: black.
        if (all(src >= vec2f(0.0)) && all(src <= vec2f(1.0))) {
            colour = textureSampleLevel(first, smp, src, 0.0).rgb;
        }
    } else {
        // Incoming clip: zoom 130 -> 100 %.
        let zoom = track(t, 1.0, 1.959993, 130.0, 100.0, SMOOTH) * 0.01;
        colour = textureSampleLevel(second, smp, (uv - 0.5) / zoom + 0.5, 0.0).rgb;
    }
    gpufx_write(id, vec4f(colour, 1.0));
}
