// Scene change check between two rgba8unorm frames (frame interpolation), as the official RIFE
// inference_video.py does it: both frames downscaled to 32x32 (bilinear, align_corners=False, no
// antialias), then ssim_matlab (RIFE's model/pytorch_msssim) over the 32x32x3 volume, the colour
// channels being the third axis; a pair is a cut when the SSIM is below the threshold. Two deviations: RIFE
// downscales the frame after zero-padding it to its model multiple (a black band, which differs between
// RIFE versions), here the unpadded frame; and on a cut RIFE repeats frame 0, here the nearer source
// frame is used. Bindings shared by
// scene_down.wgsl, scene_blur.wgsl, scene_ssim.wgsl and scene_select.wgsl, which are appended to this file.
//
// down: the 32x32 RGB of both frames into `small`.
// blur: the five SSIM moments (a, b, a*a, b*b, a*b) blurred along the channels and the rows.
// ssim: blurred along the columns, the SSIM map averaged; `cut` = SSIM < threshold.
// select: on a cut, the interpolated frame is replaced by the nearer source frame.

struct P {
    w: u32,
    h: u32,
    threshold: f32,
    t: f32,
}

struct State {
    cut: u32,
    ssim: f32,
    pad0: u32,
    pad1: u32,
    // small: 2 frames x 3 channels x 32 x 32, then the row-blurred moments: 5 x 3 x 32 x 32.
    data: array<f32>,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var frame0: texture_2d<f32>;
@group(0) @binding(2) var frame1: texture_2d<f32>;
@group(0) @binding(3) var<storage, read_write> state: State;
@group(0) @binding(4) var dst: texture_storage_2d<rgba8unorm, write>;

const SMALL: u32 = 32u;
const PLANE: u32 = 1024u;
const MOMENTS: u32 = 6144u;

// The 11-tap gaussian of sigma 1.5 (RIFE's gaussian(11, 1.5)), normalized.
fn gauss(k: i32) -> f32 {
    var sum = 0.0;
    for (var i = 0; i < 11; i++) {
        let d = f32(i - 5);
        sum += exp(-d * d / 4.5);
    }
    let d = f32(k - 5);
    return exp(-d * d / 4.5) / sum;
}
