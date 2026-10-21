// Zig-zag brush strokes paint the second clip over the first, then the rest of it fades in.

// Animation clock length (seconds) that `progress` sweeps.
const SPAN: f32 = 2.0;
// The stroke advances on a 30 fps grid; each frame holds its shape.
const STEP_RATE: f32 = 30.0;
// Square reference canvas the stroke path is laid out on (stretched to the frame).
const CANVAS: f32 = 360.0;
// Brush radius on the reference canvas (px).
const BRUSH: f32 = 13.0;
// Number of path points.
const POINTS: i32 = 54;
// Final fade of the whole second clip (seconds on the animation clock).
const FADE_START: f32 = 1.833333;
const FADE_END: f32 = 1.966667;

// Brush path on the reference canvas: the stroke reaches point k+1 on step k+2.
const PATH = array<vec2f, 54>(
        vec2f(-2.0, 206.0), vec2f(1.0, 161.0), vec2f(31.0, 44.0), vec2f(49.0, -10.0),
        vec2f(22.0, 174.0), vec2f(4.0, 294.0), vec2f(-5.0, 357.0), vec2f(29.0, 263.0),
        vec2f(54.0, 144.0), vec2f(84.0, 27.0), vec2f(94.0, -3.0), vec2f(65.0, 192.0),
        vec2f(44.0, 311.0), vec2f(35.0, 374.0), vec2f(69.0, 251.0), vec2f(98.0, 132.0),
        vec2f(132.0, 16.0), vec2f(133.0, 81.0), vec2f(105.0, 199.0), vec2f(81.0, 317.0),
        vec2f(87.0, 355.0), vec2f(129.0, 196.0), vec2f(154.0, 78.0), vec2f(185.0, -10.0),
        vec2f(164.0, 154.0), vec2f(134.0, 272.0), vec2f(119.0, 359.0), vec2f(166.0, 248.0),
        vec2f(191.0, 130.0), vec2f(224.0, 13.0), vec2f(220.0, 92.0), vec2f(191.0, 211.0),
        vec2f(167.0, 330.0), vec2f(142.0, -5.0), vec2f(202.0, 294.0), vec2f(246.0, 69.0),
        vec2f(279.0, -8.0), vec2f(256.0, 140.0), vec2f(171.0, 368.0), vec2f(242.0, 240.0),
        vec2f(219.0, 366.0), vec2f(277.0, 153.0), vec2f(310.0, 37.0), vec2f(323.0, -2.0),
        vec2f(287.0, 177.0), vec2f(261.0, 296.0), vec2f(251.0, 356.0), vec2f(293.0, 248.0),
        vec2f(320.0, 126.0), vec2f(355.0, 10.0), vec2f(354.0, 87.0), vec2f(326.0, 205.0),
        vec2f(321.0, 271.0), vec2f(367.0, 235.0));

fn path_point(k: i32) -> vec2f {
    return PATH[k];
}

// Distance from p to the segment a-b.
fn segment_distance(p: vec2f, a: vec2f, b: vec2f) -> f32 {
    let ab = b - a;
    let h = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    return length(p - a - ab * h);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let step = clamp(i32(floor(t * STEP_RATE + 0.5)), 0, 59);
    let segments = clamp(step - 1, 0, POINTS - 1);

    let p = uv * CANVAS;
    // Canvas px per output px, for a one-pixel soft edge at any size.
    let px = max(CANVAS / globals.size.x, CANVAS / globals.size.y);
    var dist = 1e9;
    for (var k = 0; k < segments; k++) {
        dist = min(dist, segment_distance(p, path_point(k), path_point(k + 1)));
    }
    let painted = clamp((BRUSH - dist) / px + 0.5, 0.0, 1.0);
    let fade = clamp((t - FADE_START) / (FADE_END - FADE_START), 0.0, 1.0);
    let cover = mix(painted, 1.0, fade);

    let back = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let front = textureSampleLevel(second, smp, uv, 0.0).rgb;
    gpufx_write(id, vec4f(mix(back, front, cover), 1.0));
}
