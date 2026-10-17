// A rounded card of the incoming clip swings up from below, flips over in 3D and bursts open into the second clip.

// Length of the keyframed timeline in seconds; progress enters it 3% in and runs to its end.
const TIMELINE: f32 = 1.1;

fn timeline() -> f32 {
    return (0.03 + 0.97 * clamp(params.progress, 0.0, 1.0)) * TIMELINE;
}

// CSS-style cubic-bezier easing from (0,0) to (1,1) with handles (h.x,h.y) and (h.z,h.w).
fn ease(h: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
        let m = 0.5 * (lo + hi);
        let im = 1.0 - m;
        let bx = 3.0 * im * im * m * h.x + 3.0 * im * m * m * h.z + m * m * m;
        if (bx > x) { hi = m; } else { lo = m; }
    }
    let s = 0.5 * (lo + hi);
    let is = 1.0 - s;
    return 3.0 * is * is * s * h.y + 3.0 * is * s * s * h.w + s * s * s;
}

// Eased value of a key segment [t0, t1] going from a to b.
fn key(t: f32, t0: f32, t1: f32, a: f32, b: f32, h: vec4f) -> f32 {
    return mix(a, b, ease(h, clamp((t - t0) / (t1 - t0), 0.0, 1.0)));
}

const PI: f32 = 3.14159265;

// Card path in the 720x960 design frame: two cubic curves (start, handle, handle, end).
const PATH_A0: vec3f = vec3f(270.0, 2059.0, -91.0);
const PATH_A1: vec3f = vec3f(285.965386, 1821.324280, -91.0);
const PATH_A2: vec3f = vec3f(365.792316, 632.945657, -91.0);
const PATH_A3: vec3f = vec3f(365.792316, 632.945657, -91.0);
const PATH_B0: vec3f = vec3f(365.792316, 632.945657, -91.0);
const PATH_B1: vec3f = vec3f(371.798135, 549.866930, -91.0);
const PATH_B2: vec3f = vec3f(369.453182, 449.555288, -91.0);
const PATH_B3: vec3f = vec3f(361.0, 386.793562, -91.0);

// Card orientation (degrees about x, y, z) at each knot, linear in between; x = time.
var<private> TURN: array<vec4f, 38> = array<vec4f, 38>(
    vec4f(0.000000, 0.000000, 0.000000, 0.000000),
    vec4f(0.033333, 359.990207, 359.906829, 359.999992),
    vec4f(0.066667, 359.938511, 359.414995, 359.999686),
    vec4f(0.100000, 359.887058, 358.925558, 359.998941),
    vec4f(0.233333, 359.687912, 357.033351, 359.991919),
    vec4f(0.366667, 359.488083, 355.141179, 359.978281),
    vec4f(0.400000, 359.464556, 354.919030, 359.976243),
    vec4f(0.433333, 359.002427, 346.391707, 359.877059),
    vec4f(0.466667, 357.848236, 328.204071, 359.374519),
    vec4f(0.488867, 356.795326, 316.158751, 358.691410),
    vec4f(0.500000, 356.093267, 310.140945, 358.161594),
    vec4f(0.503320, 355.849167, 308.349076, 357.967495),
    vec4f(0.506673, 355.584706, 306.557769, 357.752495),
    vec4f(0.522201, 353.966827, 298.213618, 356.359090),
    vec4f(0.533333, 352.141529, 292.271034, 354.689055),
    vec4f(0.536654, 351.408044, 290.511432, 354.001036),
    vec4f(0.540007, 350.542998, 288.755488, 353.181206),
    vec4f(0.544466, 349.109529, 286.417405, 351.807789),
    vec4f(0.546680, 348.236341, 285.256920, 350.964387),
    vec4f(0.550000, 346.645804, 283.517113, 349.418554),
    vec4f(0.553320, 344.596506, 281.790277, 347.413801),
    vec4f(0.555534, 342.875481, 280.653813, 345.722278),
    vec4f(0.559993, 338.045944, 278.412666, 340.951797),
    vec4f(0.563346, 332.393153, 276.795617, 335.343100),
    vec4f(0.566667, 323.388498, 275.283725, 326.382468),
    vec4f(0.569987, 308.223761, 274.011341, 311.261174),
    vec4f(0.573340, 282.922623, 273.231499, 286.003449),
    vec4f(0.576660, 251.741462, 273.312967, 254.865727),
    vec4f(0.580013, 228.297793, 274.206801, 231.465510),
    vec4f(0.583333, 214.485563, 275.534612, 217.696832),
    vec4f(0.586654, 206.288948, 277.055092, 209.543822),
    vec4f(0.588867, 202.582047, 278.118862, 205.865918),
    vec4f(0.593327, 197.481782, 280.323449, 200.823972),
    vec4f(0.600000, 192.937875, 283.713224, 196.367777),
    vec4f(0.633333, 185.227426, 300.812590, 189.101751),
    vec4f(0.666667, 182.871000, 317.302924, 187.206104),
    vec4f(0.700000, 181.541030, 333.821627, 186.399442),
    vec4f(0.733333, 180.563039, 350.350161, 186.048813)
);

