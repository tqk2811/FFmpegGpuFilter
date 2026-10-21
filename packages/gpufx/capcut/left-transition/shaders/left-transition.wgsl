// Both clips slide left with a strong motion blur, under a warm light leak and closing-then-opening black letterbox bars.

// Progress 0..1 runs over a 1-second timeline.
// Slide keys: the move runs from MOVE_START for MOVE_LEN; the trailing pose lags one key frame behind.
const MOVE_START: f32 = 0.333333;
const TRAIL_START: f32 = 0.3666663;
const MOVE_LEN: f32 = 0.333334;
// Visibility windows of the two clips.
const FIRST_END: f32 = 0.6666667;
const SECOND_START: f32 = 0.3333333;
// Blur: the samples spread between these fractions of the trail-to-current move.
const SPREAD_FROM: f32 = 0.75;
const SPREAD_TO: f32 = 1.25;
const FEW_TAPS: f32 = 12.0;
const MANY_TAPS: f32 = 24.0;
// Overlay artwork size (light leak and bars are laid out on it, scaled to cover the frame).
const ART: vec2f = vec2f(1280.0, 720.0);
const FRAMES: i32 = 30;

// Average light-leak colour of each overlay frame.
const LEAK_TINT = array<vec3f, 30>(
    vec3f(0.0104, 0.0188, 0.0005), vec3f(0.0105, 0.0187, 0.0004), vec3f(0.0114, 0.0187, 0.0004), vec3f(0.0118, 0.0188, 0.0004),
    vec3f(0.0136, 0.0191, 0.0004), vec3f(0.0143, 0.0190, 0.0004), vec3f(0.0463, 0.0198, 0.0011), vec3f(0.0818, 0.0226, 0.0013),
    vec3f(0.1300, 0.0336, 0.0032), vec3f(0.2332, 0.0814, 0.0186), vec3f(0.4142, 0.1871, 0.0690), vec3f(0.5600, 0.2823, 0.1369),
    vec3f(0.6232, 0.3237, 0.1739), vec3f(0.6090, 0.3148, 0.1719), vec3f(0.4998, 0.2357, 0.1126), vec3f(0.3285, 0.1387, 0.0458),
    vec3f(0.1854, 0.0665, 0.0120), vec3f(0.0990, 0.0453, 0.0039), vec3f(0.0428, 0.0270, 0.0012), vec3f(0.0225, 0.0205, 0.0006),
    vec3f(0.0098, 0.0179, 0.0002), vec3f(0.0059, 0.0169, 0.0002), vec3f(0.0052, 0.0166, 0.0002), vec3f(0.0046, 0.0168, 0.0002),
    vec3f(0.0058, 0.0163, 0.0002), vec3f(0.0073, 0.0168, 0.0002), vec3f(0.0169, 0.0154, 0.0004), vec3f(0.0191, 0.0149, 0.0004),
    vec3f(0.0056, 0.0162, 0.0002), vec3f(0.0038, 0.0158, 0.0002));
// Left-to-right brightness tilt of the leak per frame: the glow drifts from the left edge to the right.
const LEAK_TILT = array<f32, 30>(
    0.113, 0.144, 0.038, -0.023, -0.543, -0.844, -0.488, -0.717, -0.920, -1.050, -0.624, -0.124, 0.095, 0.342, 0.643,
    0.832, 0.777, 0.473, 0.572, 0.637, 0.748, 0.768, 0.604, 0.245, -0.430, -0.646, 0.261, -0.424, 0.492, 0.768);
// Vertical shape of the leak, top to bottom in 9 knots: warm on top, deep red at the bottom.
const LEAK_ROWS = array<vec3f, 9>(
    vec3f(1.077, 1.237, 1.282), vec3f(1.106, 1.245, 1.322), vec3f(1.125, 1.239, 1.338), vec3f(1.120, 1.208, 1.303),
    vec3f(1.091, 1.156, 1.210), vec3f(1.027, 1.045, 1.017), vec3f(0.907, 0.807, 0.699), vec3f(0.761, 0.525, 0.369),
    vec3f(0.641, 0.292, 0.194));
// Height of the top letterbox bar per frame, in art pixels; the bottom bar is one pixel shorter.
const BAR_HEIGHT = array<f32, 30>(
    0.0, 4.6, 32.26, 63.02, 78.45, 87.57, 93.37, 97.1, 99.38, 100.58, 100.94, 96.33, 68.67, 37.92, 22.48,
    13.36, 7.56, 3.84, 1.56, 0.36, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);

