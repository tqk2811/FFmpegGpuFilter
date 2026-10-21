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

// Filtered value after strength and threshold; all values are 0..1 (thr is the 8-bit threshold / 255).
fn plane(orig: f32, blur: f32, strength: f32, thr: f32) -> f32 {
    let filtered = orig + strength * (blur - orig);
    let diff = orig - filtered;
    let ad = abs(diff);
    let sg = select(-1.0, 1.0, diff > 0.0);
    if (thr > 0.0) {
        if (ad > 2.0 * thr) { return orig; }
        if (ad > thr) { return orig - sg * thr; }
        return filtered;
    }
    if (thr < 0.0) {
        let t = -thr;
        if (ad <= t) { return orig; }
        if (ad <= 2.0 * t) { return filtered + sg * t; }
        return filtered;
    }
    return filtered;
}

// Pass 2: vertical gaussian of the pass-1 result, then strength and threshold against the original.
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
    for (var j = -rl; j <= rl; j++) {
        let k = gw(j, sl);
        luma += k * textureLoad(tmp, clamp(p + vec2i(0, j), vec2i(0), size - 1), 0).x;
        wl += k;
    }
    var chroma = vec2f(0.0);
    var wc = 0.0;
    for (var j = -rc; j <= rc; j++) {
        let k = gw(j, sc);
        chroma += k * (textureLoad(tmp, clamp(p + vec2i(0, j), vec2i(0), size - 1), 0).yz - 0.5);
        wc += k;
    }
    let s = textureLoad(src, p, 0);
    let c = to_ycc(s.rgb);
    let cs = select(params.luma_strength, params.chroma_strength, params.chroma_strength >= -1.0);
    let ct = select(params.luma_threshold, params.chroma_threshold, params.chroma_threshold >= -30);
    let y = plane(c.x, luma / wl, params.luma_strength, f32(params.luma_threshold) / 255.0);
    let cb = plane(c.y, chroma.x / wc, cs, f32(ct) / 255.0);
    let cr = plane(c.z, chroma.y / wc, cs, f32(ct) / 255.0);
    gpufx_write(id, vec4f(to_rgb(vec3f(y, cb, cr)), s.a));
}
