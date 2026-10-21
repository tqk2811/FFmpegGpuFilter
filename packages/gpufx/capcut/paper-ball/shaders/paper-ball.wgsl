// A crumpled paper ball lands on the first clip, unfolds into a sheet and tears open on the second clip.

// The animation runs in ten held steps, like a flip book.
const STEPS: f32 = 9.99;
// Crumple texture: mean grey of the baked shading and its standard deviation.
const CRUMPLE_MEAN: f32 = 0.5;
const CRUMPLE_STD: f32 = 0.174;
// Number of samples around the outline tables below.
const RAYS: i32 = 24;

// Scale of the incoming sheet for each step (it grows to full frame).
var<private> SHEET_SCALE: array<f32, 10> = array<f32, 10>(0.47, 0.47, 0.46, 0.64, 0.73, 0.9, 0.955, 0.99, 0.985, 1.0);
// How much the overlay shapes follow the frame instead of a centred square (0 = square, 1 = frame).
var<private> FIT_FRAME: array<f32, 10> = array<f32, 10>(0.0, 0.0, 0.0, 0.5, 0.75, 0.9, 1.0, 1.0, 1.0, 1.0);
// Crease shading laid over the incoming sheet: opacity, mean tone and texture strength per step.
var<private> SHEET_CREASE: array<vec3f, 10> = array<vec3f, 10>(
    vec3f(0.0, 0.88, 0.0), vec3f(0.987, 0.881, 0.054), vec3f(0.988, 0.883, 0.05), vec3f(0.988, 0.878, 0.053),
    vec3f(0.976, 0.875, 0.056), vec3f(0.6, 0.878, 0.055), vec3f(0.56, 0.877, 0.054), vec3f(0.4, 0.878, 0.032),
    vec3f(0.314, 0.937, 0.017), vec3f(0.263, 0.874, 0.0));
// Shadow along the inside of the tear: darkness and width (fraction of the tear radius) per step.
var<private> TEAR_SHADOW: array<vec2f, 10> = array<vec2f, 10>(
    vec2f(0.0, 0.3), vec2f(0.45, 0.6), vec2f(0.45, 0.5), vec2f(0.6, 0.45), vec2f(0.65, 0.4),
    vec2f(0.6, 0.35), vec2f(0.55, 0.3), vec2f(0.4, 0.2), vec2f(0.3, 0.12), vec2f(0.0, 0.1));
