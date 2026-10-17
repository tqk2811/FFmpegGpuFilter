// Rotating Disk, second clip: moved and turned, then blurred along circles around the centre.

// The transition maps progress onto this stretch of the animation clock (seconds).
const CLOCK_START: f32 = 0.64;
const CLOCK_END: f32 = 1.68;
// The animation is laid out on a frame whose short side is this many units.
const DESIGN: f32 = 720.0;
// The working canvas is this much larger than the frame; samples outside it stick to its edge.
const CANVAS: f32 = 1.6;
// Arc length (design units) between two samples of the spin blur.
const ARC_STEP: f32 = 2.0625;
const MAX_ARC_TAPS: i32 = 150;

// One segment of an After Effects style curve: keys (x0, y0) and (x3, y3) with handles
// (x1, y1) and (x2, y2); the curve parameter is found by bisection on x.
fn segment(t: f32, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 18; i++) {
        let m = 0.5 * (lo + hi);
        let n = 1.0 - m;
        let x = x0 * n * n * n + 3.0 * x1 * n * n * m + 3.0 * x2 * n * m * m + x3 * m * m * m;
        if (x > t) { hi = m; } else { lo = m; }
    }
    let m = 0.5 * (lo + hi);
    let n = 1.0 - m;
    return y0 * n * n * n + 3.0 * y1 * n * n * m + 3.0 * y2 * n * m * m + y3 * m * m * m;
}

// Mirror-repeat texture coordinates.
fn mirror(p: vec2f) -> vec2f {
    let m = p - 2.0 * floor(p * 0.5);
    return select(m, 2.0 - m, m > vec2f(1.0));
}

// Second clip: arrives turned and shrunk, unwinding to rest while its blur fades.
// Returns (unused, vertical shift in design units, scale, angle in degrees).
fn clip_pose(t: f32, view: vec2f) -> vec4f {
    var grow = 100.0;
    var turn = 0.0;
    if (t <= 0.72) { grow = 90.0; turn = 150.0; } else if (t < 1.08) {
        grow = segment(t, 0.72, 90.0, 0.8795862, 90.0, 0.7663036, 97.3089998, 1.08, 99.4296785);
        turn = segment(t, 0.72, 150.0, 0.9083909, 150.0, 0.8242794, 30.3835831, 1.08, 9.9331018);
    } else if (t < 1.68) {
        grow = segment(t, 1.08, 99.4296785, 1.2396953, 100.5092650, 1.4362756, 100.0000097, 1.68, 100.0);
        turn = segment(t, 1.08, 9.9331018, 1.2229221, -1.4966639, 1.4161784, 0.0437654, 1.68, 0.0);
    }
    return vec4f(0.0, 0.0, grow * 0.01, -turn);
}

// Spin blur angle (degrees) of the second clip.
fn clip_spin_blur(t: f32) -> f32 {
    if (t <= 0.72) { return 40.0; }
    if (t >= 1.08) { return 0.0; }
    return segment(t, 0.72, 40.0, 0.720036, 40.0, 1.079964, 0.0, 1.08, 0.0);
}

// Colour of the moved clip at design point `p` (y up, from the frame centre).
fn moved(p: vec2f, pose: vec4f, view: vec2f) -> vec3f {
    let half = 0.5 * view * CANVAS;
    let q0 = clamp(p, -half, half) - vec2f(0.0, pose.y);
    let a = radians(pose.w);
    let c = cos(a);
    let s = sin(a);
    let q = vec2f(c * q0.x + s * q0.y, -s * q0.x + c * q0.y) / (view * pose.z) + 0.5;
    let t = mirror(q);
    return textureSampleLevel(second, smp, vec2f(t.x, 1.0 - t.y), 0.0).rgb;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = globals.size;
    let unit = min(size.x, size.y) / DESIGN;
    let view = size / unit;
    let clock = mix(CLOCK_START, CLOCK_END, params.progress);
    let pose = clip_pose(clock, view);
    let spin = radians(clip_spin_blur(clock));

    let pix = gpufx_uv(id) * size;
    let p = vec2f(pix.x - 0.5 * size.x, 0.5 * size.y - pix.y) / unit;
    var sum = moved(p, pose, view);
    let radius = length(p);
    let taps = min(i32(ceil(spin * 0.5 * radius / ARC_STEP)), MAX_ARC_TAPS);
    if (taps > 0) {
        let base = atan2(p.y, p.x);
        let da = spin * 0.5 / (f32(taps) + 0.1);
        for (var i = 1; i <= taps; i++) {
            let a = da * f32(i);
            sum += moved(vec2f(cos(base + a), sin(base + a)) * radius, pose, view);
            sum += moved(vec2f(cos(base - a), sin(base - a)) * radius, pose, view);
        }
    }
    gpufx_write(id, vec4f(sum / (1.0 + 2.0 * f32(taps)), 1.0));
}
