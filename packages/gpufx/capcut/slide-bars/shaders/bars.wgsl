// Slide Bars, pass 1: four horizontal strips of the second clip slide in from alternating sides, with motion blur.
//
// `progress` 0..1 is the scene time in seconds. Each strip is a quarter of the frame
// height; its offset eases in with a sharp ease-out curve, and the blur trail spans the
// last quarter (or, for the bottom strip, half) of one 30 fps frame of motion.

const FRAME: f32 = 0.0333333;
const BLUR_MIN: f32 = 12.0;
const BLUR_MAX: f32 = 24.0;

fn cubic(p1: f32, p2: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * p1 * r * r * s + 3.0 * p2 * r * s * s + s * s * s;
}

// y(x) of the bezier (0,0)-(k.x,k.y)-(k.z,k.w)-(1,1), x solved by bisection.
fn ease(k: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 16; n++) {
        let mid = (lo + hi) * 0.5;
        if (cubic(k.x, k.z, mid) > x) { hi = mid; } else { lo = mid; }
    }
    return cubic(k.y, k.w, (lo + hi) * 0.5);
}

// Horizontal offset (in frame widths) of a strip that starts `start` widths away and
// settles at 0 between t0 and t1.
fn strip_offset(t: f32, t0: f32, t1: f32, start: f32) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return start * (1.0 - ease(vec4f(0.333333, 0.0, 0.0, 1.0), x));
}

fn dither_hash(a: f32, b: f32) -> f32 {
    var f = fract(vec2f(a, b) * 13.517);
    f += dot(f, f.yx + 22.541);
    return fract((f.x + f.y) * f.y);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    let base = textureSampleLevel(first, smp, uv, 0.0);

    // Pick the strip under this pixel: timing, starting side and blur spread.
    let row = min(i32(floor(uv.y * 4.0)), 3);
    var t0 = 0.0;
    var start = -1.0;
    var spread = 0.25;
    if (row == 1) { t0 = 0.2; start = 1.0; }
    if (row == 2) { t0 = 0.4; }
    if (row == 3) { t0 = 0.433333; start = 1.0; spread = 0.5; }
    let t1 = t0 + 0.2;

    // Offset now and one frame earlier; the trail runs from 75% to 75% + spread of that step.
    let now = strip_offset(t, t0, t1, start);
    let before = strip_offset(t - FRAME, t0, t1, start);
    let w0 = 0.75;
    let w1 = 0.75 + spread;
    let off0 = mix(before, now, w0);
    let off1 = mix(before, now, w1);

    let taps = floor(BLUR_MIN + (BLUR_MAX - BLUR_MIN) * smoothstep(0.0, 0.2, abs(off1 - off0)));
    var acc = vec4f(0.0);
    let gl_y = 1.0 - uv.y;
    for (var i = 0; i < 24; i++) {
        let fi = f32(i);
        if (fi >= taps) { break; }
        let s = fi / (taps - 1.0) + (dither_hash(fi + uv.x, fi * gl_y) - 0.5) / taps;
        let q = vec2f(uv.x - mix(off0, off1, s), uv.y);
        if (q.x >= 0.0 && q.x <= 1.0) {
            acc += vec4f(textureSampleLevel(second, smp, q, 0.0).rgb, 1.0);
        }
    }
    acc /= taps;
    gpufx_write(id, vec4f(acc.rgb + base.rgb * (1.0 - acc.a), 1.0));
}