// Bent outline of the incoming sheet: 12 Bezier handles per step, in a 1280 grid with y down.
// Order: top-left, top-left handle, top-right handle, right-top, right-top handle, right-bottom handle,
// bottom-right, bottom-right handle, bottom-left handle, left-bottom, left-bottom handle, left-top handle.
var<private> SHEET_EDGE: array<vec2f, 120> = array<vec2f, 120>(
    vec2f(0.14008, 0.27960), vec2f(0.38857, 0.26064), vec2f(0.55804, 0.24912), vec2f(0.72679, 0.28690), vec2f(0.88646, 0.38208), vec2f(0.87240, 0.66260), vec2f(0.92784, 0.83963), vec2f(0.61729, 0.74427), vec2f(0.80656, 0.81250), vec2f(0.15581, 0.79617), vec2f(0.18659, 0.65307), vec2f(0.17191, 0.44188),
    vec2f(0.14008, 0.27960), vec2f(0.38857, 0.26064), vec2f(0.55804, 0.24912), vec2f(0.72679, 0.28690), vec2f(0.88646, 0.38208), vec2f(0.87240, 0.66260), vec2f(0.92784, 0.83963), vec2f(0.61729, 0.74427), vec2f(0.80656, 0.81250), vec2f(0.15581, 0.79617), vec2f(0.18659, 0.65307), vec2f(0.17191, 0.44188),
    vec2f(0.25727, 0.31018), vec2f(0.39027, 0.31329), vec2f(0.55634, 0.29668), vec2f(0.73698, 0.31917), vec2f(0.78116, 0.40926), vec2f(0.80106, 0.65581), vec2f(0.76819, 0.75132), vec2f(0.50520, 0.74767), vec2f(0.48048, 0.75476), vec2f(0.25262, 0.76220), vec2f(0.24094, 0.65137), vec2f(0.22456, 0.44188),
    vec2f(0.14008, 0.27960), vec2f(0.38857, 0.26064), vec2f(0.55804, 0.24912), vec2f(0.72679, 0.28690), vec2f(0.77904, 0.38697), vec2f(0.75521, 0.65284), vec2f(0.92784, 0.83963), vec2f(0.36583, 0.71497), vec2f(0.80656, 0.81250), vec2f(0.11675, 0.72049), vec2f(0.18659, 0.65307), vec2f(0.07670, 0.45653),
    vec2f(0.18517, 0.18390), vec2f(0.39517, 0.17720), vec2f(0.59981, 0.18905), vec2f(0.80737, 0.16878), vec2f(0.81504, 0.37456), vec2f(0.81122, 0.59226), vec2f(0.92784, 0.83963), vec2f(0.69035, 0.82511), vec2f(0.28152, 0.83358), vec2f(0.13817, 0.82578), vec2f(0.16038, 0.63468), vec2f(0.18603, 0.35661),
    vec2f(0.07950, 0.14154), vec2f(0.32345, 0.15173), vec2f(0.66086, 0.11423), vec2f(0.84815, 0.09642), vec2f(0.90264, 0.31066), vec2f(0.93251, 0.65053), vec2f(0.98650, 0.90947), vec2f(0.59191, 0.96280), vec2f(0.33216, 0.96260), vec2f(0.01309, 0.85831), vec2f(0.08015, 0.64009), vec2f(0.06831, 0.31797),
    vec2f(0.07950, 0.14154), vec2f(0.32345, 0.15173), vec2f(0.66086, 0.11423), vec2f(0.84815, 0.09642), vec2f(0.90264, 0.31066), vec2f(0.93251, 0.65053), vec2f(0.98650, 0.90947), vec2f(0.59191, 0.96280), vec2f(0.33216, 0.96260), vec2f(0.01309, 0.85831), vec2f(0.08015, 0.64009), vec2f(0.06831, 0.31797),
    vec2f(0.02992, 0.02327), vec2f(0.33665, 0.01995), vec2f(0.64338, 0.02992), vec2f(0.94681, 0.02660), vec2f(0.97673, 0.32668), vec2f(1.08311, 0.65668), vec2f(0.90359, 0.97673), vec2f(0.63673, 0.96011), vec2f(0.33665, 0.97008), vec2f(0.04987, 0.94016), vec2f(0.00000, 0.66666), vec2f(0.00000, 0.33333),
    vec2f(0.00957, 0.00478), vec2f(0.31087, 0.00000), vec2f(0.66666, -0.01594), vec2f(0.99043, 0.00638), vec2f(1.00000, 0.33333), vec2f(1.04783, 0.65362), vec2f(0.98645, 0.99761), vec2f(0.66666, 1.01276), vec2f(0.31406, 1.01913), vec2f(0.00478, 0.99203), vec2f(-0.00478, 0.65841), vec2f(0.00000, 0.33333),
    vec2f(0.00000, 0.00000), vec2f(0.33333, 0.00000), vec2f(0.66666, 0.00000), vec2f(1.00000, 0.00000), vec2f(1.00000, 0.33333), vec2f(1.00000, 0.66666), vec2f(1.00000, 1.00000), vec2f(0.66666, 1.00000), vec2f(0.33333, 1.00000), vec2f(0.00000, 1.00000), vec2f(0.00000, 0.66666), vec2f(0.00000, 0.33333)
);
// Outline of the paper ball (steps 0..8): centre and radius along  rays, in square overlay space, y down.
var<private> BALL_CENTRE: array<vec2f, 9> = array<vec2f, 9>(vec2f(0.509, 0.476), vec2f(0.502, 0.473), vec2f(0.493, 0.488), vec2f(0.494, 0.487), vec2f(0.480, 0.495), vec2f(0.511, 0.494), vec2f(0.489, 0.510), vec2f(0.505, 0.494), vec2f(0.500, 0.498));
var<private> BALL_RADIUS: array<f32, 216> = array<f32, 216>(
    0.076, 0.070, 0.075, 0.075, 0.080, 0.073, 0.071, 0.068, 0.064, 0.068, 0.075, 0.075, 0.074, 0.070, 0.071, 0.075, 0.075, 0.081, 0.078, 0.068, 0.059, 0.066, 0.073, 0.068,
    0.070, 0.074, 0.074, 0.078, 0.079, 0.076, 0.070, 0.061, 0.065, 0.069, 0.074, 0.074, 0.071, 0.070, 0.071, 0.074, 0.080, 0.080, 0.073, 0.063, 0.064, 0.070, 0.069, 0.074,
    0.115, 0.120, 0.113, 0.099, 0.096, 0.106, 0.106, 0.123, 0.133, 0.135, 0.129, 0.126, 0.109, 0.106, 0.100, 0.101, 0.115, 0.116, 0.134, 0.121, 0.118, 0.123, 0.135, 0.120,
    0.158, 0.158, 0.152, 0.141, 0.136, 0.145, 0.159, 0.158, 0.149, 0.158, 0.157, 0.155, 0.144, 0.149, 0.150, 0.152, 0.154, 0.163, 0.150, 0.141, 0.131, 0.149, 0.160, 0.165,
    0.240, 0.238, 0.250, 0.219, 0.215, 0.214, 0.213, 0.227, 0.217, 0.222, 0.232, 0.225, 0.210, 0.210, 0.220, 0.243, 0.250, 0.242, 0.227, 0.219, 0.173, 0.175, 0.197, 0.249,
    0.299, 0.289, 0.284, 0.275, 0.279, 0.309, 0.273, 0.247, 0.234, 0.237, 0.254, 0.308, 0.295, 0.299, 0.285, 0.283, 0.290, 0.279, 0.272, 0.250, 0.239, 0.234, 0.255, 0.316,
    0.376, 0.324, 0.316, 0.311, 0.317, 0.334, 0.361, 0.354, 0.336, 0.342, 0.364, 0.364, 0.359, 0.352, 0.318, 0.329, 0.337, 0.349, 0.322, 0.343, 0.333, 0.336, 0.366, 0.404,
    0.455, 0.476, 0.475, 0.462, 0.408, 0.392, 0.406, 0.468, 0.443, 0.419, 0.429, 0.463, 0.465, 0.453, 0.452, 0.467, 0.442, 0.438, 0.397, 0.466, 0.427, 0.421, 0.441, 0.470,
    0.475, 0.490, 0.546, 0.655, 0.535, 0.510, 0.492, 0.505, 0.565, 0.545, 0.535, 0.491, 0.476, 0.493, 0.542, 0.576, 0.562, 0.507, 0.487, 0.502, 0.520, 0.640, 0.496, 0.492
);
// Outline of the tear (steps 1..8; row 0 unused).
var<private> HOLE_CENTRE: array<vec2f, 9> = array<vec2f, 9>(vec2f(0.5, 0.5), vec2f(0.501, 0.464), vec2f(0.514, 0.451), vec2f(0.508, 0.440), vec2f(0.451, 0.473), vec2f(0.497, 0.466), vec2f(0.485, 0.491), vec2f(0.507, 0.470), vec2f(0.505, 0.490));
var<private> HOLE_RADIUS: array<f32, 216> = array<f32, 216>(
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.009, 0.028, 0.016, 0.011, 0.009, 0.009, 0.008, 0.005, 0.005, 0.004, 0.006, 0.005, 0.010, 0.026, 0.018, 0.013, 0.010, 0.004, 0.001, 0.001, 0.001, 0.001, 0.003, 0.005,
    0.045, 0.050, 0.038, 0.033, 0.019, 0.011, 0.011, 0.009, 0.010, 0.009, 0.010, 0.011, 0.050, 0.048, 0.035, 0.033, 0.030, 0.011, 0.005, 0.004, 0.004, 0.005, 0.006, 0.023,
    0.096, 0.086, 0.045, 0.035, 0.034, 0.035, 0.039, 0.044, 0.043, 0.039, 0.040, 0.041, 0.090, 0.066, 0.055, 0.053, 0.051, 0.054, 0.036, 0.028, 0.025, 0.023, 0.021, 0.029,
    0.184, 0.130, 0.131, 0.126, 0.115, 0.090, 0.079, 0.076, 0.080, 0.091, 0.114, 0.134, 0.160, 0.121, 0.104, 0.099, 0.109, 0.136, 0.124, 0.090, 0.088, 0.076, 0.068, 0.064,
    0.259, 0.219, 0.198, 0.183, 0.198, 0.162, 0.136, 0.125, 0.125, 0.136, 0.184, 0.245, 0.232, 0.209, 0.210, 0.200, 0.205, 0.160, 0.138, 0.128, 0.125, 0.099, 0.131, 0.215,
    0.387, 0.328, 0.268, 0.267, 0.264, 0.278, 0.274, 0.244, 0.238, 0.249, 0.363, 0.364, 0.354, 0.336, 0.280, 0.269, 0.277, 0.257, 0.258, 0.279, 0.232, 0.247, 0.279, 0.408,
    0.452, 0.473, 0.475, 0.458, 0.328, 0.309, 0.327, 0.374, 0.377, 0.371, 0.436, 0.471, 0.465, 0.444, 0.460, 0.388, 0.354, 0.349, 0.369, 0.439, 0.352, 0.363, 0.378, 0.468,
    0.470, 0.483, 0.542, 0.522, 0.496, 0.517, 0.500, 0.455, 0.461, 0.480, 0.520, 0.497, 0.480, 0.497, 0.530, 0.487, 0.502, 0.500, 0.480, 0.492, 0.505, 0.488, 0.481, 0.486
);

