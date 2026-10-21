// Record Scratch: the first clip shoves sideways off frame with a small bounce and zoom
// while the second slides in behind it; 80 samples over a short shutter keep the
// brightest hit per pixel, so the move smears into light trails (mirror-filled edges).

// One cubic Bezier segment of a keyframed track: (x1, y1) and (x4, y4) are the
// keys, (x2, y2) and (x3, y3) the handles, all in (time, value) space.
// The time is solved by bisection, then the value is read off the curve.
fn bez(q: f32, a: f32, b: f32, c: f32, d: f32) -> f32 {
    let p = 1.0 - q;
    return a * p * p * p + 3.0 * b * p * p * q + 3.0 * c * p * q * q + d * q * q * q;
}

fn segment(x: f32, x1: f32, x2: f32, x3: f32, x4: f32, y1: f32, y2: f32, y3: f32, y4: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 17; i++) {
        let mid = (lo + hi) * 0.5;
        if (bez(mid, x1, x2, x3, x4) > x) { hi = mid; } else { lo = mid; }
    }
    return bez((lo + hi) * 0.5, y1, y2, y3, y4);
}

// The animation clock: progress 0..1 maps onto 15/30 .. 32/30 s of the source timeline.
fn clock(t: f32) -> f32 {
    return mix(15.0 / 30.0, 32.0 / 30.0, t);
}

// Vertical bounce, in 1080-px units: 540 -> 500 -> 580 -> 540.
fn bounce(x: f32) -> f32 {
    if (x <= 0.5) { return 540.0; }
    if (x >= 1.0666667) { return 540.0; }
    if (x < 0.6666667) { return segment(x, 0.5, 0.5480784, 0.5672160, 0.6666667, 540.0, 539.82763, 500.02940, 500.09062); }
    if (x < 0.8666667) { return segment(x, 0.6666667, 0.7185127, 0.7833511, 0.8666667, 500.09062, 500.12253, 558.76104, 579.62203); }
    return segment(x, 0.8666667, 0.9239909, 0.9900621, 1.0666667, 579.62203, 593.97519, 540.06669, 540.0);
}

// Zoom of the first clip, percent: 100 -> 104 -> 100.
fn zoom(x: f32) -> f32 {
    if (x <= 0.5 || x >= 1.0666667) { return 100.0; }
    if (x < 0.7333333) { return segment(x, 0.5, 0.7333333, 0.6555556, 0.7333333, 100.0, 99.9044, 104.0, 104.0); }
    return segment(x, 0.7333333, 0.7743254, 0.7616971, 1.0666667, 104.0, 103.98888, 100.0, 100.0);
}

// Sideways travel of the first clip, 0 -> 1075.
fn push_first(x: f32) -> f32 {
    if (x <= 0.5) { return 0.0; }
    if (x >= 0.8333333) { return 1075.0; }
    return min(segment(x, 0.5, 0.8333333, 0.8333, 0.8333333, 0.0, 0.0, 1075.0, 1075.0), 1075.0);
}

// Sideways travel of the second clip, -1082 -> 0.
fn push_second(x: f32) -> f32 {
    if (x <= 0.7333333) { return -1082.0; }
    if (x >= 1.0666667) { return 0.0; }
    return -1082.0 + min(segment(x, 0.7333333, 0.7409576, 0.7333333, 1.0666667, 0.0, 0.0, 1079.7418, 1082.0), 1082.0);
}

// How much the first clip still counts against the second: 1 -> 0.
fn first_weight(x: f32) -> f32 {
    if (x <= 0.7333333) { return 1.0; }
    if (x >= 0.8333333) { return 0.0; }
    return segment(x, 0.7333333, 0.7666667, 0.8, 0.8333333, 100.0, 100.0, 0.0, 0.0) / 100.0;
}

const SAMPLES: u32 = 80u;
// Per shutter sample: first clip offset (x, y), zoom, second clip offset x.
var<workgroup> motion: array<vec4f, 80>;
var<workgroup> weight: array<f32, 80>;

fn mirrored_first(q: vec2f) -> vec4f {
    let m = abs(q - 2.0 * floor(q / 2.0));
    let u = select(m, 2.0 - m, m > vec2f(1.0));
    return textureSampleLevel(dust_first, smp, to_tex(u), 0.0);
}

fn mirrored_second(q: vec2f) -> vec4f {
    let m = abs(q - 2.0 * floor(q / 2.0));
    let u = select(m, 2.0 - m, m > vec2f(1.0));
    return textureSampleLevel(dust_second, smp, to_tex(u), 0.0);
}

const FLIP_Y: bool = true;

// The motion is laid out with y pointing up.
fn to_tex(u: vec2f) -> vec2f {
    return select(u, vec2f(u.x, 1.0 - u.y), FLIP_Y);
}

fn luma(c: vec4f) -> f32 {
    return dot(c.rgb, vec3f(0.299, 0.587, 0.114));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u, @builtin(local_invocation_index) lane: u32) {
    let t = clamp(params.progress, 0.0, 1.0);
    let start = clock(t);
    let shutter = mix(0.5, 3.0, clamp((t - 0.05) / 0.1, 0.0, 1.0)) / 30.0;
    for (var k = lane; k < SAMPLES; k += 64u) {
        let x = mix(start, start + shutter, f32(k) / f32(SAMPLES));
        motion[k] = vec4f(push_first(x), bounce(x), zoom(x) / 100.0, push_second(x));
        weight[k] = first_weight(x);
    }
    workgroupBarrier();
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let frame = globals.size * 1080.0 / min(globals.size.x, globals.size.y);
    let p = to_tex(uv) * frame;
    let centre = frame * 0.5;
    var best = vec4f(0.0);
    var best_luma = 0.0;
    for (var k = 0u; k < SAMPLES; k++) {
        let m = motion[k];
        let lift = vec2f(m.x / 1080.0 * frame.x, frame.y);
        let shift = vec2f(centre.x, (1.0 - m.y / 1080.0) * frame.y);
        let qa = centre - lift + (p - vec2f(0.0, frame.y) - shift) / m.z;
        let lift_b = vec2f(m.w / 1080.0 * frame.x, frame.y);
        let qb = centre - lift_b + (p - vec2f(0.0, frame.y) - shift);
        let w = weight[k];
        let a = mirrored_first(qa / frame) * w;
        let b = mirrored_second(qb / frame) * (1.0 - w);
        let la = luma(a);
        let lb = luma(b);
        let hi = max(la, lb);
        if (hi >= best_luma) {
            best = select(a, b, lb >= la);
        }
        best_luma = max(best_luma, hi);
    }
    gpufx_write(id, vec4f(best.rgb, 1.0));
}
