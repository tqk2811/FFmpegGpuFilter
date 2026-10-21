// A white flash, then the first clip rips along a ragged seam and slides away in stop-motion jumps over the second clip.

// The animation clock runs from frame 17 to frame 40 of a 30 fps timeline.
const CLOCK_START: f32 = 17.0;
const CLOCK_END: f32 = 40.0;
// Frame at which each torn pose starts (pose 0 = untouched first clip).
const POSE_FRAMES = array<f32, 5>(20.0, 27.0, 30.0, 35.0, 37.0);
// Seam position across the frame for poses 1..5, sampled at 9 evenly spaced rows (fraction of the width).
const SEAM_ROWS = array<f32, 45>(
    0.1078, 0.0977, 0.0867, 0.0914, 0.0945, 0.0984, 0.0969, 0.0898, 0.0898,
    0.4492, 0.4352, 0.4242, 0.4094, 0.3914, 0.3711, 0.3547, 0.3477, 0.3406,
    0.5586, 0.5617, 0.5695, 0.5859, 0.5969, 0.6102, 0.6211, 0.6180, 0.6180,
    0.7633, 0.7695, 0.7813, 0.7758, 0.7727, 0.7688, 0.7602, 0.7625, 0.7648,
    0.9617, 0.9594, 0.9586, 0.9672, 0.9695, 0.9758, 0.9813, 0.9672, 0.9578
);
// Centre of the first / second clip along the tear axis for poses 1..5 (fraction of the width).
const FIRST_CENTRE = array<f32, 5>(0.5906, 0.8469, 1.0344, 1.2508, 1.4547);
const SECOND_CENTRE = array<f32, 5>(-0.4039, -0.0391, 0.1250, 0.2773, 0.4852);
// Colour of the torn paper fibres along the seam.
const FIBRE_COLOUR: vec3f = vec3f(0.82, 0.81, 0.795);

fn hash11(n: f32) -> f32 {
    return fract(sin(n * 127.1) * 43758.5453);
}

// Smooth 1D value noise in [0, 1].
fn ridge_noise(x: f32, seed: f32) -> f32 {
    let i = floor(x);
    let f = x - i;
    let w = f * f * (3.0 - 2.0 * f);
    return mix(hash11(i + seed * 17.31), hash11(i + 1.0 + seed * 17.31), w);
}

// Which torn pose is shown at the given animation frame.
fn pose_at(frame: f32) -> i32 {
    var starts = POSE_FRAMES;
    var pose = 0;
    for (var k = 0; k < 5; k++) {
        if (frame >= starts[k]) { pose = k + 1; }
    }
    return pose;
}

// Seam position (fraction of the width) at row `row` (0 = top) for pose 1..5.
fn seam_at(pose: i32, row: f32) -> f32 {
    var rows = SEAM_ROWS;
    let s = clamp(row, 0.0, 1.0) * 8.0;
    let k = min(i32(floor(s)), 7);
    let f = s - f32(k);
    let base = (pose - 1) * 9;
    let coarse = mix(rows[base + k], rows[base + k + 1], f * f * (3.0 - 2.0 * f));
    // Ragged paper edge: a few octaves of noise, a few pixels of a 720-line frame.
    let seed = f32(pose);
    var jag = (ridge_noise(row * 30.0, seed) - 0.5) * 0.008;
    jag += (ridge_noise(row * 95.0, seed + 3.0) - 0.5) * 0.005;
    jag += (ridge_noise(row * 260.0, seed + 7.0) - 0.5) * 0.0025;
    return coarse + jag;
}

// Clip sampled with black outside its frame.
fn clip_or_black(which: i32, p: vec2f) -> vec3f {
    if (any(p < vec2f(0.0)) || any(p > vec2f(1.0))) { return vec3f(0.0); }
    if (which == 0) { return textureSampleLevel(first, smp, p, 0.0).rgb; }
    return textureSampleLevel(second, smp, p, 0.0).rgb;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }

    let frame = mix(CLOCK_START, CLOCK_END, clamp(params.progress, 0.0, 1.0)) + 0.003;
    let pose = pose_at(frame);

    // Tear layout lives in a landscape frame; portrait outputs turn it a quarter turn so the
    // seam runs across the short side and the pieces travel downwards.
    let portrait = globals.size.x < globals.size.y;
    var along = uv.x;
    var across = uv.y;
    var span = globals.size.x;
    if (portrait) { along = uv.y; across = 1.0 - uv.x; span = globals.size.y; }

    var colour: vec3f;
    if (pose == 0) {
        colour = textureSampleLevel(first, smp, uv, 0.0).rgb;
    } else {
        var firsts = FIRST_CENTRE;
        var seconds = SECOND_CENTRE;
        let seam = seam_at(pose, across);
        var shift: f32;
        var which: i32;
        if (along >= seam) { which = 0; shift = firsts[pose - 1] - 0.5; } else { which = 1; shift = seconds[pose - 1] - 0.5; }
        var p = uv;
        if (portrait) { p.y -= shift; } else { p.x -= shift; }
        colour = clip_or_black(which, p);

        // Torn fibres: a light ragged band straddling the seam, wider on the trailing side.
        let px = 1280.0 / span;
        let d = (along - seam) * 1280.0;
        let seed = f32(pose) + 11.0;
        let reach_back = 3.0 + 14.0 * ridge_noise(across * 40.0, seed);
        let reach_front = 1.0 + 6.0 * ridge_noise(across * 55.0, seed + 5.0);
        let reach = select(reach_front, reach_back, d < 0.0);
        let edge = 1.0 - smoothstep(reach - px, reach + px, abs(d));
        let fibres = 0.35 + 0.65 * ridge_noise(across * 900.0 + d * 0.15, seed + 9.0);
        colour = mix(colour, FIBRE_COLOUR, edge * fibres);
    }

    // Additive white flash around frame 19 (linear 0 -> 0.6 -> 0).
    let flash = 0.6 * max(1.0 - abs(frame - 19.0) / 2.0, 0.0);
    colour = min(colour + vec3f(flash), vec3f(1.0));
    gpufx_write(id, vec4f(colour, 1.0));
}