fn curve(p0: vec3f, p1: vec3f, p2: vec3f, p3: vec3f, s: f32) -> vec3f {
    let r = 1.0 - s;
    return r * r * r * p0 + 3.0 * r * r * s * p1 + 3.0 * r * s * s * p2 + s * s * s * p3;
}

// Point at fraction `f` of the curve length, measured on 200 steps as the motion was authored.
fn along(p0: vec3f, p1: vec3f, p2: vec3f, p3: vec3f, f: f32) -> vec3f {
    if (f <= 0.0) { return p0; }
    if (f >= 1.0) { return p3; }
    var total = 0.0;
    var prev = p0;
    for (var i = 1; i <= 200; i++) {
        let q = curve(p0, p1, p2, p3, f32(i) / 200.0);
        total += length(q - prev);
        prev = q;
    }
    let goal = f * (total + 0.000001);
    var run = 0.0;
    prev = p0;
    for (var i = 1; i <= 200; i++) {
        let q = curve(p0, p1, p2, p3, f32(i) / 200.0);
        let step_len = length(q - prev);
        if (run + step_len >= goal) {
            let k = (goal - run) / (step_len + 0.000001);
            return curve(p0, p1, p2, p3, (f32(i - 1) + k) / 200.0);
        }
        run += step_len;
        prev = q;
    }
    return p3;
}

fn card_position(t: f32) -> vec3f {
    if (t < 0.4) {
        return along(PATH_A0, PATH_A1, PATH_A2, PATH_A3, ease(vec4f(0.333333, 0.0, 0.666667, 1.0), t / 0.4));
    }
    if (t < 0.766667) {
        return along(PATH_B0, PATH_B1, PATH_B2, PATH_B3, ease(vec4f(0.166667, 0.0, 0.666667, 1.0), (t - 0.4) / 0.366667));
    }
    return PATH_B3;
}

// Card scale in percent.
fn card_scale(t: f32) -> vec3f {
    if (t < 0.4) {
        let k = ease(vec4f(0.333333, 0.0, 0.833333, 1.0), t / 0.4);
        return mix(vec3f(300.323870, 300.323870, 258.946749), vec3f(124.053235, 124.053235, 248.485944), k);
    }
    if (t < 0.766667) {
        let k = ease(vec4f(0.166667, 0.0, 0.833333, 1.0), (t - 0.4) / 0.366667);
        return mix(vec3f(124.053235, 124.053235, 248.485944), vec3f(96.0, 96.0, 192.293661), k);
    }
    return vec3f(96.0, 96.0, 192.293661);
}

fn card_turn(t: f32) -> vec3f {
    if (t >= 0.766667) { return vec3f(0.0, 179.0, 5.976243); }
    if (t >= 0.733333) { return TURN[37].yzw; }
    for (var i = 1; i < 38; i++) {
        if (t < TURN[i].x) {
            let a = TURN[i - 1];
            let b = TURN[i];
            return mix(a.yzw, b.yzw, clamp((t - a.x) / (b.x - a.x), 0.0, 1.0));
        }
    }
    return TURN[37].yzw;
}

