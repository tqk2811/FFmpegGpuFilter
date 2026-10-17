// Dissolve of the two clips, stored as a shrunken copy in the top-left corner for the blur pass.

// `progress` 0..1 spans this many seconds of animation time.
const TIMELINE: f32 = 1.99999;
// The dissolve runs between these two times (seconds).
const MIX_START: f32 = 0.933333;
const MIX_END: f32 = 1.1;

// Blur strength (0..400) at animation time `t`: linear keys every 1/30 s.
fn blur_strength(t: f32) -> f32 {
    let times = array<f32, 7>(0.866667, 0.9, 0.933333, 0.966667, 1.0, 1.033333, 1.066667);
    let values = array<f32, 7>(0.0, 100.0, 200.0, 400.0, 200.0, 100.0, 0.0);
    var s = 0.0;
    for (var k = 0; k < 6; k++) {
        if (t >= times[k] && t < times[k + 1]) {
            s = mix(values[k], values[k + 1], (t - times[k]) / (times[k + 1] - times[k]));
        }
    }
    return s;
}

// Shrink factor of the blurred copy for a given strength.
fn shrink_for(strength: f32) -> f32 {
    if (strength <= 10.0) { return 0.8; }
    if (strength <= 50.0) { return 0.7; }
    if (strength <= 200.0) { return 0.5; }
    return 0.25;
}

// The first clip fades towards black while the second fades in on top of it
// (premultiplied colour, coverage in alpha).
fn dissolve(q: vec2f, t: f32) -> vec4f {
    let x = clamp((t - MIX_START) / (MIX_END - MIX_START), 0.0, 1.0);
    let under = 1.0 - x;
    let a = textureSampleLevel(first, smp, q, 0.0).rgb;
    let b = textureSampleLevel(second, smp, q, 0.0).rgb;
    return vec4f(a * under * (1.0 - x) + b * x, x + under * (1.0 - x));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let t = clamp(params.progress, 0.0, 1.0) * TIMELINE;
    let grid = max(floor(globals.size * shrink_for(blur_strength(t))), vec2f(1.0));
    let cell = vec2f(id.xy);
    if (cell.x >= grid.x || cell.y >= grid.y) {
        gpufx_write(id, vec4f(0.0));
        return;
    }
    // One filtered read of the full-size dissolve at the centre of each shrunken texel.
    gpufx_write(id, dissolve((cell + 0.5) / grid, t));
}
