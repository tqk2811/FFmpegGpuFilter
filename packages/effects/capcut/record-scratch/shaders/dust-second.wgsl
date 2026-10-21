// Record Scratch: add a layer of twinkling dust specks onto the second clip.

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

// Dust on the second clip: fades out over the last 0.2 s of the clock.
fn dust_amount(x: f32) -> f32 {
    if (x <= 0.8666667) { return 1.0; }
    if (x >= 1.0666667) { return 0.0; }
    return segment(x, 0.8666667, 0.9, 1.0333333, 1.0666667, 100.0, 83.333333, 16.666667, 0.0) / 100.0;
}

fn hash12(p: vec2f) -> f32 {
    var q = fract(p * vec2f(0.1031, 0.1030));
    q += dot(q, q.yx + 33.33);
    return fract((q.x + q.y) * q.x);
}

fn hash22(p: vec2f) -> vec2f {
    var q = fract(vec3f(p.xyx) * vec3f(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return fract((q.xx + q.yz) * q.zy);
}

// Faint violet-white dust specks on a 540 x 720 sheet stretched over the frame,
// twinkling from one sheet frame to the next.
const SHEET: vec2f = vec2f(540.0, 720.0);
const CELL: f32 = 14.0;

fn specks(uv: vec2f, frame: f32) -> vec3f {
    let px = uv * SHEET;
    let base = floor(px / CELL);
    var sum = 0.0;
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let cell = base + vec2f(f32(i), f32(j));
            if (hash12(cell + 17.0) > 0.2) { continue; }
            let centre = (cell + 0.15 + 0.7 * hash22(cell)) * CELL;
            let size = mix(0.5, 1.1, hash12(cell + 91.0));
            let level = 0.8 * pow(hash12(cell + 53.0), 2.5);
            let twinkle = 0.6 + 0.4 * sin(frame * 1.3 + 6.2831853 * hash12(cell + 7.0));
            let d = length(px - centre);
            sum += level * twinkle * exp(-d * d / (2.0 * size * size));
        }
    }
    return clamp(sum * vec3f(0.95, 0.9, 1.1), vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    let c = textureSampleLevel(second, smp, uv, 0.0).rgb;
    let frame = ceil(t * 78.00001);
    let dust = specks(uv, frame) * dust_amount(clock(t));
    gpufx_write(id, vec4f(min(c + dust, vec3f(1.0)), 1.0));
}