fn rot_x(a: f32) -> mat3x3f {
    let c = cos(a);
    let s = sin(a);
    return mat3x3f(vec3f(1.0, 0.0, 0.0), vec3f(0.0, c, s), vec3f(0.0, -s, c));
}

fn rot_y(a: f32) -> mat3x3f {
    let c = cos(a);
    let s = sin(a);
    return mat3x3f(vec3f(c, 0.0, -s), vec3f(0.0, 1.0, 0.0), vec3f(s, 0.0, c));
}

fn rot_z(a: f32) -> mat3x3f {
    let c = cos(a);
    let s = sin(a);
    return mat3x3f(vec3f(c, s, 0.0), vec3f(-s, c, 0.0), vec3f(0.0, 0.0, 1.0));
}

// Soft light-leak wash added over the card (orange flare, pink corner, blue streak), 0..1 coordinates.
fn leak(q: vec2f) -> vec3f {
    var c = vec3f(0.078, 0.067, 0.071);
    let dw = (q.x - 0.28) / 0.13;
    let warm = exp(-dw * dw) * (1.0 - smoothstep(0.1, 0.75, q.y));
    c += warm * vec3f(0.40, 0.13, 0.0);
    let corner = q - vec2f(0.0, 0.1);
    c += exp(-dot(corner, corner) / 0.04) * vec3f(0.32, 0.10, 0.13);
    let run = clamp(dot(q - vec2f(0.05, 0.45), vec2f(0.35, 0.55)) / 0.425, 0.0, 1.0);
    let foot = q - (vec2f(0.05, 0.45) + run * vec2f(0.35, 0.55));
    c += exp(-dot(foot, foot) / 0.012) * run * vec3f(0.08, 0.22, 0.42);
    let spot = q - vec2f(0.33, 0.97);
    c += exp(-dot(spot, spot) / 0.006) * vec3f(0.12, 0.30, 0.62);
    let dm = (q.x - 0.5) / 0.12;
    c += exp(-dm * dm) * smoothstep(0.2, 0.9, q.y) * vec3f(0.14, 0.12, 0.12);
    return min(c, vec3f(1.0));
}

// Rounded square that cuts the card, on a grid where the short side is 720 units.
const BOX_CENTER: vec2f = vec2f(359.44, 478.44);
const BOX_HALF: f32 = 229.44;
const BOX_RADIUS: f32 = 53.0;
// How far the clip sits below the card window, as a fraction of the frame height.
const DROP: f32 = 0.102083;

// Signed distance to the rounded square, in output pixels.
fn box_distance(uv: vec2f) -> f32 {
    let size = globals.size;
    let grid = min(size.x, size.y) / 720.0;
    let m = (uv - 0.5) * size / min(size.x, size.y) * 720.0 + vec2f(360.0, 480.0);
    let q = abs(m - BOX_CENTER) - vec2f(BOX_HALF - BOX_RADIUS);
    return (length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - BOX_RADIUS) * grid;
}

// Coarse height map of the card edge for the bevel (a ramp about four pixels wide).
fn bevel_height(uv: vec2f) -> f32 {
    return clamp(0.5 - box_distance(uv) / 4.5, 0.0, 1.0);
}

