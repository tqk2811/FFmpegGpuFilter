// Layers, last pass: rings cut from both clips spin out of a hole that opens in the first clip, then a light burst hands over to the second clip.

const SPAN: f32 = 2.0;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// At the ends the last pass shows the plain clips, so the passes before it have nothing to do.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0; }

// Animation curves, baked into `curves` (one row per value, 120 samples a second over the
// 240 / 120 s timeline, 16 bits split over red and green) and the range of each row.
const CURVE_RANGES = array<vec2f, 42>(
    vec2f(0.0, 0.42),
    vec2f(0.0, 0.985),
    vec2f(0.0, 20.0),
    vec2f(0.0, 50.0),
    vec2f(0.0, 3.3),
    vec2f(0.0, 0.5),
    vec2f(0.33, 1.0),
    vec2f(0.1, 5.000000000000011),
    vec2f(0.01, 6.097739109338931),
    vec2f(180.0, 280.0),
    vec2f(-464.210972644056, 0.60000000000284),
    vec2f(-73.6431589379067, 0.20000000000802),
    vec2f(2.014116038636463, 5.4242455820952795),
    vec2f(74.8413728912158, 129.97718440954),
    vec2f(0.3999999999989, 293.512035449172),
    vec2f(-344.084503527348, 0.40000000000727),
    vec2f(1.880286402033971, 4.44402557600561),
    vec2f(-156.0, -155.0),
    vec2f(0.79999999999538, 505.996165811321),
    vec2f(0.39999999999563, 199.804499438008),
    vec2f(1.90999487932311, 3.59998680172147),
    vec2f(107.648181500873, 151.564537521815),
    vec2f(-812.768112050506, 0.60000000000149),
    vec2f(0.3717441816165785, 47.8424998444659),
    vec2f(1.7077737950290799, 2.86315149804378),
    vec2f(45.0, 46.0),
    vec2f(0.39999999999225, 501.029689378446),
    vec2f(-182.589776829558, 1.08713039e-11),
    vec2f(1.18740322338799, 1.82068910166609),
    vec2f(-134.4438336242, -6.77236765561375),
    vec2f(-335.110005612987, 0.00483479718578),
    vec2f(0.67811674727608, 198.968219240883),
    vec2f(1.0682418831128, 1.43679503574076),
    vec2f(-140.666666666667, -100.666666666667),
    vec2f(-290.404759814774, -2.48974175e-11),
    vec2f(-280.883963388767, 0.40000000029519),
    vec2f(1.0421206745211802, 1.20951485816406),
    vec2f(-120.746192525012, 58.1263516665803),
    vec2f(-0.2000000000053, 283.004231054111),
    vec2f(-0.40000000000828, 253.389532279875),
    vec2f(0.9617768161917521, 1.1676416483894),
    vec2f(-251.319762864034, -164.869992138424)
);

fn curve_code(row: i32, col: i32) -> f32 {
    let c = textureLoad(curves, vec2i(clamp(col, 0, 240), row), 0);
    return (round(c.r * 255.0) * 256.0 + round(c.g * 255.0)) / 65535.0;
}

fn curve(row: i32, t: f32) -> f32 {
    let x = clamp(t, 0.0, 2.0) * 120.0;
    let i = i32(floor(x));
    let v = mix(curve_code(row, i), curve_code(row, i + 1), x - f32(i));
    let r = CURVE_RANGES[row];
    return r.x + v * (r.y - r.x);
}

const ROW_BULGE_HEIGHT: i32 = 0;
const ROW_BULGE_TAPER: i32 = 1;
const ROW_ZOOM_AMOUNT: i32 = 2;
const ROW_SPIN_A: i32 = 3;
const ROW_GLOW_EXPOSURE: i32 = 4;
const ROW_GLOW_STRENGTH: i32 = 5;
const ROW_GROW_B: i32 = 6;
const ROW_RINGS_SCALE: i32 = 7;
const ROW_DISK_SCALE: i32 = 8;
const ROW_DISK_TURN: i32 = 9;
const ROW_RING1_X: i32 = 10;
const ROW_RING1_Y: i32 = 11;
const ROW_RING1_SCALE: i32 = 12;
const ROW_RING1_TURN: i32 = 13;
const ROW_RING2_X: i32 = 14;
const ROW_RING2_Y: i32 = 15;
const ROW_RING2_SCALE: i32 = 16;
const ROW_RING2_TURN: i32 = 17;
const ROW_RING3_X: i32 = 18;
const ROW_RING3_Y: i32 = 19;
const ROW_RING3_SCALE: i32 = 20;
const ROW_RING3_TURN: i32 = 21;
const ROW_RING4_X: i32 = 22;
const ROW_RING4_Y: i32 = 23;
const ROW_RING4_SCALE: i32 = 24;
const ROW_RING4_TURN: i32 = 25;
const ROW_RING5_X: i32 = 26;
const ROW_RING5_Y: i32 = 27;
const ROW_RING5_SCALE: i32 = 28;
const ROW_RING5_TURN: i32 = 29;
const ROW_RING6_X: i32 = 30;
const ROW_RING6_Y: i32 = 31;
const ROW_RING6_SCALE: i32 = 32;
const ROW_RING6_TURN: i32 = 33;
const ROW_RING7_X: i32 = 34;
const ROW_RING7_Y: i32 = 35;
const ROW_RING7_SCALE: i32 = 36;
const ROW_RING7_TURN: i32 = 37;
const ROW_RING8_X: i32 = 38;
const ROW_RING8_Y: i32 = 39;
const ROW_RING8_SCALE: i32 = 40;
const ROW_RING8_TURN: i32 = 41;
// Layout space: the frame scaled so its long side is 1080 units, y pointing up.
fn frame_size() -> vec2f { return globals.size * (1080.0 / max(globals.size.x, globals.size.y)); }

