// luma coefficients (kr, kg, kb): bt709, fcc, bt601, smpte240m, bt2020
fn coeffs(m: i32) -> vec3f {
    if (m == 1) { return vec3f(0.30, 0.59, 0.11); }
    if (m == 2) { return vec3f(0.299, 0.587, 0.114); }
    if (m == 3) { return vec3f(0.212, 0.701, 0.087); }
    if (m == 4) { return vec3f(0.2627, 0.678, 0.0593); }
    return vec3f(0.2126, 0.7152, 0.0722);
}

fn encode(c: vec3f, k: vec3f) -> vec3f {
    let y = dot(c, k);
    return vec3f(y, 0.5 * (c.b - y) / (1.0 - k.z), 0.5 * (c.r - y) / (1.0 - k.x));
}

fn decode(yuv: vec3f, k: vec3f) -> vec3f {
    let r = yuv.x + yuv.z * 2.0 * (1.0 - k.x);
    let b = yuv.x + yuv.y * 2.0 * (1.0 - k.z);
    let g = (yuv.x - k.x * r - k.z * b) / k.y;
    return vec3f(r, g, b);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let k709 = coeffs(0);
    let ks = coeffs(clamp(params.src, 0, 4));
    let kd = coeffs(clamp(params.dst, 0, 4));
    let yuv = encode(p.rgb, k709);
    let out_rgb = decode(encode(decode(yuv, ks), kd), k709);
    gpufx_write(id, vec4f(clamp(out_rgb, vec3f(0.0), vec3f(1.0)), p.a));
}
