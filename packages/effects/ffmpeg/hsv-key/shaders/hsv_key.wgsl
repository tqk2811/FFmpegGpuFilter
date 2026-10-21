const PI = 3.14159265358979;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let y = dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722));
    // BT.709 full-range chroma centered on 0 (FFmpeg reads the U and V planes of the video)
    let u = (c.b - y) / 1.8556;
    let v = (c.r - y) / 1.5748;

    // FFmpeg turns the hue option into radians; a negative component means "use the pixel's own value"
    let hue_opt = params.hue;
    let hue_key = select(-1.0, 1.0, hue_opt > 0.0) * PI * ((526.0 - abs(hue_opt)) % 360.0) / 180.0;
    let sat_key = params.sat;
    let val_key = params.val;

    let hue = select(atan2(u, v) + PI, -hue_key, hue_key < 0.0);
    let sat = select(sqrt((u * u + v * v) / 0.5), -sat_key, sat_key < 0.0);
    let val = select(y, -val_key, val_key < 0.0);

    let hk = abs(hue_key);
    let sk = abs(sat_key);
    let vk = abs(val_key);
    let diff = sqrt(max(sat * sat * val * val + sk * sk * vk * vk
        - 2.0 * sat * val * sk * vk * cos(hk - hue)
        + (val - vk) * (val - vk), 0.0));

    var alpha = 1.0;
    if (diff < params.similarity) {
        alpha = 0.0;
    } else if (params.blend > 0.0000001) {
        alpha = clamp((diff - params.similarity) / params.blend, 0.0, 1.0);
    }
    gpufx_write(id, vec4f(c.rgb, c.a * alpha));
}
