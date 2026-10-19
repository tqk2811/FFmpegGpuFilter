// Scene change check between two rgba8unorm frames (frame interpolation): bindings shared by
// scene_sad.wgsl, scene_decide.wgsl and scene_select.wgsl, which are appended to this file.
//
// sad: mean absolute luma difference of a grid of samples (every `step` pixels), summed with atomics.
// The same pass keeps the largest mean difference of one 16x16 tile of samples (`tile`).
// decide: score = min(mafd, |mafd - previous mafd|) in percent of full scale, as FFmpeg's framerate
// filter scores it; `cut` = 1 when threshold > 0 and score >= threshold. A static pair (mafd below
// STATIC_MAFD and no tile above STATIC_TILE: a still scene or a duplicated frame, which the model would
// only soften) gets `cut` = 2.
// select: on a cut or a static pair, the interpolated frame is replaced by the nearer source frame.

// Static pair: mafd in percent of full scale (0.5 % is about 1.3 levels of 255) ...
const STATIC_MAFD: f32 = 0.5;
// ... and the largest mean difference of a 16x16 tile in 1/16 of a level of 255 (48 = 3 levels), so a small
// moving object on a still background is not taken for a still frame.
const STATIC_TILE: u32 = 48u;

struct P {
    w: u32,
    h: u32,
    step: u32,
    count: u32,
    threshold: f32,
    t: f32,
}

struct State {
    sum: atomic<u32>,
    prev: f32,
    cut: u32,
    tile: atomic<u32>,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var frame0: texture_2d<f32>;
@group(0) @binding(2) var frame1: texture_2d<f32>;
@group(0) @binding(3) var<storage, read_write> state: State;
@group(0) @binding(4) var dst: texture_storage_2d<rgba8unorm, write>;
