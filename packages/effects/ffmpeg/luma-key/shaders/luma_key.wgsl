@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    // FFmpeg compares the Y plane of the video (16..235 for limited range): map the full-range luma back to it.
    let l = (16.0 + 219.0 * dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722))) / 255.0;
    let white = clamp(params.threshold + params.tolerance, 0.0, 1.0);
    let black = clamp(params.threshold - params.tolerance, 0.0, 1.0);
    let so = params.softness;
    var alpha = 1.0;
    if (l >= black && l <= white) {
        alpha = 0.0;
    } else if (so > 0.0 && l > black - so && l < white + so) {
        if (l < black) {
            alpha = 1.0 - (l - black + so) / so;
        } else {
            alpha = (l - white) / so;
        }
    }
    gpufx_write(id, vec4f(c.rgb, c.a * alpha));
}
