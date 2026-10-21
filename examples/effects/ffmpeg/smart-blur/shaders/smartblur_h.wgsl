fn to_ycc(c: vec3f) -> vec3f {
    let y = dot(c, vec3f(0.2126, 0.7152, 0.0722));
    return vec3f(y, (c.b - y) / 1.8556, (c.r - y) / 1.5748);
}

fn to_rgb(c: vec3f) -> vec3f {
    let r = c.x + 1.5748 * c.z;
    let b = c.x + 1.8556 * c.y;
    return vec3f(r, (c.x - 0.2126 * r - 0.0722 * b) / 0.7152, b);
}

fn ld(p: vec2i, size: vec2i) -> vec3f {
    return to_ycc(textureLoad(src, clamp(p, vec2i(0), size - 1), 0).rgb);
}

fn gw(i: i32, sigma: f32) -> f32 {
    return exp(-f32(i * i) / (2.0 * sigma * sigma));
}

fn chroma_radius() -> f32 {
    return select(params.luma_radius, params.chroma_radius, params.chroma_radius >= 0.1);
}

// Pass 1: horizontal gaussian (sigma = radius) of luma and chroma; chroma stored +0.5.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let sl = max(params.luma_radius, 0.1);
    let sc = max(chroma_radius(), 0.1);
    let rl = i32(ceil(3.0 * sl));
    let rc = i32(ceil(3.0 * sc));
    var luma = 0.0;
    var wl = 0.0;
    for (var i = -rl; i <= rl; i++) {
        let k = gw(i, sl);
        luma += k * ld(p + vec2i(i, 0), size).x;
        wl += k;
    }
    var chroma = vec2f(0.0);
    var wc = 0.0;
    for (var i = -rc; i <= rc; i++) {
        let k = gw(i, sc);
        chroma += k * ld(p + vec2i(i, 0), size).yz;
        wc += k;
    }
    let a = textureLoad(src, p, 0).a;
    gpufx_write(id, vec4f(luma / wl, chroma / wc + 0.5, a));
}