// Handle `k` of step `s`, flipped to y up.
fn edge_point(s: i32, k: i32) -> vec2f {
    let p = SHEET_EDGE[s * 12 + k];
    return vec2f(p.x, 1.0 - p.y);
}

// Point on a cubic Bezier segment (de Casteljau).
fn bezier(a: vec2f, b: vec2f, c: vec2f, d: vec2f, t: f32) -> vec2f {
    let ab = mix(a, b, t);
    let bc = mix(b, c, t);
    let cd = mix(c, d, t);
    return mix(mix(ab, bc, t), mix(bc, cd, t), t);
}

// Where the sheet point `g` (0..1, y up) lands on screen (-1..1, y up) at step `s`: a patch
// bounded by four Bezier edges, blended in both directions, then scaled about the centre.
fn sheet_forward(s: i32, g: vec2f) -> vec2f {
    let tlv = edge_point(s, 0);
    let tlt = edge_point(s, 1);
    let trt = edge_point(s, 2);
    let rtv = edge_point(s, 3);
    let rtt = edge_point(s, 4);
    let rbt = edge_point(s, 5);
    let brv = edge_point(s, 6);
    let brt = edge_point(s, 7);
    let blt = edge_point(s, 8);
    let lbv = edge_point(s, 9);
    let lbt = edge_point(s, 10);
    let ltt = edge_point(s, 11);

    // Horizontal pass: left and right edges give the row ends, inner handles blend bottom to top.
    let row_l = bezier(lbv, lbt, ltt, tlv, g.y);
    let row_r = bezier(brv, rbt, rtt, rtv, g.y);
    let ey = smoothstep(0.0, 1.0, g.y);
    let shift_x = mix(-mix(lbv.x, tlv.x, ey), 1.0 - mix(brv.x, rtv.x, ey), g.x) + mix(row_l.x, row_r.x - 1.0, g.x);
    let h1 = mix(blt, tlt, vec2f(ey, g.y)) + vec2f(shift_x, 0.0);
    let h2 = mix(brt, trt, vec2f(ey, g.y)) + vec2f(shift_x, 0.0);
    let across = bezier(row_l, h1, h2, row_r, g.x);

    // Vertical pass: bottom and top edges give the column ends.
    let col_b = bezier(lbv, blt, brt, brv, g.x);
    let col_t = bezier(tlv, tlt, trt, rtv, g.x);
    let ex = smoothstep(0.0, 1.0, g.x);
    let shift_y = mix(-mix(lbv.y, brv.y, ex), 1.0 - mix(tlv.y, rtv.y, ex), g.y) + mix(col_b.y, col_t.y - 1.0, g.y);
    let v1 = mix(lbt, rbt, vec2f(g.x, ex)) + vec2f(0.0, shift_y);
    let v2 = mix(ltt, rtt, vec2f(g.x, ex)) + vec2f(0.0, shift_y);
    let down = bezier(col_b, v1, v2, col_t, g.y);

    return (vec2f(across.x, down.y) * 2.0 - 1.0) * SHEET_SCALE[s];
}

