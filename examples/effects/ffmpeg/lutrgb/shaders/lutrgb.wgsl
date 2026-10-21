fn q(c: f32) -> f32 {
    return round(clamp(c, 0.0, 1.0) * 255.0);
}

fn out_ch(res: f32) -> f32 {
    // FFmpeg truncates the result to an integer, then clips it to 0..255.
    return clamp(floor(res + 0.001), 0.0, 255.0) / 255.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let s = textureLoad(src, vec2i(id.xy), 0);
    let W = globals.size.x;
    let H = globals.size.y;
    let vr = q(s.r);
    let vg = q(s.g);
    let vb = q(s.b);
    let va = q(s.a);
    gpufx_write(id, vec4f(out_ch(gpufx_expr_r(vr, 255.0, 0.0, 255.0 - vr, clamp(vr, 0.0, 255.0), W, H)),
                          out_ch(gpufx_expr_g(vg, 255.0, 0.0, 255.0 - vg, clamp(vg, 0.0, 255.0), W, H)),
                          out_ch(gpufx_expr_b(vb, 255.0, 0.0, 255.0 - vb, clamp(vb, 0.0, 255.0), W, H)),
                          out_ch(gpufx_expr_a(va, 255.0, 0.0, 255.0 - va, clamp(va, 0.0, 255.0), W, H))));
}
