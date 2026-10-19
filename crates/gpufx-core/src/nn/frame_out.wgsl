// The first 3 channel planes of a tensor at `in_off` (`wp x hp`, cropped to the texture size) to an
// rgba8unorm texture: clamped to [lo, hi], mapped to 0..1 and rounded to 8 bits as the CPU reference does
// (floor(v * 255 + 0.5)), so the unorm conversion is exact.

struct P {
    w: u32,
    h: u32,
    wp: u32,
    hp: u32,
    in_off: u32,
    lo: f32,
    hi: f32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> src0: array<f32>;
@group(0) @binding(2) var dst: texture_storage_2d<rgba8unorm, write>;

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= p.w || id.y >= p.h) {
        return;
    }
    let plane = p.wp * p.hp;
    let i = p.in_off + id.y * p.wp + id.x;
    let v = clamp(vec3f(src0[i], src0[i + plane], src0[i + 2u * plane]), vec3f(p.lo), vec3f(p.hi));
    let q = clamp(floor((v - p.lo) / (p.hi - p.lo) * 255.0 + 0.5), vec3f(0.0), vec3f(255.0)) / 255.0;
    textureStore(dst, vec2i(id.xy), vec4f(q, 1.0));
}
