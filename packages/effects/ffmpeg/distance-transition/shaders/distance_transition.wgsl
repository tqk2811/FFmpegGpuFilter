// Port of FFmpeg's xfade distance: pixels whose color differs little between the clips
// switch first, the others later, with a cross-fade on top.
// FFmpeg's progress runs 1 -> 0; here p = 1 - progress.
// FFmpeg measures the difference over its Y, U, V planes; here over Y, U, V computed from
// the RGBA texels (BT.601, full range).
fn yuv(c: vec4f) -> vec3f {
    let y = dot(c.rgb, vec3f(0.299, 0.587, 0.114));
    return vec3f(y, 0.5 + (c.b - y) * 0.564, 0.5 + (c.r - y) * 0.713);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    let p = 1.0 - params.progress;
    let d = length(yuv(a) - yuv(b));
    // The color distance can exceed 1 (up to sqrt 3); at progress 0 every pixel keeps the
    // first clip, so the start is exact.
    let near = d <= p || p >= 1.0;
    let sel = select(b, a, near);               // FFmpeg: mix(xf0, xf1, near) with near = 0 or 1
    gpufx_write(id, sel * p + b * (1.0 - p));
}
