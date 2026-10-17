// RGB dot-screen version of the current clip (hard cut from the first to the second at the middle).

// `progress` 0..1 spans this many seconds of animation time (just short of 2, so the
// midpoint still lands before the cut).
const TIMELINE: f32 = 1.99999;
// The cut from the first clip to the second happens at this time (seconds).
const CUT_TIME: f32 = 1.0;
// Dot cells per frame height.
const CELLS: f32 = 99.0;
// Added to the brightness before the dot-radius test (makes dark areas still show small dots).
const LIFT: f32 = 0.1;
// Vertical shift of the red and blue dot centres inside a cell (blue goes the other way).
const CHANNEL_SHIFT: f32 = 0.03125;

// The clip shown at time `t`.
fn clip_at(q: vec2f, t: f32) -> vec3f {
    if (t < CUT_TIME) { return textureSampleLevel(first, smp, q, 0.0).rgb; }
    return textureSampleLevel(second, smp, q, 0.0).rgb;
}

// The dots read a half-size copy of the clip. Rebuild that copy on the fly: each copy
// texel is one filtered read of the full image at its centre; the copy is read bilinearly.
fn half_copy(q: vec2f, t: f32) -> vec3f {
    let grid = max(floor(globals.size * 0.5), vec2f(1.0));
    let pos = q * grid - 0.5;
    let base = floor(pos);
    let f = pos - base;
    let last = grid - 1.0;
    let i0 = clamp(base, vec2f(0.0), last);
    let i1 = clamp(base + 1.0, vec2f(0.0), last);
    let c00 = clip_at((vec2f(i0.x, i0.y) + 0.5) / grid, t);
    let c10 = clip_at((vec2f(i1.x, i0.y) + 0.5) / grid, t);
    let c01 = clip_at((vec2f(i0.x, i1.y) + 0.5) / grid, t);
    let c11 = clip_at((vec2f(i1.x, i1.y) + 0.5) / grid, t);
    return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

// 1 when a channel of brightness `v` lights its dot at cell position `cell` (0..1).
fn dot_on(cell: vec2f, v: f32) -> f32 {
    return select(0.0, 1.0, v - length(cell - 0.5) + LIFT > 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * TIMELINE;
    let c = half_copy(uv, t);
    // Cell grid measured with y pointing up, square cells sized by the frame height.
    let p = vec2f((uv.x - 0.5) * globals.size.x / globals.size.y, 0.5 - uv.y) + 1.0;
    let cell = fract(p * CELLS);
    let dots = vec3f(
        dot_on(cell + vec2f(0.0, CHANNEL_SHIFT), c.r),
        dot_on(cell, c.g),
        dot_on(cell - vec2f(0.0, CHANNEL_SHIFT), c.b));
    gpufx_write(id, vec4f(dots, 1.0));
}
