// Flickering film-burn light leaks wash over the clips while a slanted edge wipes the second clip in from the top.

// Number of film frames the burn footage runs through over the transition.
const FRAMES: f32 = 44.0;

// One film frame of light leak: colour above and below a soft horizontal split.
struct Leak { upper: vec3f, lower: vec3f, split: f32 };

const LEAKS = array<Leak, 44>(
    Leak(vec3f(0.03, 0.00, 0.00), vec3f(0.28, 0.04, 0.06), 0.133),
    Leak(vec3f(0.37, 0.39, 0.44), vec3f(0.02, 0.01, 0.05), 0.742),
    Leak(vec3f(0.25, 0.23, 0.25), vec3f(0.07, 0.01, 0.02), 0.164),
    Leak(vec3f(0.90, 0.38, 0.18), vec3f(0.33, 0.36, 0.36), 0.523),
    Leak(vec3f(0.90, 0.39, 0.18), vec3f(0.33, 0.36, 0.36), 0.523),
    Leak(vec3f(0.67, 0.49, 0.41), vec3f(0.89, 0.29, 0.06), 0.711),
    Leak(vec3f(0.22, 0.05, 0.11), vec3f(0.98, 0.65, 0.22), 0.430),
    Leak(vec3f(0.31, 0.26, 0.37), vec3f(0.15, 0.04, 0.14), 0.383),
    Leak(vec3f(0.07, 0.04, 0.13), vec3f(0.18, 0.20, 0.36), 0.695),
    Leak(vec3f(0.97, 0.74, 0.39), vec3f(0.65, 0.41, 0.12), 0.117),
    Leak(vec3f(0.28, 0.15, 0.03), vec3f(0.43, 0.24, 0.04), 0.570),
    Leak(vec3f(0.50, 0.29, 0.05), vec3f(0.08, 0.04, 0.00), 0.367),
    Leak(vec3f(0.58, 0.27, 0.23), vec3f(0.02, 0.06, 0.12), 0.133),
    Leak(vec3f(0.04, 0.03, 0.08), vec3f(0.37, 0.04, 0.03), 0.383),
    Leak(vec3f(0.06, 0.04, 0.09), vec3f(0.37, 0.04, 0.03), 0.383),
    Leak(vec3f(0.42, 0.52, 0.58), vec3f(0.04, 0.04, 0.16), 0.836),
    Leak(vec3f(0.07, 0.02, 0.01), vec3f(0.04, 0.00, 0.03), 0.195),
    Leak(vec3f(0.07, 0.02, 0.10), vec3f(0.04, 0.00, 0.01), 0.195),
    Leak(vec3f(0.07, 0.02, 0.01), vec3f(0.04, 0.00, 0.10), 0.242),
    Leak(vec3f(0.03, 0.02, 0.01), vec3f(0.00, 0.00, 0.00), 0.242),
    Leak(vec3f(0.02, 0.01, 0.00), vec3f(0.00, 0.00, 0.00), 0.352),
    Leak(vec3f(0.02, 0.01, 0.00), vec3f(0.00, 0.00, 0.00), 0.352),
    Leak(vec3f(0.00, 0.00, 0.00), vec3f(0.01, 0.01, 0.00), 0.414),
    Leak(vec3f(0.00, 0.00, 0.00), vec3f(0.01, 0.01, 0.00), 0.414),
    Leak(vec3f(0.02, 0.01, 0.00), vec3f(0.00, 0.00, 0.00), 0.711),
    Leak(vec3f(0.02, 0.01, 0.00), vec3f(0.00, 0.00, 0.00), 0.711),
    Leak(vec3f(0.01, 0.00, 0.00), vec3f(0.00, 0.00, 0.00), 0.789),
    Leak(vec3f(0.05, 0.06, 0.05), vec3f(0.00, 0.01, 0.01), 0.789),
    Leak(vec3f(0.00, 0.00, 0.00), vec3f(0.10, 0.06, 0.02), 0.852),
    Leak(vec3f(0.52, 0.06, 0.01), vec3f(0.10, 0.06, 0.02), 0.852),
    Leak(vec3f(0.48, 0.04, 0.01), vec3f(0.93, 0.10, 0.02), 0.508),
    Leak(vec3f(0.02, 0.00, 0.00), vec3f(0.93, 0.10, 0.02), 0.727),
    Leak(vec3f(0.15, 0.15, 0.16), vec3f(0.06, 0.21, 0.29), 0.258),
    Leak(vec3f(0.15, 0.15, 0.16), vec3f(0.07, 0.21, 0.29), 0.258),
    Leak(vec3f(0.09, 0.15, 0.21), vec3f(0.24, 0.09, 0.06), 0.570),
    Leak(vec3f(0.49, 0.50, 0.49), vec3f(0.10, 0.40, 0.53), 0.070),
    Leak(vec3f(0.38, 0.01, 0.01), vec3f(0.97, 0.02, 0.02), 0.789),
    Leak(vec3f(0.37, 0.00, 0.01), vec3f(0.78, 0.01, 0.02), 0.523),
    Leak(vec3f(0.37, 0.00, 0.01), vec3f(0.78, 0.01, 0.02), 0.523),
    Leak(vec3f(0.54, 0.05, 0.01), vec3f(0.93, 0.10, 0.02), 0.523),
    Leak(vec3f(0.96, 0.17, 0.02), vec3f(0.72, 0.03, 0.02), 0.258),
    Leak(vec3f(1.00, 1.00, 1.00), vec3f(0.97, 0.26, 0.02), 0.289),
    Leak(vec3f(0.58, 0.04, 0.02), vec3f(0.92, 0.13, 0.02), 0.508),
    Leak(vec3f(0.28, 0.01, 0.01), vec3f(0.82, 0.05, 0.02), 0.523),
);
// Depth of the wipe edge (0 = top, 1 = bottom) at the left and right side of the scene, per film frame.
const EDGE = array<vec2f, 44>(vec2f(0.000, 0.000), vec2f(0.000, 0.000), vec2f(0.000, 0.000), vec2f(0.000, 0.000), vec2f(0.000, 0.000), vec2f(0.000, 0.000), vec2f(0.000, 0.000), vec2f(0.000, 0.000), vec2f(0.000, 0.000), vec2f(0.000, 0.000), vec2f(0.000, 0.000), vec2f(0.000, 0.000), vec2f(0.000, 0.000), vec2f(0.000, 0.000), vec2f(0.070, 0.000), vec2f(0.070, 0.000), vec2f(0.194, 0.081), vec2f(0.194, 0.081), vec2f(0.253, 0.120), vec2f(0.253, 0.120), vec2f(0.329, 0.375), vec2f(0.329, 0.375), vec2f(0.464, 0.474), vec2f(0.464, 0.474), vec2f(0.592, 0.665), vec2f(0.592, 0.665), vec2f(0.754, 0.751), vec2f(0.754, 0.751), vec2f(0.893, 0.904), vec2f(0.893, 0.904), vec2f(1.000, 1.000), vec2f(1.000, 1.000), vec2f(1.000, 1.000), vec2f(1.000, 1.000), vec2f(1.000, 1.000), vec2f(1.000, 1.000), vec2f(1.000, 1.000), vec2f(1.000, 1.000), vec2f(1.000, 1.000), vec2f(1.000, 1.000), vec2f(1.000, 1.000), vec2f(1.000, 1.000), vec2f(1.000, 1.000), vec2f(1.000, 1.000));

