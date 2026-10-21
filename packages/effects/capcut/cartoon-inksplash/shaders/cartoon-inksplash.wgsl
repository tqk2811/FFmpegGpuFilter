// Cartoon ink splats burst out from the centre and spread until the second clip, seen through them, fills the frame.

// Scene length in seconds; progress 0..1 covers it.
const SCENE: f32 = 1.966667;
// The splat animation advances at this many frames per second (60 frames in all).
const RATE: f32 = 30.0;
const LAST_FRAME: f32 = 59.0;
const SPLAT_COUNT: i32 = 12;
const TAU: f32 = 6.2831853;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bezier_y(x: f32, k: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 16; n++) {
        let s = (lo + hi) * 0.5;
        let r = 1.0 - s;
        let bx = 3.0 * r * r * s * k.x + 3.0 * r * s * s * k.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = (lo + hi) * 0.5;
    let r = 1.0 - s;
    return 3.0 * r * r * s * k.y + 3.0 * r * s * s * k.w + s * s * s;
}

// Small integer hash (PCG style) mapped to [0, 1).
fn hash01(v: u32) -> f32 {
    var s = v * 747796405u + 2891336453u;
    s = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    s = (s >> 22u) ^ s;
    return f32(s) / 4294967296.0;
}

// Radius of the big central splat against animation frame (piecewise linear).
const CORE_KEYS: array<vec2f, 15> = array<vec2f, 15>(
    vec2f(0.0, 0.0), vec2f(2.0, 0.014), vec2f(8.0, 0.059), vec2f(14.0, 0.108), vec2f(20.0, 0.155),
    vec2f(26.0, 0.2), vec2f(30.0, 0.235), vec2f(34.0, 0.27), vec2f(38.0, 0.33), vec2f(42.0, 0.42),
    vec2f(46.0, 0.52), vec2f(50.0, 0.63), vec2f(54.0, 0.76), vec2f(57.0, 0.9), vec2f(59.0, 1.0));

fn core_radius(f: f32) -> f32 {
    for (var i = 1; i < 15; i++) {
        let b = CORE_KEYS[i];
        if (f <= b.x) {
            let a = CORE_KEYS[i - 1];
            return mix(a.y, b.y, (f - a.x) / (b.x - a.x));
        }
    }
    return CORE_KEYS[14].y;
}

// Satellite splats: start centre (xy) and end centre (zw) in square splat space,
// then (birth frame, frame the travel ends, radius at that frame, growth per frame afterwards).
const SAT_PATH: array<vec4f, 12> = array<vec4f, 12>(
    vec4f(0.72, 0.727, 0.725, 0.728), vec4f(0.263, 0.21, 0.263, 0.218), vec4f(0.365, 0.85, 0.367, 0.845),
    vec4f(0.67, 0.27, 0.671, 0.266), vec4f(0.384, 0.353, 0.353, 0.31), vec4f(0.589, 0.487, 0.99, 0.439),
    vec4f(0.437, 0.66, 0.412, 0.743), vec4f(0.19, 0.575, 0.193, 0.575), vec4f(0.137, 0.548, 0.003, 0.49),
    vec4f(0.696, 0.171, 0.755, 0.013), vec4f(0.465, 0.858, 0.449, 0.988), vec4f(0.678, 0.853, 0.625, 0.991));
const SAT_TIME: array<vec4f, 12> = array<vec4f, 12>(
    vec4f(11.0, 24.0, 0.058, 0.004), vec4f(17.0, 30.0, 0.09, 0.004), vec4f(19.0, 28.0, 0.056, 0.004),
    vec4f(21.0, 26.0, 0.037, 0.003), vec4f(18.0, 26.0, 0.028, 0.001), vec4f(7.0, 50.0, 0.04, 0.0),
    vec4f(13.0, 26.0, 0.024, 0.001), vec4f(26.0, 30.0, 0.032, 0.001), vec4f(31.0, 44.0, 0.017, 0.0),
    vec4f(27.0, 46.0, 0.021, 0.0), vec4f(25.0, 40.0, 0.02, 0.0), vec4f(25.0, 44.0, 0.022, 0.0));

// Signed coverage (in splat-space units, positive inside) of one lobed splat.
fn splat(d: vec2f, radius: f32, seed: u32) -> f32 {
    let len = length(d);
    if (radius <= 0.0) { return -len; }
    let ang = atan2(d.y, d.x);
    let lobes = 6.0 + floor(hash01(seed) * 4.0);
    let w = 0.5 + 0.5 * cos(lobes * ang + hash01(seed + 1u) * TAU);
    let wobble = sin(3.0 * ang + hash01(seed + 2u) * TAU) * 0.06;
    let edge = radius * (0.84 + 0.34 * pow(w, 3.0) + wobble);
    return edge - len;
}

// Ink matte (0..1) at square splat-space point `q` for animation frame `f`.
fn ink(q: vec2f, f: f32, px: f32) -> f32 {
    var best = splat(q - vec2f(0.495, 0.505), core_radius(f), 7u);
    for (var i = 0; i < SPLAT_COUNT; i++) {
        let tm = SAT_TIME[i];
        if (f <= tm.x) { continue; }
        let k = clamp((f - tm.x) / (tm.y - tm.x), 0.0, 1.0);
        let path = SAT_PATH[i];
        let centre = mix(path.xy, path.zw, k);
        let grow = 1.0 - (1.0 - k) * (1.0 - k);
        let r = tm.z * grow + tm.w * max(f - tm.y, 0.0);
        best = max(best, splat(q - centre, r, 101u + u32(i) * 13u));
    }
    return clamp(best / px + 0.5, 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // Exact clips at the ends of the transition.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(a, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(b, 1.0)); return; }

    let t = params.progress * SCENE;
    let f = clamp(t * RATE, 0.0, LAST_FRAME);
    // The square splat artwork is scaled to cover the frame (cropped on the long side).
    let dims = globals.size;
    let side = max(dims.x, dims.y);
    let q = (uv - 0.5) * dims / side + 0.5;
    var m = ink(q, f, 1.0 / side);
    // The second clip fades in behind the matte over the first 0.1 s.
    m *= bezier_y(clamp(t / 0.1, 0.0, 1.0), vec4f(0.33, 0.0, 0.67, 1.0));
    // A solid fill closes any gap during the last frame.
    m = max(m, clamp((t - 1.933333) / 0.033333, 0.0, 1.0));
    // The first clip fades out underneath near the end.
    let fade_a = 1.0 - clamp((t - 1.9) / 0.066667, 0.0, 1.0);
    gpufx_write(id, vec4f(mix(a * fade_a, b, m), 1.0));
}
