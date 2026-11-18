// The crop of a tracker: a square of `span` frame pixels from (x0, y0) (the frame coordinates of the crop's
// first pixel centre), resized to `size` x `size` with bilinear taps (half-pixel centres, as cv::resize), as a
// 3 x size x size tensor of values in [0, 255] at `out_off` of dst. Taps outside the frame read the pad colour
// (the frame's mean). The frame is RGBA8 packed one pixel per u32, rows of `fw` pixels.

struct P {
    fw: u32,
    fh: u32,
    size: u32,
    out_off: u32,
    x0: f32,
    y0: f32,
    span: f32,
    bgr: u32,
    pad_r: f32,
    pad_g: f32,
    pad_b: f32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> frame: array<u32>;
@group(0) @binding(2) var<storage, read_write> dst: array<f32>;

fn texel(x: i32, y: i32) -> vec3f {
    if (x < 0 || y < 0 || x >= i32(p.fw) || y >= i32(p.fh)) {
        return vec3f(p.pad_r, p.pad_g, p.pad_b);
    }
    let v = frame[u32(y) * p.fw + u32(x)];
    return vec3f(f32(v & 0xffu), f32((v >> 8u) & 0xffu), f32((v >> 16u) & 0xffu));
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= p.size || id.y >= p.size) {
        return;
    }
    let scale = p.span / f32(p.size);
    let sx = p.x0 + (f32(id.x) + 0.5) * scale - 0.5;
    let sy = p.y0 + (f32(id.y) + 0.5) * scale - 0.5;
    let fx = floor(sx);
    let fy = floor(sy);
    let ax = sx - fx;
    let ay = sy - fy;
    let ix = i32(fx);
    let iy = i32(fy);
    let top = mix(texel(ix, iy), texel(ix + 1, iy), ax);
    let bottom = mix(texel(ix, iy + 1), texel(ix + 1, iy + 1), ax);
    var c = mix(top, bottom, ay);
    if (p.bgr != 0u) {
        c = c.zyx;
    }
    let plane = p.size * p.size;
    let i = p.out_off + id.y * p.size + id.x;
    dst[i] = c.x;
    dst[i + plane] = c.y;
    dst[i + 2u * plane] = c.z;
}