fn to_layout(uv: vec2f) -> vec2f { return vec2f(uv.x, 1.0 - uv.y) * frame_size(); }

// A y-up texture coordinate as a uv of our (y-down) textures.
fn tex_uv(g: vec2f) -> vec2f { return vec2f(g.x, 1.0 - g.y); }

const SPIN: f32 = 1.0;

fn turn(v: vec2f, deg: f32) -> vec2f {
    let a = radians(deg) * SPIN;
    let c = cos(a);
    let s = sin(a);
    return vec2f(c * v.x - s * v.y, s * v.x + c * v.y);
}

fn mirror(u: vec2f) -> vec2f {
    let t = u - 2.0 * floor(u * 0.5);
    return select(t, 2.0 - t, t >= vec2f(1.0));
}

struct Ring {
    corner: vec2f,      // which corner of the ring's square the clip is pinned to
    zoom: f32,          // clip size on the ring, in short sides of the square
    shade_at: vec2f,    // centre of the soft shadow over the ring (layout units)
    shade_size: f32,
    shade_turn: f32,
    until: f32,         // the ring is shown before this time (s)
};

const RINGS = array<Ring, 8>(
    Ring(vec2f(0.0, 0.0), 1.5, vec2f(544.4, 499.70000000000005), 0.634, 105.6, 1.1),
    Ring(vec2f(1.0, 1.0), 2.0, vec2f(525.2, 543.9), 0.61, 271.7, 1.2),
    Ring(vec2f(1.0, 0.0), 1.5, vec2f(528.7, 530.3), 0.658, 222.7, 1.3),
    Ring(vec2f(0.0, 1.0), 2.0, vec2f(488.7, 504.79999999999995), 0.746, 42.7, 1.3),
    Ring(vec2f(0.0, 0.0), 1.5, vec2f(502.4, 530.1), 0.77, 90.6, 1.5666666666666667),
    Ring(vec2f(1.0, 1.0), 2.0, vec2f(576.9, 578.0), 0.702, 265.4, 1.6333333333333333),
    Ring(vec2f(1.0, 0.0), 1.5, vec2f(511.4, 499.4), 0.7, 349.1, 1.6666666666666667),
    Ring(vec2f(0.0, 1.0), 2.0, vec2f(503.9, 501.29999999999995), 0.701, 158.4, 1.6666666666666667)
);

// Radial profiles of the ring pictures (r = distance from the centre over the half size).
fn ring_body(r: f32) -> f32 { return smoothstep(0.272, 0.276, r) * clamp((0.9446 - r) / 0.2469, 0.0, 1.0); }
fn disk_body(r: f32) -> f32 { return smoothstep(0.272, 0.276, r) * clamp((0.645 - r) / 0.268, 0.0, 1.0); }
fn rim(r: f32) -> f32 { return 0.387 * smoothstep(0.727, 0.739, r) * exp(-pow(max(r - 0.74, 0.0) / 0.0424, 1.47)); }
fn shade(r: f32) -> f32 { let d = (r - 0.625) / 0.14; return 0.84 * exp(-0.5 * d * d); }
fn porthole(r: f32) -> f32 { return 1.0 - smoothstep(0.816, 0.820, r); }

fn over(dst: vec4f, src: vec4f) -> vec4f { return src + dst * (1.0 - src.a); }

fn read_clip(which: i32, g: vec2f) -> vec4f {
    if (which == 0) { return textureSampleLevel(crisp_a, smp, tex_uv(g), 0.0); }
    return textureSampleLevel(crisp_b, smp, tex_uv(g), 0.0);
}

