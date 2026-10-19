
fn coord(o: u32, size: u32) -> vec3f {
    // PyTorch's bilinear source index (align_corners=False): (o + 0.5) * in / out - 0.5, at least 0.
    let s = max((f32(o) + 0.5) * f32(size) / f32(SMALL) - 0.5, 0.0);
    let i0 = min(u32(s), size - 1u);
    let i1 = min(i0 + 1u, size - 1u);
    return vec3f(f32(i0), f32(i1), s - f32(i0));
}

fn sample(f: u32, x: vec3f, y: vec3f) -> vec3f {
    let x0 = i32(x.x);
    let x1 = i32(x.y);
    let y0 = i32(y.x);
    let y1 = i32(y.y);
    var v00: vec3f;
    var v01: vec3f;
    var v10: vec3f;
    var v11: vec3f;
    if (f == 0u) {
        v00 = textureLoad(frame0, vec2i(x0, y0), 0).rgb;
        v01 = textureLoad(frame0, vec2i(x1, y0), 0).rgb;
        v10 = textureLoad(frame0, vec2i(x0, y1), 0).rgb;
        v11 = textureLoad(frame0, vec2i(x1, y1), 0).rgb;
    } else {
        v00 = textureLoad(frame1, vec2i(x0, y0), 0).rgb;
        v01 = textureLoad(frame1, vec2i(x1, y0), 0).rgb;
        v10 = textureLoad(frame1, vec2i(x0, y1), 0).rgb;
        v11 = textureLoad(frame1, vec2i(x1, y1), 0).rgb;
    }
    return (1.0 - y.z) * ((1.0 - x.z) * v00 + x.z * v01) + y.z * ((1.0 - x.z) * v10 + x.z * v11);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    let x = coord(id.x, p.w);
    let y = coord(id.y, p.h);
    let o = id.y * SMALL + id.x;
    for (var f = 0u; f < 2u; f++) {
        let v = sample(f, x, y);
        state.data[(f * 3u + 0u) * PLANE + o] = v.r;
        state.data[(f * 3u + 1u) * PLANE + o] = v.g;
        state.data[(f * 3u + 2u) * PLANE + o] = v.b;
    }
}
