// One tile of an RGBA texture to the first 3 channel planes of a tensor at `out_off` (`tw x th`), values mapped
// to [lo, hi]. Tile pixel (x, y) is frame pixel (sx + x, sy + y); outside the frame it is the reflection without
// edge repeat (reflect-101, as gpufx-nnconv `reflect101`), or the edge pixel when `replicate` is set.

struct P {
    fw: u32,
    fh: u32,
    sx: i32,
    sy: i32,
    tw: u32,
    th: u32,
    out_off: u32,
    lo: f32,
    hi: f32,
    replicate: u32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var<storage, read_write> dst: array<f32>;

fn fold(i: i32, n: u32) -> i32 {
    let last = i32(n) - 1;
    if (p.replicate != 0u) {
        return clamp(i, 0, last);
    }
    if (n <= 1u) {
        return 0;
    }
    let period = 2 * last;
    let m = ((i % period) + period) % period;
    return select(period - m, m, m <= last);
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= p.tw || id.y >= p.th) {
        return;
    }
    let x = fold(p.sx + i32(id.x), p.fw);
    let y = fold(p.sy + i32(id.y), p.fh);
    let v = p.lo + (p.hi - p.lo) * textureLoad(src, vec2i(x, y), 0).rgb;
    let plane = p.tw * p.th;
    let i = p.out_off + id.y * p.tw + id.x;
    dst[i] = v.r;
    dst[i + plane] = v.g;
    dst[i + 2u * plane] = v.b;
}
