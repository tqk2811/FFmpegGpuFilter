// Rotating Disk, final pass: light box blur on both spun clips, a growing disc reveals the second clip, exposure flash.

const CLOCK_START: f32 = 0.64;
const CLOCK_END: f32 = 1.68;
const DESIGN: f32 = 720.0;
// Disc radius per 25 fps animation frame (frames 16..33), as a fraction of the frame's long side.
// Negative: no disc yet. From frame 34 on the disc covers everything.
var<private> DISC: array<f32, 18> = array<f32, 18>(
    -1.0, -1.0, 0.004, 0.0149, 0.0483, 0.1143, 0.2211, 0.3547, 0.476,
    0.5638, 0.6212, 0.6557, 0.6757, 0.6884, 0.6953, 0.6993, 0.7022, 0.7061);
// Width of the disc's soft edge (fraction of the long side).
const DISC_EDGE: f32 = 0.01;

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

// Box blur reach (design units) of each clip.
fn first_box(t: f32) -> f32 {
    if (t <= 0.72) { return 0.0; }
    if (t >= 1.08) { return 3.0; }
    return segment(t, 0.72, 0.0, 1.08, 0.0, 0.96, 3.0, 1.08, 3.0);
}
fn second_box(t: f32) -> f32 {
    if (t <= 0.72) { return 1.0; }
    if (t >= 1.08) { return 0.0; }
    return segment(t, 0.72, 1.0, 0.7714627, 1.0, 0.72, 0.0, 1.08, 0.0);
}
// Exposure in stops.
fn exposure(t: f32) -> f32 {
    if (t <= 0.72 || t >= 1.4) { return 0.0; }
    if (t < 0.88) { return segment(t, 0.72, 0.0, 0.7733333, 0.0, 0.8266667, 2.0, 0.88, 2.0); }
    return segment(t, 0.88, 2.0, 0.9372619, 2.0, 1.0565670, 0.0, 1.4, 0.0);
}

// 3x3 box of taps `step` pixels apart.
fn box_first(uv: vec2f, step: vec2f) -> vec3f {
    var acc = vec3f(0.0);
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            acc += textureSampleLevel(spun_first, smp, uv + step * vec2f(f32(i), f32(j)), 0.0).rgb;
        }
    }
    return acc / 9.0;
}
fn box_second(uv: vec2f, step: vec2f) -> vec3f {
    var acc = vec3f(0.0);
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            acc += textureSampleLevel(spun_second, smp, uv + step * vec2f(f32(i), f32(j)), 0.0).rgb;
        }
    }
    return acc / 9.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = params.progress;
    // Exact clips at the ends of the transition.
    if (p <= 0.0) { gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0)); return; }
    if (p >= 1.0) { gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0)); return; }

    let size = globals.size;
    let unit = min(size.x, size.y) / DESIGN;
    let clock = mix(CLOCK_START, CLOCK_END, p);
    let px = unit / size;

    let a = box_first(uv, px * first_box(clock));
    let b = box_second(uv, px * second_box(clock));

    // Disc mask, held for each 25 fps animation frame.
    let frame = i32(floor(clock * 25.0)) - 16;
    var cover = 1.0;
    if (frame < 18) {
        let r = DISC[clamp(frame, 0, 17)];
        if (r < 0.0) {
            cover = 0.0;
        } else {
            let d = length((uv - 0.5) * size) / max(size.x, size.y);
            cover = 1.0 - smoothstep(r - 2.0 * DISC_EDGE, r, d);
        }
    }
    let col = mix(a, b, cover) * pow(4.0 / 3.0, exposure(clock));
    gpufx_write(id, vec4f(col, 1.0));
}
