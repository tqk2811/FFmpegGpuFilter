// Port of FFmpeg's colorize: the chroma of a fixed HSL color over the (mixed) luma of the picture.

fn hue2rgb(p: f32, q: f32, t_in: f32) -> f32 {
    var t = t_in;
    if (t < 0.0) { t += 1.0; }
    if (t > 1.0) { t -= 1.0; }
    if (t < 1.0 / 6.0) { return p + (q - p) * 6.0 * t; }
    if (t < 0.5) { return q; }
    if (t < 2.0 / 3.0) { return p + (q - p) * (2.0 / 3.0 - t) * 6.0; }
    return p;
}

fn hsl2rgb(h_deg: f32, s: f32, l: f32) -> vec3f {
    let h = h_deg / 360.0;
    if (s == 0.0) {
        return vec3f(l);
    }
    let q = select(l + s - l * s, l * (1.0 + s), l < 0.5);
    let p = 2.0 * l - q;
    return vec3f(hue2rgb(p, q, h + 1.0 / 3.0), hue2rgb(p, q, h), hue2rgb(p, q, h - 1.0 / 3.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let kw = vec3f(0.2126, 0.7152, 0.0722);
    let target_rgb = hsl2rgb(params.hue, params.saturation, params.lightness);
    // FFmpeg scales the color's Y by 219/255 and U, V by 224/255 (video range factors) but writes
    // them into the picture's planes as they are; the same factors are kept.
    let ty_full = dot(target_rgb, kw);
    let ty = ty_full * (219.0 / 255.0);
    let tu = (target_rgb.z - ty_full) / 1.8556 * (224.0 / 255.0);
    let tv = (target_rgb.x - ty_full) / 1.5748 * (224.0 / 255.0);
    let sy = dot(p.rgb, kw);
    let y = mix(ty, sy, params.mix);
    let o = vec3f(y + 1.5748 * tv, y - 0.1873 * tu - 0.4681 * tv, y + 1.8556 * tu);
    gpufx_write(id, vec4f(o, p.a));
}
