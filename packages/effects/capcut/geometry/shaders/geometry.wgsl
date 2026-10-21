// Flat shapes covering the first clip slide, shrink and break apart to reveal the second, under a chalk trigonometry sketch that draws itself on.

// The shape artwork is laid out on a 360-unit square stretched over the frame.
const GRID: f32 = 360.0;
// Shape and chalk animations step at this frame rate.
const ART_FPS: f32 = 30.0;
// The first clip stops being drawn at this progress.
const FIRST_END: f32 = 0.9;

// Linear ramp of `a` to `b` over the time span [t0, t1].
fn ramp(t: f32, t0: f32, t1: f32, a: f32, b: f32) -> f32 {
    return mix(a, b, clamp((t - t0) / (t1 - t0), 0.0, 1.0));
}

// The three white blocks that hold the first clip at the start and pull away mid-way.
fn blocks(uv: vec2f, t: f32) -> bool {
    // Full-frame block sliding off to the left.
    let cx = ramp(t, 0.4, 0.56667, 78.0, -373.0) / 720.0;
    if (abs(uv.x - cx) <= 0.5) { return true; }
    // Top-right block squashing vertically into its centre line.
    let hy = 0.23889 * ramp(t, 0.4, 0.56667, 1.0, 0.0);
    if (abs(uv.x - 0.86528) <= 0.26667 && abs(uv.y - 0.225) <= hy) { return true; }
    // Lower-right block narrowing toward the right edge.
    let w = 0.53333 * ramp(t, 0.4, 0.56667, 1.0, 0.234375);
    if (uv.x <= 1.13056 && uv.x >= 1.13056 - w && abs(uv.y - 0.75556) <= 0.3) { return true; }
    return false;
}

// Disc, corner wedge and side wedge (grid units, y down) for animation frame f.
fn shapes(p: vec2f, f: i32) -> bool {
    // Disc that turns into a four-blade pinwheel whose blades close up.
    let d = p - vec2f(112.0, 188.0);
    if (f <= 23 && dot(d, d) <= 104.0 * 104.0) {
        if (f <= 15) { return true; }
        let ang = degrees(atan2(-d.y, d.x)) + 360.0;
        let blade = 10.2 * (23.94 - f32(f));
        if (ang - 90.0 * floor(ang / 90.0) < blade) { return true; }
    }
    // Top-right corner wedge; its upper tip is cut away first, then the rest.
    if (f <= 26 && p.x > 258.0 + p.y) {
        if (p.y >= 49.0) { return true; }
        if (f <= 23) { return true; }
        if (f == 24 && p.x > 297.0 + 0.19 * p.y) { return true; }
        if (f == 25 && p.x > 356.0 - p.y) { return true; }
    }
    // Wedge on the right side that slides out to the lower-right.
    if (f <= 21) {
        if (p.x >= min(395.0 - 0.25 * p.y, 521.0 - 0.75 * p.y)) { return true; }
    } else if (f <= 24) {
        if (p.x >= 521.0 - 0.75 * p.y + 30.0 * f32(f - 21)) { return true; }
    }
    return false;
}

// Chalk ink at uv for frame f: red holds coverage, green the first frame a stroke shows,
// blue the frame it is rubbed out (both stored as frame * 8).
fn chalk_ink(uv: vec2f, f: i32) -> f32 {
    let size = vec2i(textureDimensions(chalk));
    let texel = clamp(vec2i(uv * vec2f(size)), vec2i(0), size - 1);
    let timing = textureLoad(chalk, texel, 0).gb * 255.0 / 8.0;
    if (f32(f) + 0.5 < timing.x || f32(f) + 0.5 >= timing.y) { return 0.0; }
    return textureSampleLevel(chalk, smp, uv, 0.0).r;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress;
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // Frame of the shape / chalk animation, sampled half a frame late.
    let f = min(i32(floor(t * ART_FPS + 0.5)), 29);
    // Shape layer and chalk both fade out together near the end.
    let fade = ramp(t, 0.76667, 0.83333, 1.0, 0.0);

    var col = b;
    if (t < FIRST_END) {
        if (blocks(uv, t)) { col = a; }
        if (shapes(uv * GRID, f)) { col = mix(col, a, fade); }
    }
    col = mix(col, vec3f(1.0), chalk_ink(uv, f) * fade);
    gpufx_write(id, vec4f(col, 1.0));
}
