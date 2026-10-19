// RIFE warp (ncnn warp.comp): every channel of `img` sampled at (x + fx, y + fy), bilinear, clamp to edge.

struct P {
    c: u32,
    h: u32,
    w: u32,
    img_off: u32,
    flow_off: u32,
    out_off: u32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> img: array<f32>;
@group(0) @binding(2) var<storage, read> flow: array<f32>;
@group(0) @binding(5) var<storage, read_write> dst: array<f32>;

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= p.w || id.y >= p.h) {
        return;
    }
    let plane = p.h * p.w;
    let i = id.y * p.w + id.x;
    let sx = f32(id.x) + flow[p.flow_off + i];
    let sy = f32(id.y) + flow[p.flow_off + plane + i];
    let wl = i32(p.w) - 1;
    let hl = i32(p.h) - 1;
    let fx = i32(floor(sx));
    let fy = i32(floor(sy));
    let x0 = clamp(fx, 0, wl);
    let y0 = clamp(fy, 0, hl);
    let x1 = clamp(fx + 1, 0, wl);
    let y1 = clamp(fy + 1, 0, hl);
    let alpha = sx - f32(x0);
    let beta = sy - f32(y0);
    let r0 = u32(y0) * p.w;
    let r1 = u32(y1) * p.w;
    for (var c = 0u; c < p.c; c++) {
        let base = p.img_off + c * plane;
        let v4 = img[base + r0 + u32(x0)] * (1.0 - alpha) + img[base + r0 + u32(x1)] * alpha;
        let v5 = img[base + r1 + u32(x0)] * (1.0 - alpha) + img[base + r1 + u32(x1)] * alpha;
        dst[p.out_off + c * plane + i] = v4 * (1.0 - beta) + v5 * beta;
    }
}
