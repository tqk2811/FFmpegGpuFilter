fn q(c: f32) -> f32 {
    return round(clamp(c, 0.0, 1.0) * 255.0);
}

fn out_ch(res: f32) -> f32 {
    // FFmpeg truncates the result to an integer, then clips it to 0..255.
    return clamp(floor(res + 0.001), 0.0, 255.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let s = textureLoad(src, vec2i(id.xy), 0);
    let W = globals.size.x;
    let H = globals.size.y;
    // RGB to YUV, BT.709 full range, each channel on 0..255 with 128 as neutral chroma.
    let y0 = dot(s.rgb, vec3f(0.2126, 0.7152, 0.0722));
    let u0 = (s.b - y0) / 1.8556;
    let v0 = (s.r - y0) / 1.5748;
    let vy = q(y0);
    let vu = clamp(round(u0 * 255.0 + 128.0), 0.0, 255.0);
    let vv = clamp(round(v0 * 255.0 + 128.0), 0.0, 255.0);
    let va = q(s.a);
    let yo = out_ch(gpufx_expr_y(vy, 255.0, 0.0, 255.0 - vy, clamp(vy, 0.0, 255.0), W, H));
    let uo = out_ch(gpufx_expr_u(vu, 255.0, 0.0, 255.0 - vu, clamp(vu, 0.0, 255.0), W, H));
    let vo = out_ch(gpufx_expr_v(vv, 255.0, 0.0, 255.0 - vv, clamp(vv, 0.0, 255.0), W, H));
    let ao = out_ch(gpufx_expr_a(va, 255.0, 0.0, 255.0 - va, clamp(va, 0.0, 255.0), W, H));
    // Pass-through when every expression returned its input unchanged (keeps the original pixel exactly).
    if (yo == vy && uo == vu && vo == vv && ao == va) {
        gpufx_write(id, s);
        return;
    }
    // Back to float: chroma is centred on 128 in both directions.
    let yf = yo / 255.0;
    let uf = (uo - 128.0) / 255.0;
    let vf = (vo - 128.0) / 255.0;
    // YUV to RGB, BT.709 full range.
    let r = yf + 1.5748 * vf;
    let b = yf + 1.8556 * uf;
    let g = (yf - 0.2126 * r - 0.0722 * b) / 0.7152;
    gpufx_write(id, vec4f(r, g, b, ao / 255.0));
}
