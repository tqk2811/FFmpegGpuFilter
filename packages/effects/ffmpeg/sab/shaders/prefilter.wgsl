// Pass 1: gaussian pre-filter of each channel (swscale's gaussian vector: length (int)(r * 3 + 0.5) | 1,
// weights exp(-d^2 / (2 r^2)), normalised). The result is 8-bit, as in FFmpeg.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let r = params.luma_pre_filter_radius;
    let half_len = ((i32(r * 3.0 + 0.5)) | 1) / 2;
    var sum = vec3f(0.0);
    var wsum = 0.0;
    for (var j = -half_len; j <= half_len; j++) {
        for (var i = -half_len; i <= half_len; i++) {
            let w = exp(-f32(i * i + j * j) / (2.0 * r * r));
            sum += w * round(textureLoad(src, clamp(p + vec2i(i, j), vec2i(0), size - 1), 0).rgb * 255.0);
            wsum += w;
        }
    }
    gpufx_write(id, vec4f(round(sum / wsum) / 255.0, 1.0));
}