// Inverse of sheet_forward by Newton steps: the sheet point seen at screen point `ndc`.
fn sheet_inverse(s: i32, ndc: vec2f) -> vec2f {
    var g = clamp(ndc / SHEET_SCALE[s] * 0.5 + 0.5, vec2f(0.0), vec2f(1.0));
    let h = 1e-3;
    for (var i = 0; i < 10; i++) {
        let f = sheet_forward(s, g) - ndc;
        let jx = (sheet_forward(s, g + vec2f(h, 0.0)) - ndc - f) / h;
        let jy = (sheet_forward(s, g + vec2f(0.0, h)) - ndc - f) / h;
        let det = jx.x * jy.y - jy.x * jx.y;
        if (abs(det) < 1e-8) { break; }
        let step = vec2f(jy.y * f.x - jy.x * f.y, jx.x * f.y - jx.y * f.x) / det;
        g -= step;
        g = clamp(g, vec2f(-0.5), vec2f(1.5));
    }
    return g;
}

// Radius of an outline table row along direction `d` (y down), interpolated between rays.
fn outline_radius(table: i32, s: i32, d: vec2f) -> f32 {
    var a = atan2(d.y, d.x);
    if (a < 0.0) { a += 6.2831853; }
    let x = a / 6.2831853 * f32(RAYS);
    let i0 = i32(floor(x)) % RAYS;
    let i1 = (i0 + 1) % RAYS;
    let t = fract(x);
    if (table == 0) {
        return mix(BALL_RADIUS[s * RAYS + i0], BALL_RADIUS[s * RAYS + i1], t);
    }
    return mix(HOLE_RADIUS[s * RAYS + i0], HOLE_RADIUS[s * RAYS + i1], t);
}

