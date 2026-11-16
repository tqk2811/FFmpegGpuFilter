// A frame (RGBA texture, `fw x fh`) resized to the model input (`mw x mh`, 3 channel planes at `out_off`):
// bilinear with half-pixel centres, `src = (dst + 0.5) * fw / mw - 0.5` clamped to the frame (no antialias, as
// gpufx-nnconv `frames::matte_input`), then `(v - mean) / std` per channel.

struct P {
    fw: u32,
    fh: u32,
    mw: u32,
    mh: u32,
    out_off: u32,
    _pad0: u32,
    _pad1: u32,
    _pad2: u32,
    mean: vec4f,
    inv_std: vec4f,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var<storage, read_write> dst: array<f32>;

fn axis(d: u32, i: u32, o: u32) -> vec3f {
    // x0, x1, weight of x1
    let s = clamp((f32(d) + 0.5) * f32(i) / f32(o) - 0.5, 0.0, f32(i - 1u));
    let x0 = floor(s);
    return vec3f(x0, min(x0 + 1.0, f32(i - 1u)), s - x0);
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= p.mw || id.y >= p.mh) {
        return;
    }
    let ax = axis(id.x, p.fw, p.mw);
    let ay = axis(id.y, p.fh, p.mh);
    let a = textureLoad(src, vec2i(i32(ax.x), i32(ay.x)), 0).rgb;
    let b = textureLoad(src, vec2i(i32(ax.y), i32(ay.x)), 0).rgb;
    let c = textureLoad(src, vec2i(i32(ax.x), i32(ay.y)), 0).rgb;
    let d = textureLoad(src, vec2i(i32(ax.y), i32(ay.y)), 0).rgb;
    let top = a + (b - a) * ax.z;
    let bot = c + (d - c) * ax.z;
    let v = ((top + (bot - top) * ay.z) - p.mean.rgb) * p.inv_std.rgb;
    let plane = p.mw * p.mh;
    let i = p.out_off + id.y * p.mw + id.x;
    dst[i] = v.r;
    dst[i + plane] = v.g;
    dst[i + 2u * plane] = v.b;
}
