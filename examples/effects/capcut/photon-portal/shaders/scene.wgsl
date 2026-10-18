// Photon Portal, pass 1: a violet energy ring bursts open over the shaking first clip, the second clip shows through its hole, then everything zooms in.
//
// `progress` 0..1 spans SCENE seconds. The ring and the hole are radial profiles keyed
// every second animation frame (30 fps), broken up with streaky procedural noise.

const SCENE: f32 = 1.033333;
const RATE: f32 = 30.0;
const RADIAL_STEP: f32 = 0.04;
const RING_BINS: i32 = 16;
const HOLE_BINS: i32 = 9;
const KEY_ROWS: i32 = 16;
const BASE_SCALE: f32 = 1.02602249;
const ZOOM_END: f32 = 2.92;
// Shake reach in pixels of a 1080-pixel short side, per unit of amplitude ratio.
const SHAKE_REACH: f32 = 192.0;
const SHAKE_PEAK: f32 = 2.8;
const SHAKE_RATE: f32 = 8.0;
const PI: f32 = 3.14159265;

// Premultiplied ring colour against radius (fraction of the long side), one row per key.
const PORTAL_RGB: array<vec3f, 256> = array<vec3f, 256>(
    vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.812, 0.763, 0.941), vec3f(0.995, 0.996, 0.998), vec3f(0.425, 0.422, 0.485), vec3f(0.001, 0.001, 0.001), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.449, 0.413, 0.588), vec3f(0.855, 0.817, 0.934), vec3f(0.981, 0.977, 0.995), vec3f(0.981, 0.985, 0.996), vec3f(0.615, 0.616, 0.835), vec3f(0.094, 0.085, 0.188), vec3f(0.001, 0.001, 0.002), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.155, 0.145, 0.203), vec3f(0.542, 0.505, 0.641), vec3f(0.936, 0.910, 0.977), vec3f(0.964, 0.947, 0.991), vec3f(0.961, 0.961, 0.993), vec3f(0.747, 0.743, 0.945), vec3f(0.341, 0.314, 0.642), vec3f(0.070, 0.056, 0.164), vec3f(0.008, 0.005, 0.021), vec3f(0.000, 0.000, 0.001), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.031, 0.030, 0.041), vec3f(0.257, 0.240, 0.304), vec3f(0.808, 0.783, 0.867), vec3f(0.932, 0.907, 0.973), vec3f(0.905, 0.875, 0.958), vec3f(0.844, 0.818, 0.962), vec3f(0.549, 0.511, 0.863), vec3f(0.253, 0.210, 0.538), vec3f(0.091, 0.070, 0.214), vec3f(0.016, 0.010, 0.039), vec3f(0.001, 0.001, 0.003), vec3f(0.000, 0.000, 0.001), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.003, 0.003, 0.004), vec3f(0.071, 0.066, 0.084), vec3f(0.501, 0.483, 0.552), vec3f(0.874, 0.847, 0.926), vec3f(0.872, 0.838, 0.936), vec3f(0.780, 0.744, 0.844), vec3f(0.628, 0.553, 0.845), vec3f(0.375, 0.307, 0.698), vec3f(0.167, 0.118, 0.385), vec3f(0.073, 0.047, 0.186), vec3f(0.026, 0.017, 0.064), vec3f(0.005, 0.003, 0.013), vec3f(0.000, 0.000, 0.001), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.000, 0.000, 0.000), vec3f(0.013, 0.012, 0.016), vec3f(0.231, 0.222, 0.259), vec3f(0.721, 0.693, 0.785), vec3f(0.871, 0.837, 0.933), vec3f(0.785, 0.753, 0.845), vec3f(0.640, 0.568, 0.827), vec3f(0.395, 0.324, 0.704), vec3f(0.172, 0.124, 0.383), vec3f(0.073, 0.046, 0.184), vec3f(0.028, 0.019, 0.070), vec3f(0.006, 0.004, 0.015), vec3f(0.001, 0.000, 0.002), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.000, 0.000, 0.000), vec3f(0.001, 0.001, 0.002), vec3f(0.063, 0.060, 0.072), vec3f(0.451, 0.428, 0.512), vec3f(0.826, 0.791, 0.891), vec3f(0.780, 0.748, 0.839), vec3f(0.631, 0.562, 0.783), vec3f(0.404, 0.327, 0.678), vec3f(0.174, 0.126, 0.362), vec3f(0.068, 0.041, 0.166), vec3f(0.029, 0.019, 0.072), vec3f(0.006, 0.003, 0.016), vec3f(0.001, 0.001, 0.003), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.009, 0.009, 0.011), vec3f(0.190, 0.179, 0.229), vec3f(0.663, 0.631, 0.736), vec3f(0.771, 0.742, 0.832), vec3f(0.618, 0.558, 0.744), vec3f(0.410, 0.333, 0.651), vec3f(0.173, 0.127, 0.343), vec3f(0.065, 0.040, 0.151), vec3f(0.028, 0.017, 0.069), vec3f(0.006, 0.003, 0.015), vec3f(0.001, 0.001, 0.003), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.001, 0.001, 0.001), vec3f(0.054, 0.049, 0.071), vec3f(0.390, 0.366, 0.459), vec3f(0.728, 0.696, 0.791), vec3f(0.624, 0.569, 0.734), vec3f(0.429, 0.352, 0.650), vec3f(0.182, 0.136, 0.344), vec3f(0.068, 0.043, 0.151), vec3f(0.028, 0.017, 0.070), vec3f(0.007, 0.004, 0.016), vec3f(0.001, 0.001, 0.003), vec3f(0.000, 0.000, 0.001), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.012, 0.010, 0.019), vec3f(0.149, 0.137, 0.192), vec3f(0.563, 0.533, 0.629), vec3f(0.608, 0.560, 0.704), vec3f(0.434, 0.361, 0.625), vec3f(0.184, 0.140, 0.327), vec3f(0.069, 0.045, 0.146), vec3f(0.026, 0.015, 0.062), vec3f(0.007, 0.004, 0.017), vec3f(0.002, 0.001, 0.004), vec3f(0.001, 0.000, 0.001), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.010, 0.008, 0.015), vec3f(0.140, 0.129, 0.181), vec3f(0.549, 0.520, 0.615), vec3f(0.575, 0.532, 0.667), vec3f(0.403, 0.338, 0.573), vec3f(0.167, 0.128, 0.290), vec3f(0.060, 0.040, 0.125), vec3f(0.022, 0.013, 0.054), vec3f(0.008, 0.005, 0.018), vec3f(0.001, 0.001, 0.003), vec3f(0.000, 0.000, 0.001), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.009, 0.008, 0.014), vec3f(0.133, 0.123, 0.173), vec3f(0.538, 0.510, 0.606), vec3f(0.558, 0.516, 0.649), vec3f(0.389, 0.327, 0.547), vec3f(0.158, 0.122, 0.272), vec3f(0.056, 0.037, 0.117), vec3f(0.021, 0.011, 0.050), vec3f(0.008, 0.004, 0.018), vec3f(0.001, 0.001, 0.003), vec3f(0.000, 0.000, 0.001), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.008, 0.007, 0.012), vec3f(0.125, 0.116, 0.162), vec3f(0.526, 0.497, 0.594), vec3f(0.536, 0.497, 0.622), vec3f(0.365, 0.309, 0.506), vec3f(0.144, 0.111, 0.242), vec3f(0.051, 0.035, 0.104), vec3f(0.018, 0.010, 0.042), vec3f(0.007, 0.004, 0.017), vec3f(0.001, 0.001, 0.003), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.007, 0.006, 0.011), vec3f(0.118, 0.110, 0.152), vec3f(0.514, 0.486, 0.581), vec3f(0.520, 0.483, 0.599), vec3f(0.346, 0.296, 0.470), vec3f(0.134, 0.105, 0.217), vec3f(0.046, 0.031, 0.090), vec3f(0.015, 0.008, 0.034), vec3f(0.007, 0.004, 0.015), vec3f(0.001, 0.001, 0.003), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
    vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.008, 0.007, 0.012), vec3f(0.112, 0.105, 0.143), vec3f(0.504, 0.479, 0.568), vec3f(0.510, 0.478, 0.585), vec3f(0.337, 0.292, 0.450), vec3f(0.129, 0.102, 0.205), vec3f(0.042, 0.029, 0.081), vec3f(0.013, 0.008, 0.031), vec3f(0.006, 0.003, 0.014), vec3f(0.001, 0.001, 0.002), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000), vec3f(0.000, 0.000, 0.000),
);