// Shine: a burst of rays from the centre that brightens and fades (mean brightness per region
// over time, on a square covering the frame).
const SHINE = array<vec3f, 32>(
    vec3f(0.04, 0.003, 0.001),
    vec3f(0.056, 0.005, 0.002),
    vec3f(0.151, 0.024, 0.011),
    vec3f(0.247, 0.051, 0.023),
    vec3f(0.306, 0.067, 0.03),
    vec3f(0.41, 0.097, 0.041),
    vec3f(0.497, 0.128, 0.052),
    vec3f(0.656, 0.186, 0.073),
    vec3f(0.582, 0.222, 0.081),
    vec3f(0.443, 0.252, 0.091),
    vec3f(0.388, 0.272, 0.101),
    vec3f(0.31, 0.32, 0.132),
    vec3f(0.267, 0.368, 0.174),
    vec3f(0.257, 0.433, 0.233),
    vec3f(0.254, 0.462, 0.267),
    vec3f(0.245, 0.499, 0.336),
    vec3f(0.235, 0.507, 0.413),
    vec3f(0.229, 0.497, 0.45),
    vec3f(0.213, 0.464, 0.51),
    vec3f(0.193, 0.418, 0.532),
    vec3f(0.18, 0.387, 0.518),
    vec3f(0.158, 0.34, 0.485),
    vec3f(0.132, 0.287, 0.421),
    vec3f(0.111, 0.243, 0.358),
    vec3f(0.086, 0.193, 0.284),
    vec3f(0.065, 0.148, 0.218),
    vec3f(0.046, 0.107, 0.158),
    vec3f(0.031, 0.074, 0.11),
    vec3f(0.018, 0.045, 0.068),
    vec3f(0.007, 0.021, 0.033),
    vec3f(0.001, 0.007, 0.012),
    vec3f(0.0, 0.0, 0.0)
);

fn hash11(x: f32) -> f32 { return fract(sin(x * 127.1) * 43758.5453); }

fn ray_noise(a: f32, cells: f32) -> f32 {
    let x = a * cells;
    let i = floor(x);
    let u = x - i;
    let s = u * u * (3.0 - 2.0 * u);
    return mix(hash11((i % cells) + cells), hash11(((i + 1.0) % cells) + cells), s);
}

fn shine(uv: vec2f, t: f32) -> f32 {
    let st = t - 27.0 / 30.0;
    if (st < 0.0 || st >= 62.0 / 60.0) { return 0.0; }
    let x = st * 30.0;
    let i = min(i32(floor(x)), 30);
    let lvl = mix(SHINE[i], SHINE[i + 1], x - f32(i));
    let aspect = globals.size.x / globals.size.y;
    var v = uv - 0.5;
    if (aspect > 1.0) { v.y /= aspect; } else { v.x *= aspect; }
    let r = length(v) * 2.0;
    let a = atan2(v.y, v.x) / 6.2831853 + 0.5;
    let rays = 0.55 * ray_noise(a, 23.0) + 0.3 * ray_noise(a, 61.0) + 0.15 * ray_noise(a, 137.0);
    var base: f32;
    if (r < 0.3) { base = lvl.x; }
    else if (r < 0.7) { base = mix(lvl.x, lvl.y, smoothstep(0.3, 0.5, r)); }
    else { base = mix(lvl.y, lvl.z, smoothstep(0.5, 0.85, r)); }
    return clamp(base * (0.25 + 1.5 * rays), 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clock();
    var col = vec4f(textureSampleLevel(back, smp, uv, 0.0).rgb, 1.0);
    if (t < 51.0 / 30.0) {
        let p = to_layout(uv);
        let fs = frame_size();
        let k = max(globals.size.x, globals.size.y) / min(globals.size.x, globals.size.y);
        let centre = fs * 0.5;
        // The opening disk: its own size and turn also cut every ring to a porthole.
        let dq = turn((p - centre) / curve(ROW_DISK_SCALE, t), curve(ROW_DISK_TURN, t)) + 540.0;
        let hole = porthole(length(dq - 540.0) / 240.0);
        let spread = curve(ROW_RINGS_SCALE, t);
        for (var n = 8; n >= 1; n--) {
            let ring = RINGS[n - 1];
            if (t >= ring.until || hole <= 0.0) { continue; }
            let row = ROW_RING1_X + (n - 1) * 4;
            let at = vec2f(curve(row, t), curve(row + 1, t));
            let q = turn(((p - centre) / spread - at) / curve(row + 2, t), curve(row + 3, t)) + 540.0;
            let pin = ring.corner * 1080.0;
            let g = ((q - pin) / (k * ring.zoom) + ring.corner * fs) / fs;
            var which = 1;
            if (n == 1 || n == 2 || n == 5 || n == 6) { which = 0; }
            var c = read_clip(which, g) * ring_body(length(q - 540.0) / 543.0);
            let glow = rim(length(q - 540.0) / 204.0);
            c = over(c, vec4f(vec3f(glow), glow));
            let sq = turn((q - ring.shade_at) / ring.shade_size, ring.shade_turn);
            c *= 1.0 - shade(length(sq) / 736.0);
            col = over(col, c * hole);
        }
        if (t < 28.0 / 30.0) {
            let g = ((dq - vec2f(540.0, 120.0)) / (1.5 * k) + vec2f(0.5 * fs.x, 0.0)) / fs;
            var c = read_clip(0, g) * disk_body(length(dq - 540.0) / (1.086 * 500.0));
            let glow = rim(length(dq - 540.0) / 204.0);
            c = over(c, vec4f(vec3f(glow), glow));
            col = over(col, c);
        }
    }
    let s = shine(uv, t);
    gpufx_write(id, vec4f(1.0 - (1.0 - col.rgb) * (1.0 - s), 1.0));
}