fn hash21(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(12.9898, 78.233))) * 43758.5453);
}

// Smooth value noise.
fn value_noise(p: vec2f) -> f32 {
    let i = floor(p);
    let t = fract(p);
    let w = t * t * (3.0 - 2.0 * t);
    let a = hash21(i);
    let b = hash21(i + vec2f(1.0, 0.0));
    let c = hash21(i + vec2f(0.0, 1.0));
    let d = hash21(i + vec2f(1.0, 1.0));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// Additive light, clipped to white.
fn add_light(base: vec3f, layer: vec3f) -> vec3f {
    return min(base + layer, vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let p = clamp(params.progress, 0.0, 1.0);
    // The footage is shown frame by frame, like the film it imitates.
    let k = u32(min(floor(p * 0.999 * FRAMES), FRAMES - 1.0));
    let seed = f32(k) * 7.31;

    // Square scene covering the frame (longer side), centred.
    let size = globals.size;
    let side = max(size.x, size.y);
    let q = 0.5 + (uv - 0.5) * size / side;
    let px = 1.0 / side;

    // Slanted wipe: the second clip fills everything above the edge line.
    let e = EDGE[k];
    let edge_y = mix(e.x, e.y, q.x);
    let reveal = select(1.0 - smoothstep(-px, px, q.y - edge_y), 0.0, e.x <= 0.0 && e.y <= 0.0);
    let outgoing = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let incoming = textureSampleLevel(second, smp, uv, 0.0).rgb;
    var base = mix(outgoing, incoming, select(reveal, 1.0, e.x >= 1.0 && e.y >= 1.0));

    // Light leak: two-tone gradient with blotchy density and fine grain.
    let leak = LEAKS[k];
    let blot = value_noise(q * vec2f(2.5, 4.0) + seed) * 0.6 + value_noise(q * vec2f(6.0, 9.0) - seed) * 0.4;
    let bend = (value_noise(vec2f(q.x * 3.0, seed)) - 0.5) * 0.12;
    let tone = smoothstep(leak.split - 0.09, leak.split + 0.09, q.y + bend);
    var light = mix(leak.upper, leak.lower, tone) * (0.65 + 0.7 * blot);
    light *= 0.92 + 0.16 * hash21(floor(q / px) + seed);

    // Scratched streak riding on the wipe edge, with a fainter twin just below.
    if (e.x > 0.0 && e.x < 1.0) {
        let dist = abs(q.y - edge_y) / px;
        let twin = abs(q.y - edge_y - 0.012 - 0.01 * q.x) / px;
        let shimmer = 0.7 + 0.3 * value_noise(vec2f(q.x * 40.0, seed));
        light += vec3f(0.95, 0.62, 0.32) * shimmer * (exp(-dist * dist / 3.0) + 0.5 * exp(-twin * twin / 1.5));
    }
    // Sparse dust specks.
    let cell = floor(q * 90.0);
    if (hash21(cell + seed * 3.1) > 0.9965) {
        let c = (cell + 0.5) / 90.0;
        light += vec3f(0.9, 0.85, 0.75) * smoothstep(2.5 * px, 0.5 * px, length(q - c));
    }
    base = add_light(base, clamp(light, vec3f(0.0), vec3f(1.0)));
    gpufx_write(id, vec4f(base, 1.0));
}