// Luma of the hole matte against radius, one row per key.
const HOLE_MATTE: array<f32, 144> = array<f32, 144>(
    0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000,
    0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000,
    0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000,
    0.006, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000,
    0.192, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000,
    0.995, 0.694, 0.069, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000,
    1.000, 1.000, 0.984, 0.742, 0.194, 0.005, 0.000, 0.000, 0.000,
    1.000, 1.000, 0.999, 0.973, 0.724, 0.203, 0.008, 0.000, 0.000,
    1.000, 1.000, 1.000, 0.992, 0.888, 0.445, 0.057, 0.000, 0.000,
    1.000, 1.000, 1.000, 0.995, 0.931, 0.563, 0.106, 0.002, 0.000,
    1.000, 1.000, 1.000, 0.995, 0.941, 0.594, 0.121, 0.002, 0.000,
    1.000, 1.000, 1.000, 0.995, 0.942, 0.593, 0.118, 0.002, 0.000,
    1.000, 1.000, 1.000, 0.995, 0.942, 0.592, 0.116, 0.002, 0.000,
    1.000, 1.000, 1.000, 0.995, 0.942, 0.592, 0.114, 0.002, 0.000,
    1.000, 1.000, 1.000, 0.995, 0.942, 0.592, 0.114, 0.002, 0.000,
    1.000, 1.000, 1.000, 0.995, 0.942, 0.594, 0.116, 0.002, 0.000,
);

