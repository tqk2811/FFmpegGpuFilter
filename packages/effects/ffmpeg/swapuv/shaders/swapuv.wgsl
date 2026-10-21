fn gpufx_rgb_to_yuv(c: vec3f) -> vec3f {
    // BT.709 full range, U and V centered on 0.5
    let y = dot(c, vec3f(0.2126, 0.7152, 0.0722));
    return vec3f(y, (c.b - y) / 1.8556 + 0.5, (c.r - y) / 1.5748 + 0.5);
}
fn gpufx_yuv_to_rgb(c: vec3f) -> vec3f {
    let u = c.y - 0.5;
    let v = c.z - 0.5;
    return vec3f(c.x + 1.5748 * v, c.x - 0.18732 * u - 0.46812 * v, c.x + 1.8556 * u);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let yuv = gpufx_rgb_to_yuv(c.rgb);
    gpufx_write(id, vec4f(gpufx_yuv_to_rgb(vec3f(yuv.x, yuv.z, yuv.y)), c.a));
}
