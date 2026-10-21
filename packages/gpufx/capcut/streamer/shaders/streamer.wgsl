// A wobbly hole with a glowing golden rim grows out of the top-left of the zooming first clip and swallows it, revealing the shrinking second clip.

// Animation frames of the reveal; progress runs over FRAMES of them.
const FRAMES: f32 = 37.0;

// Rim radius of the hole (square scene units) at each animation frame.
const RADIUS = array<f32, 30>(
    0.0, 0.008, 0.012, 0.0165, 0.0238, 0.0338, 0.0506, 0.0789, 0.1337, 0.1743,
    0.2241, 0.2931, 0.3437, 0.3704, 0.3931, 0.4215, 0.4523, 0.4797, 0.5036, 0.5279,
    0.5657, 0.6420, 0.6759, 0.7167, 0.7287, 0.7456, 0.7608, 0.7733, 0.8196, 1.2);
// Hole centre drifting from the top-left towards the middle of the scene.
const CENTRE = array<vec2f, 30>(
    vec2f(0.23, 0.31), vec2f(0.23, 0.31), vec2f(0.23, 0.31), vec2f(0.23, 0.31), vec2f(0.23, 0.31),
    vec2f(0.23, 0.31), vec2f(0.29, 0.33), vec2f(0.35, 0.37), vec2f(0.41, 0.42), vec2f(0.41, 0.41),
    vec2f(0.39, 0.40), vec2f(0.37, 0.43), vec2f(0.37, 0.46), vec2f(0.39, 0.45), vec2f(0.41, 0.45),
    vec2f(0.43, 0.45), vec2f(0.46, 0.44), vec2f(0.48, 0.45), vec2f(0.48, 0.46), vec2f(0.49, 0.46),
    vec2f(0.49, 0.46), vec2f(0.51, 0.49), vec2f(0.51, 0.49), vec2f(0.51, 0.48), vec2f(0.50, 0.49),
    vec2f(0.50, 0.49), vec2f(0.50, 0.49), vec2f(0.50, 0.49), vec2f(0.50, 0.50), vec2f(0.50, 0.50));
// Strength of the soft outer halo at each animation frame.
const HALO = array<f32, 30>(
    0.0, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.0,
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.9, 0.8, 0.7, 0.6,
    0.45, 0.25, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.15, 0.0);

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, x1: f32, y1: f32, x2: f32, y2: f32) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * x1 + 3.0 * inv * s * s * x2 + s * s * s;
        let dx = 3.0 * inv * inv * x1 + 6.0 * inv * s * (x2 - x1) + 3.0 * s * s * (1.0 - x2);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * y1 + 3.0 * inv * s * s * y2 + s * s * s;
}

// Clip zoomed about the centre by `scale`.
fn zoomed(tex: texture_2d<f32>, uv: vec2f, scale: f32) -> vec3f {
    return textureSampleLevel(tex, smp, 0.5 + (uv - 0.5) / scale, 0.0).rgb;
}

// Table value at a fractional frame, linearly interpolated between neighbours.
fn radius_at(f: f32) -> f32 {
    let i = u32(clamp(floor(f), 0.0, 28.0));
    return mix(RADIUS[i], RADIUS[i + 1u], clamp(f - f32(i), 0.0, 1.0));
}
fn centre_at(f: f32) -> vec2f {
    let i = u32(clamp(floor(f), 0.0, 28.0));
    return mix(CENTRE[i], CENTRE[i + 1u], clamp(f - f32(i), 0.0, 1.0));
}
fn halo_at(f: f32) -> f32 {
    let i = u32(clamp(floor(f), 0.0, 28.0));
    return mix(HALO[i], HALO[i + 1u], clamp(f - f32(i), 0.0, 1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let p = clamp(params.progress, 0.0, 1.0);
    let f = p * FRAMES;

    let scale_a = mix(1.0, 1.2, bezier_ease(p, 0.16667, 0.16667, 0.83333, 0.83333));
    let scale_b = mix(2.05481, 1.0, bezier_ease(p, 0.33333, 0.0, 0.66667, 1.0));
    let outgoing = zoomed(first, uv, scale_a);
    let incoming = zoomed(second, uv, scale_b);

    // Scene coordinates: a square as large as the longer side, centred on the frame.
    let size = globals.size;
    let side = max(size.x, size.y);
    let q = 0.5 + (uv - 0.5) * size / side;

    // Wobbly hole: polar radius scaled by a few angular waves around a drifting centre.
    let d = q - centre_at(f);
    let r = length(d);
    let ang = atan2(d.y, d.x);
    let wobble = 1.0 + 0.22 * sin(3.0 * ang + 1.3) + 0.12 * sin(5.0 * ang + 0.4) + 0.07 * sin(8.0 * ang + 2.1);
    let rim = radius_at(f) / wobble;
    // Signed distance to the rim along the ray: negative inside the hole.
    let s = r - rim;
    let px = 1.0 / side;
    let inside = 1.0 - smoothstep(-px, px, s);
    var base = mix(outgoing, incoming, select(inside, 0.0, radius_at(f) <= 0.0));

    // Golden light: sharp rim, a thin inner fringe and a streaky outer halo.
    var glow = 0.0;
    if (radius_at(f) > 0.0) {
        let streaks = 0.65 + 0.35 * sin(23.0 * ang + 1.7) * sin(37.0 * ang + 0.6);
        if (s < 0.0) {
            glow = 0.62 * exp(s / 0.004);
        } else {
            glow = 0.34 * exp(-s / 0.012) + 0.28 * halo_at(f) * streaks * exp(-s / 0.09);
        }
    }
    let tint = mix(vec3f(1.0, 0.8, 0.48), vec3f(1.0, 0.95, 0.62), clamp(glow * 1.6, 0.0, 1.0));
    base = min(base + tint * glow, vec3f(1.0));
    gpufx_write(id, vec4f(base, 1.0));
}