// Cubic Bezier easing through (0,0), (k.x,k.y), (k.z,k.w), (1,1), solved for x by bisection.
fn bezier_y(x: f32, k: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 16; n++) {
        let s = (lo + hi) * 0.5;
        let r = 1.0 - s;
        if (3.0 * r * r * s * k.x + 3.0 * r * s * s * k.z + s * s * s > x) { hi = s; } else { lo = s; }
    }
    let s = (lo + hi) * 0.5;
    let r = 1.0 - s;
    return 3.0 * r * r * s * k.y + 3.0 * r * s * s * k.w + s * s * s;
}

const SOFT: vec4f = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

// Rises 0 -> 1 over [t0, t1], falls back over [t1, t2].
fn swell(t: f32, t0: f32, t1: f32, t2: f32) -> f32 {
    if (t <= t0 || t >= t2) { return 0.0; }
    if (t < t1) { return bezier_y((t - t0) / (t1 - t0), SOFT); }
    return 1.0 - bezier_y((t - t1) / (t2 - t1), SOFT);
}

// Common zoom of the clip, ring and hole.
fn zoom(t: f32) -> f32 {
    let k = bezier_y(clamp((t - 0.533333) / 0.466667, 0.0, 1.0), vec4f(0.78, 0.0, 0.22, 1.0));
    return BASE_SCALE * mix(1.0, ZOOM_END, k);
}

fn hash_u(v: u32) -> u32 {
    var s = v * 747796405u + 2891336453u;
    s = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (s >> 22u) ^ s;
}

fn lattice(c: vec2i) -> f32 {
    let h = hash_u((u32(c.x) * 1597334677u) ^ hash_u(u32(c.y) + 3812015801u));
    return f32(h) / 4294967296.0;
}

