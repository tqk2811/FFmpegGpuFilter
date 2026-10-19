// An RGBA texture to the first 3 channel planes of a tensor at `out_off`, values mapped to [lo, hi], zero
// padded right and bottom to the tensor size `wp x hp`.

struct P {
    w: u32,
    h: u32,
    wp: u32,
    hp: u32,
    out_off: u32,
    lo: f32,
    hi: f32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var<storage, read_write> dst: array<f32>;

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= p.wp || id.y >= p.hp) {
        return;
    }
    var v = vec3f(0.0);
    if (id.x < p.w && id.y < p.h) {
        v = p.lo + (p.hi - p.lo) * textureLoad(src, vec2i(id.xy), 0).rgb;
    }
    let plane = p.wp * p.hp;
    let i = p.out_off + id.y * p.wp + id.x;
    dst[i] = v.r;
    dst[i + plane] = v.g;
    dst[i + 2u * plane] = v.b;
}
