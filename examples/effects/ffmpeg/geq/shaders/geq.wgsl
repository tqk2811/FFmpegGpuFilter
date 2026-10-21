@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let s = textureLoad(src, vec2i(id.xy), 0);
    let X = f32(id.x);
    let Y = f32(id.y);
    let W = globals.size.x;
    let H = globals.size.y;
    let T = globals.time;
    // Frame number from the exact time (not globals.frame, which restarts on a seek).
    let N = floor((f32(globals.time_int) + globals.time_frac) * params.fps + 0.001);
    let R = s.r * 255.0;
    let G = s.g * 255.0;
    let B = s.b * 255.0;
    let A = s.a * 255.0;
    let o = vec4f(gpufx_expr_r(X, Y, W, H, T, N, R, G, B, A),
                  gpufx_expr_g(X, Y, W, H, T, N, R, G, B, A),
                  gpufx_expr_b(X, Y, W, H, T, N, R, G, B, A),
                  gpufx_expr_a(X, Y, W, H, T, N, R, G, B, A));
    gpufx_write(id, o / 255.0);
}