// Value noise, periodic in x with period `wrap` cells.
fn value_noise(p: vec2f, wrap: i32) -> f32 {
    let i = vec2i(floor(p));
    let f = p - floor(p);
    let s = f * f * (3.0 - 2.0 * f);
    let x0 = ((i.x % wrap) + wrap) % wrap;
    let x1 = (x0 + 1) % wrap;
    let a = lattice(vec2i(x0, i.y));
    let b = lattice(vec2i(x1, i.y));
    let c = lattice(vec2i(x0, i.y + 1));
    let d = lattice(vec2i(x1, i.y + 1));
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

// Radially streaked flicker around 1.0 for the ring at polar point (ang 0..1, r).
fn streaks(ang: f32, r: f32, t: f32) -> f32 {
    let n1 = value_noise(vec2f(ang * 36.0, r * 6.0 - t * 4.0), 36);
    let n2 = value_noise(vec2f(ang * 90.0, r * 14.0 - t * 9.0), 90);
    return 0.55 + 0.9 * (0.65 * n1 + 0.35 * n2);
}

// Linear lookup in one radial row of the ring table.
fn ring_at(row: i32, r: f32) -> vec3f {
    let x = r / RADIAL_STEP;
    let i = i32(floor(x));
    if (i >= RING_BINS - 1) { return vec3f(0.0); }
    let f = x - f32(i);
    return mix(PORTAL_RGB[row * RING_BINS + i], PORTAL_RGB[row * RING_BINS + i + 1], f);
}

fn hole_at(row: i32, r: f32) -> f32 {
    let x = r / RADIAL_STEP;
    let i = i32(floor(x));
    if (i >= HOLE_BINS - 1) { return 0.0; }
    let f = x - f32(i);
    return mix(HOLE_MATTE[row * HOLE_BINS + i], HOLE_MATTE[row * HOLE_BINS + i + 1], f);
}

// The two table rows around animation time t and their blend weight.
fn rows(t: f32) -> vec3f {
    let k = clamp(t * RATE * 0.5, 0.0, f32(KEY_ROWS - 1));
    let r0 = min(floor(k), f32(KEY_ROWS - 2));
    return vec3f(r0, r0 + 1.0, k - r0);
}

fn mirror(p: vec2f) -> vec2f {
    return abs(p - 2.0 * floor((p + 1.0) * 0.5));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SCENE;
    let dims = globals.size;
    let short_side = min(dims.x, dims.y);
    let long_side = max(dims.x, dims.y);
    let s = zoom(t);
    let rw = rows(t);

    // Shake of everything under the ring (random seed 0: no phase offsets).
    let amp = SHAKE_PEAK * swell(t, 0.133333, 0.266667, 0.433333) * SHAKE_REACH;
    let w = PI * t * SHAKE_RATE;
    let dx = amp * 0.5 * (0.5 * cos(w) + 0.32 * sin(1.5 * w) + 0.18 * cos(2.5 * w));
    let dy = amp * 0.5 * (0.5 * sin(w) + 0.32 * cos(1.5 * w) + 0.18 * sin(2.5 * w));
    let shaken = mirror(uv + vec2f(dx, dy) * (short_side / 1080.0) / dims);

    // Hole matte and zoomed first clip, in the shaken frame.
    let cs = (shaken - 0.5) * dims / long_side;
    let rh = length(cs) / s;
    var hole = mix(hole_at(i32(rw.x), rh), hole_at(i32(rw.y), rh), rw.z);
    // Corners the zoomed hole does not reach are cleared over the last three frames.
    hole = max(hole, clamp((t - 0.933333) / 0.1, 0.0, 1.0));
    let a = textureSampleLevel(first, smp, 0.5 + (shaken - 0.5) / s, 0.0).rgb;
    let b = textureSampleLevel(second, smp, shaken, 0.0).rgb;
    var color = mix(a, b, hole);

    // Ring over the shaken layers (premultiplied, coverage = brightest channel).
    let c = (uv - 0.5) * dims / long_side;
    let r = length(c) / s;
    var ring = mix(ring_at(i32(rw.x), r), ring_at(i32(rw.y), r), rw.z);
    if (max(ring.r, max(ring.g, ring.b)) > 0.0) {
        let ang = atan2(c.y, c.x) / (2.0 * PI) + 0.5;
        ring = min(ring * streaks(ang, r, t), vec3f(1.0));
    }
    ring *= 1.0 - bezier_y(clamp((t - 0.8) / 0.2, 0.0, 1.0), SOFT);
    let cover = max(ring.r, max(ring.g, ring.b));
    color = ring + color * (1.0 - cover);
    gpufx_write(id, vec4f(color, 1.0));
}
