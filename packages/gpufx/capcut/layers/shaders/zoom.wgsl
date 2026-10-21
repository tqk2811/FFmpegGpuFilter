// Layers, background step 2: zoom blur towards the centre.

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
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let t = clock();
    let uv = gpufx_uv(id);
    var amount = 0.0;
    if (t < 21.0 / 30.0) { amount = curve(ROW_ZOOM_AMOUNT, t); }
    let dir = (uv - 0.5) * (amount / 200.0);
    let dist = length(dir);
    let count = 15.0 * 10.0 * (0.9 * dist + 0.1) + 20.0;
    let step = dir / count;
    var sum = textureSampleLevel(moved, smp, uv, 0.0);
    var total = 1.0;
    if (amount > 0.0) {
        for (var i = 1; i <= 170; i++) {
            let k = f32(i);
            if (k > count) { break; }
            let q = uv - step * k;
            if (all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
                sum += textureSampleLevel(moved, smp, q, 0.0);
                total += 1.0;
            }
        }
    }
    gpufx_write(id, sum / total);
}
