// Contrast Split, pass 4: the half-resolution graded picture brought back to full size with a short vertical blur around
// the cut, and a run of flat flash cards on top (a white left panel, a dark bottom bar, a light slanted right panel).

const SPAN: f32 = 0.99999;
const SMOOTH: vec4f = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

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

fn track(t: f32, t0: f32, t1: f32, v0: f32, v1: f32) -> f32 {
    if (t < t0) { return v0; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, bezier_ease((t - t0) / (t1 - t0), SMOOTH));
}

// Blur strength (0..1000 scale): 0 -> 5 -> 30 -> 0 between 0.333 s and 0.5 s.
fn blur_strength(t: f32) -> f32 {
    if (t < 0.366667) { return track(t, 0.333333, 0.366667, 0.0, 5.0); }
    if (t < 0.433333) { return track(t, 0.366667, 0.433333, 5.0, 30.0); }
    return track(t, 0.433333, 0.5, 30.0, 0.0);
}

fn half_uv(uv: vec2f, dims: vec2f) -> vec2f {
    let h = max(floor(dims * 0.5), vec2f(1.0));
    return clamp(uv, 0.5 / h, 1.0 - 0.5 / h) * h / dims;
}

fn graded_at(uv: vec2f, dims: vec2f) -> vec3f {
    return textureSampleLevel(graded, smp, half_uv(uv, dims), 0.0).rgb;
}

// Gaussian blur along y in linear light: radius = strength / 1000 of the reference size, sigma = radius / 2.5.
fn vertical_blur(uv: vec2f, dims: vec2f, s: f32) -> vec3f {
    if (s <= 0.01) { return graded_at(uv, dims); }
    var n = (0.5 * s + 2.0) * 0.78;
    if (s > 30.0) { n = (0.5 * s + 10.0) * 0.66; }
    if (n < 2.0) { n = floor(n + 0.5); }
    let here = pow(graded_at(uv, dims), vec3f(2.2));
    if (n < 1e-5) { return graded_at(uv, dims); }
    let reference = max(min(dims.x, dims.y), max(dims.x, dims.y) * 0.5);
    let radius = reference / dims.y * s / 1000.0;
    let sigma = radius / 2.5;
    let step = radius / n;
    var sum = here;
    var weight = 1.0;
    let count = min(i32(floor(n)), 1024);
    for (var i = 1; i <= count; i++) {
        let d = step * f32(i);
        let w = exp(-0.5 * d * d / (sigma * sigma));
        if (uv.y - d >= 0.0) { sum += w * pow(graded_at(uv - vec2f(0.0, d), dims), vec3f(2.2)); weight += w; }
        if (uv.y + d <= 1.0) { sum += w * pow(graded_at(uv + vec2f(0.0, d), dims), vec3f(2.2)); weight += w; }
    }
    return pow(sum / weight, vec3f(1.0 / 2.2));
}

// Flash cards on a 680 x 510 sheet that fills the frame, one card per sheet frame at 30 frames per second.
// The sheet time follows the same (1/6, 5/6) keyframe curve as the rest of the effect, which is a straight line.
fn flash_card(uv: vec2f, dims: vec2f, t: f32) -> vec4f {
    let frame = floor(bezier_ease(t, SMOOTH) * 30.0 + 0.5);
    let sheet = vec2f(680.0, 510.0);
    let fit = max(dims.x / sheet.x, dims.y / sheet.y);
    let q = ((uv - 0.5) * dims / fit + 0.5 * sheet) - 0.5;
    if (frame == 8.0 || frame == 9.0) {
        return vec4f(1.0, 1.0, 1.0, 1.0 - smoothstep(372.75 - 21.0, 372.75 + 21.0, q.x));
    }
    if (frame == 10.0 || frame == 11.0) {
        return vec4f(vec3f(28.0 / 255.0), clamp(q.y - 343.25, 0.0, 1.0));
    }
    if (frame == 12.0) {
        let edge = mix(506.5, 445.25, q.y / 509.0);
        return vec4f(vec3f(230.0 / 255.0), smoothstep(edge - 21.0, edge + 21.0, q.x));
    }
    return vec4f(0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let dims = vec2f(textureDimensions(first));
    let picture = vertical_blur(uv, dims, blur_strength(t));
    let card = flash_card(uv, dims, t);
    gpufx_write(id, vec4f(mix(picture, card.rgb, card.a), 1.0));
}
