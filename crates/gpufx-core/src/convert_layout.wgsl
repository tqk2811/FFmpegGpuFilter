// Converts between the pixel_layouts effects see (see convert::LayoutConvert). The
// bindings, `load_src` (the Y, Cb, Cr, A stored codes of a luma pixel, 0..1) and `main`
// follow, generated for each pair of layouts.

// Layout must match `LayoutConvert::encode`.
struct LayoutConv {
    kr: f32,              // luma weights of the matrix
    kb: f32,
    full: u32,            // full range YUV
    pad0: u32,
    size: vec2u,          // luma size
    src_scale: vec2u,     // luma pixels per UV texel of the source and the destination
    dst_scale: vec2u,
    pad1: vec2u,
};

@group(0) @binding(0) var<uniform> lc: LayoutConv;

// Chroma code of no colour (128 of 255).
const NEUTRAL: f32 = 128.0 / 255.0;

// Straight RGBA to the stored Y, Cb, Cr codes (and alpha).
fn to_codes(c: vec4f) -> vec4f {
    let kg = 1.0 - lc.kr - lc.kb;
    let y = lc.kr * c.r + kg * c.g + lc.kb * c.b;
    let cb = (c.b - y) / (2.0 * (1.0 - lc.kb));
    let cr = (c.r - y) / (2.0 * (1.0 - lc.kr));
    if (lc.full != 0u) {
        return vec4f(y, cb + NEUTRAL, cr + NEUTRAL, c.a);
    }
    return vec4f((16.0 + 219.0 * y) / 255.0, (128.0 + 224.0 * cb) / 255.0, (128.0 + 224.0 * cr) / 255.0, c.a);
}

// The stored codes back to straight RGBA.
fn from_codes(v: vec4f) -> vec4f {
    var y = v.x;
    var cb = v.y - NEUTRAL;
    var cr = v.z - NEUTRAL;
    if (lc.full == 0u) {
        y = (v.x * 255.0 - 16.0) / 219.0;
        cb = (v.y * 255.0 - 128.0) / 224.0;
        cr = (v.z * 255.0 - 128.0) / 224.0;
    }
    let kg = 1.0 - lc.kr - lc.kb;
    let r = y + 2.0 * (1.0 - lc.kr) * cr;
    let b = y + 2.0 * (1.0 - lc.kb) * cb;
    let g = (y - lc.kr * r - lc.kb * b) / kg;
    return clamp(vec4f(r, g, b, v.w), vec4f(0.0), vec4f(1.0));
}

