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

// Single pass: 2D box average of luma (luma_msize_x/y) and chroma (chroma_msize_x/y) in float,
// then out = c + (c - blurred) * amount per plane.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let hlx = params.luma_msize_x / 2;
    let hly = params.luma_msize_y / 2;
    let hcx = params.chroma_msize_x / 2;
    let hcy = params.chroma_msize_y / 2;
    var luma = 0.0;
    for (var j = -hly; j <= hly; j++) {
        for (var i = -hlx; i <= hlx; i++) {
            luma += ld(p + vec2i(i, j), size).x;
        }
    }
    var chroma = vec2f(0.0);
    for (var j = -hcy; j <= hcy; j++) {
        for (var i = -hcx; i <= hcx; i++) {
            chroma += ld(p + vec2i(i, j), size).yz;
        }
    }
    let blur = vec3f(luma / f32((2 * hlx + 1) * (2 * hly + 1)), chroma / f32((2 * hcx + 1) * (2 * hcy + 1)));
    let s = textureLoad(src, p, 0);
    let c = to_ycc(s.rgb);
    let amount = vec3f(params.luma_amount, params.chroma_amount, params.chroma_amount);
    gpufx_write(id, vec4f(to_rgb(c + (c - blur) * amount), s.a));
}