fn bezier1(q: f32, b: f32, c: f32) -> f32 {
    let r = 1.0 - q;
    return 3.0 * b * r * r * q + 3.0 * c * r * q * q + q * q * q;
}

// Quick start with a long soft landing: cubic-bezier(0.333, 0, 0, 1), solved for x by bisection.
fn ease(x: f32) -> f32 {
    if (x <= 0.0) { return 0.0; }
    if (x >= 1.0) { return 1.0; }
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier1(mid, 0.333333, 0.0) > x) { hi = mid; } else { lo = mid; }
    }
    return bezier1(0.5 * (lo + hi), 0.0, 1.0);
}

fn hash2(a: f32, b: f32) -> f32 {
    var q = fract(vec2f(a, b) * 13.517);
    q += dot(q, q.yx + 22.541);
    return fract((q.x + q.y) * q.y);
}

fn fetch(uv: vec2f, use_second: bool) -> vec3f {
    if (use_second) { return textureSampleLevel(second, smp, uv, 0.0).rgb; }
    return textureSampleLevel(first, smp, uv, 0.0).rgb;
}

// One clip shifted left by `shift` (between trailing and current shift), blurred along the move.
// Returns premultiplied colour with coverage in alpha; nothing is drawn outside the frame.
fn sliding_clip(uv: vec2f, trail: f32, now: f32, use_second: bool) -> vec4f {
    let s0 = mix(trail, now, SPREAD_FROM);
    let s1 = mix(trail, now, SPREAD_TO);
    let taps = floor(FEW_TAPS + (MANY_TAPS - FEW_TAPS) * smoothstep(0.0, 0.2, abs(s1 - s0)));
    // The jitter uses bottom-up coordinates, like the original renderer.
    let gl = vec2f(uv.x, 1.0 - uv.y);
    var acc = vec4f(0.0);
    for (var i = 0.0; i < MANY_TAPS; i += 1.0) {
        if (i >= taps) { break; }
        let k = i / (taps - 1.0) + (hash2(i + gl.x, i * gl.y) - 0.5) / taps;
        let p = vec2f(uv.x + mix(s0, s1, k), uv.y);
        if (all(p >= vec2f(0.0)) && all(p <= vec2f(1.0))) {
            acc += vec4f(fetch(p, use_second), 1.0);
        }
    }
    return acc / taps;
}

fn leak(a: vec2f, frame: i32) -> vec3f {
    let y = clamp(a.y, 0.0, 1.0) * 8.0;
    let r = min(i32(floor(y)), 7);
    let rows = mix(LEAK_ROWS[r], LEAK_ROWS[r + 1], y - f32(r));
    let tilt = max(1.0 + LEAK_TILT[frame] * (a.x - 0.5), 0.0);
    return LEAK_TINT[frame] * rows * tilt;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress;
    let now = ease((t - MOVE_START) / MOVE_LEN);
    let trail = ease((t - TRAIL_START) / MOVE_LEN);

    var top = vec4f(0.0);
    if (t < FIRST_END) { top = sliding_clip(uv, trail, now, false); }
    var under = vec4f(0.0);
    if (t >= SECOND_START) { under = sliding_clip(uv, trail - 1.0, now - 1.0, true); }
    var c = top.rgb + under.rgb * (1.0 - top.a);

    // Overlay frame shown at this moment, each held for one frame.
    let frame = clamp(i32(floor(t * f32(FRAMES) + 0.5)), 0, FRAMES - 1);
    // Overlay coordinates: the art is scaled to cover the frame.
    let aspect = globals.size.x / globals.size.y;
    let art_aspect = ART.x / ART.y;
    var a = uv;
    if (art_aspect > aspect) {
        a.x = (a.x - 0.5) * (aspect / art_aspect) + 0.5;
    } else {
        a.y = (a.y - 0.5) * (art_aspect / aspect) + 0.5;
    }
    c += leak(a, frame);
    let row = a.y * ART.y;
    let h = BAR_HEIGHT[frame];
    let bar = clamp(h - row, 0.0, 1.0) + clamp(row - (ART.y - max(h - 1.0, 0.0)), 0.0, 1.0);
    c = c * (1.0 - clamp(bar, 0.0, 1.0));
    gpufx_write(id, vec4f(c, 1.0));
}