// Flat card picture (premultiplied): mirrored clip plus the light wash, cut by the rounded
// square, with a thin lit and shaded bevel.
fn card_face(uv: vec2f, t: f32) -> vec4f {
    let size = globals.size;
    let grid = min(size.x, size.y) / 720.0;
    let alpha = clamp(0.5 - box_distance(uv) / grid, 0.0, 1.0);
    let sv = uv.y - DROP;
    if (alpha <= 0.0 || sv < 0.0 || sv > 1.0) { return vec4f(0.0); }
    let src = vec2f(uv.x, sv);
    var col = textureSampleLevel(second, smp, vec2f(1.0 - src.x, src.y), 0.0).rgb;
    let asp = size.x / size.y;
    var lq = src;
    if (asp > 1.0) { lq.y = (lq.y - 0.5) / asp + 0.5; } else { lq.x = (lq.x - 0.5) * asp + 0.5; }
    let wash = clamp((t - 0.466667) / 0.233333, 0.0, 1.0);
    col = min(col + leak(fract(lq)) * wash, vec3f(1.0));

    // Bevel: slope of the height map two pixels either side, lit from the upper left.
    let px = 2.02 / size;
    let dx = (bevel_height(uv + vec2f(px.x, 0.0)) - bevel_height(uv - vec2f(px.x, 0.0))) * 2.477;
    let dy = (bevel_height(uv - vec2f(0.0, px.y)) - bevel_height(uv + vec2f(0.0, px.y))) * 2.477;
    let n = normalize(vec3f(-2.0 * dx, -2.0 * dy, 4.0));
    let yaw = (90.0 - 314.4) * PI / 180.0;
    let shade = dot(n, vec3f(cos(yaw), sin(yaw), 0.0));
    let dark = max(-shade, 0.0) * 0.36 * alpha;
    let lit = max(shade, 0.0) * 0.75 * alpha;
    var pm = col * alpha * (1.0 - dark);
    var a = dark + alpha * (1.0 - dark);
    pm = pm * (1.0 - lit) + vec3f(lit);
    a = lit + a * (1.0 - lit);
    return vec4f(pm, a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = timeline();
    var color = textureSampleLevel(first, smp, uv, 0.0).rgb;
    if (t >= 0.766667) { color = textureSampleLevel(second, smp, uv, 0.0).rgb; }

    let fade = 1.0 - clamp((t - 0.766667) / 0.1, 0.0, 1.0);
    if (fade > 0.0) {
        // Camera that frames the whole picture at the reference depth.
        let ratio = globals.size.x / globals.size.y;
        let eye_z = ratio / tan(39.6 * 0.5 * PI / 180.0);
        let pos = card_position(t);
        let scl = card_scale(t) / 100.0;
        let turn = card_turn(t) * (PI / 180.0);
        let spin = key(t, 0.0, 0.4, 23.0, -6.0, vec4f(0.333333, 0.0, 0.833333, 1.0)) * (PI / 180.0);
        let rot = rot_x(turn.x) * rot_y(-turn.y) * rot_z(-turn.z) * rot_z(-spin);
        let center = vec3f((pos.x / 720.0 - 0.5) * 2.0 * ratio, (0.5 - pos.y / 960.0) * 2.0, -pos.z * 2.0 / 960.0);
        let origin = center + rot * (scl * vec3f(0.0, 0.0, 28.0 * 2.0 / 960.0));
        let ax_u = rot * (scl * vec3f(ratio, 0.0, 0.0));
        let ax_v = rot * (scl * vec3f(0.0, 1.0, 0.0));
        let ray = vec3f((uv.x * 2.0 - 1.0) * ratio, 1.0 - uv.y * 2.0, -eye_z);
        let rhs = origin - vec3f(0.0, 0.0, eye_z);
        // Solve eye + s*ray = origin + a*ax_u + b*ax_v; the card shows from both sides.
        let c1 = -ax_u;
        let c2 = -ax_v;
        let det = dot(ray, cross(c1, c2));
        if (abs(det) > 1e-7) {
            let s = dot(rhs, cross(c1, c2)) / det;
            let a = dot(ray, cross(rhs, c2)) / det;
            let b = dot(ray, cross(c1, rhs)) / det;
            if (s > 0.0 && abs(a) <= 1.0 && abs(b) <= 1.0) {
                let face = card_face(vec2f((a + 1.0) * 0.5, (1.0 - b) * 0.5), t) * fade;
                color = color * (1.0 - face.a) + face.rgb;
            }
        }
    }

    // Exposure push of the burst, applied in linear light.
    var gain = 0.0;
    if (t >= 0.7 && t < 0.766667) { gain = key(t, 0.7, 0.766667, 0.0, 1.6, vec4f(0.333333, 0.0, 0.666667, 1.0)); }
    if (t >= 0.766667 && t < 1.066667) { gain = key(t, 0.766667, 1.066667, 1.6, 0.0, vec4f(0.333333, 0.0, 0.666667, 1.0)); }
    color = clamp(color * exp2(gain / 2.2), vec3f(0.0), vec3f(1.0));
    gpufx_write(id, vec4f(color, 1.0));
}
