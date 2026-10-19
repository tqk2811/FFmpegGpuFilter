// Scene change check between two rgba8unorm frames (frame interpolation): bindings shared by
// scene_sad.wgsl, scene_decide.wgsl and scene_select.wgsl, which are appended to this file.
//
// sad: mean absolute luma difference of a grid of samples (every `step` pixels), summed with atomics.
// decide: score = min(mafd, |mafd - previous mafd|) in percent of full scale, as FFmpeg's framerate
// filter scores it; `cut` = score >= threshold.
// select: on a cut, the interpolated frame is replaced by the nearer source frame.

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
    pad: u32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var frame0: texture_2d<f32>;
@group(0) @binding(2) var frame1: texture_2d<f32>;
@group(0) @binding(3) var<storage, read_write> state: State;
@group(0) @binding(4) var dst: texture_storage_2d<rgba8unorm, write>;