// Baked crease shading, tiled.
fn crumple(p: vec2f) -> f32 {
    return textureSampleLevel(crease, smp, fract(p), 0.0).r;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = params.progress;
    // Exact clips at the ends of the transition.
    if (p <= 0.0) { gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0)); return; }
    if (p >= 1.0) { gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0)); return; }

    let s = min(i32(floor(p * STEPS)), 9);
    let size = globals.size;
    let px = 1.0 / max(size.x, size.y);

    // Overlay space: a centred square covering the frame, slightly shrunk on wide or tall frames,
    // easing into plain frame coordinates as the sheet opens.
    let ratio = max(size.x, size.y) / min(size.x, size.y);
    let square = (uv * size - 0.5 * size) / max(size.x, size.y) / mix(1.0, 0.9, clamp(ratio - 1.0, 0.0, 1.0)) + 0.5;
    let q = mix(square, uv, FIT_FRAME[s]);

    // First clip with the paper ball on top.
    var col = textureSampleLevel(first, smp, uv, 0.0).rgb;
    if (s < 9) {
        let c = BALL_CENTRE[s];
        let d = q - c;
        let r = outline_radius(0, s, d);
        let inside = 1.0 - smoothstep(r - px, r + px, length(d));
        if (inside > 0.0) {
            let req = mix(0.07, 0.53, f32(s) / 8.0);
            let rim = smoothstep(0.55, 1.0, length(d) / max(r, 1e-4));
            let shade = 0.86 + (crumple(d / req * 0.45 + 0.37) - CRUMPLE_MEAN) * 0.3 - rim * 0.05;
            col = mix(col, vec3f(shade, shade * 1.005, shade * 1.004), inside);
        }
    }

    // Tear in the paper, showing the bent, creased second clip.
    var hole = 0.0;
    var edge_dist = 1.0;
    if (s >= 9) {
        hole = 1.0;
    } else if (s >= 1) {
        let c = HOLE_CENTRE[s];
        let d = q - c;
        let r = outline_radius(1, s, d);
        hole = 1.0 - smoothstep(r - px, r + px, length(d));
        edge_dist = 1.0 - length(d) / max(r, 1e-4);
    }
    if (hole > 0.0) {
        let ndc = vec2f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
        let g = sheet_inverse(s, ndc);
        var sheet = vec3f(0.0);
        if (all(g >= vec2f(0.0)) && all(g <= vec2f(1.0))) {
            let suv = vec2f(g.x, 1.0 - g.y);
            sheet = textureSampleLevel(second, smp, suv, 0.0).rgb;
            let cr = SHEET_CREASE[s];
            let tone = cr.y + (crumple(suv) - CRUMPLE_MEAN) * (cr.z / CRUMPLE_STD);
            sheet = mix(sheet, sheet * clamp(tone, 0.0, 1.0), cr.x);
        }
        let sh = TEAR_SHADOW[s];
        let shadow = sh.x * (1.0 - smoothstep(0.0, sh.y, edge_dist));
        sheet = sheet * mix(1.0, 0.2, shadow);
        col = mix(col, sheet, hole);
    }
    gpufx_write(id, vec4f(col, 1.0));
}
