const PI = 3.14159265358979;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let y = dot(p.rgb, vec3f(0.2126, 0.7152, 0.0722));
    let u = (p.b - y) / 1.8556;
    let v = (p.r - y) / 1.5748;

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

    var t = 1.0;
    if (diff < params.similarity) {
        t = 0.0;
    } else if (params.blend > 0.0000001) {
        t = clamp((diff - params.similarity) / params.blend, 0.0, 1.0);
    }
    let f = 1.0 - t;
    let b = y + u * f * 1.8556;
    let r = y + v * f * 1.5748;
    let g = (y - 0.2126 * r - 0.0722 * b) / 0.7152;
    gpufx_write(id, vec4f(clamp(vec3f(r, g, b), vec3f(0.0), vec3f(1.0)), p.a));
}
