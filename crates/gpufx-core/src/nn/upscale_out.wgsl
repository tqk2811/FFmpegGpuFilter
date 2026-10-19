// The output rectangle of one tile: the first 3 channel planes of a tensor at `in_off` (`tw x th`) to the
// output pixels [ox, ox + rw) x [oy, oy + rh) of an rgba8unorm texture, output pixel (X, Y) taken from tensor
// pixel (X - dx, Y - dy). Clamped to [lo, hi], mapped to 0..1 and rounded to 8 bits as the CPU reference does
// (floor(v * 255 + 0.5)), so the unorm conversion is exact.

struct P {
    tw: u32,
    th: u32,
    in_off: u32,
    ox: u32,
    oy: u32,
    rw: u32,
    rh: u32,
    dx: i32,
    dy: i32,
    lo: f32,
    hi: f32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> src0: array<f32>;
@group(0) @binding(2) var dst: texture_storage_2d<rgba8unorm, write>;

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= p.rw || id.y >= p.rh) {
        return;
    }
    let ox = p.ox + id.x;
    let oy = p.oy + id.y;
    let plane = p.tw * p.th;
    let i = p.in_off + u32(i32(oy) - p.dy) * p.tw + u32(i32(ox) - p.dx);
    let v = clamp(vec3f(src0[i], src0[i + plane], src0[i + 2u * plane]), vec3f(p.lo), vec3f(p.hi));
    let q = clamp(floor((v - p.lo) / (p.hi - p.lo) * 255.0 + 0.5), vec3f(0.0), vec3f(255.0)) / 255.0;
    textureStore(dst, vec2i(i32(ox), i32(oy)), vec4f(q, 1.0));
}
