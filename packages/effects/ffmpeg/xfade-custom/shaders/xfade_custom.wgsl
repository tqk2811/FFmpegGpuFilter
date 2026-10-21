@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let a = textureLoad(first, vec2i(id.xy), 0);
    let b = textureLoad(second, vec2i(id.xy), 0);
    let prog = clamp(params.progress, 0.0, 1.0);
    // The endpoints are forced so the transition starts exactly on the first clip and ends on the second.
    if (prog <= 0.0) { gpufx_write(id, a); return; }
    if (prog >= 1.0) { gpufx_write(id, b); return; }
    let X = f32(id.x);
    let Y = f32(id.y);
    let W = globals.size.x;
    let H = globals.size.y;
    let P = 1.0 - prog;
    let a8 = a.rgb * 255.0;
    let b8 = b.rgb * 255.0;
    let c = vec3f(gpufx_expr_expr(X, Y, W, H, P, a8.r, b8.r),
                  gpufx_expr_expr(X, Y, W, H, P, a8.g, b8.g),
                  gpufx_expr_expr(X, Y, W, H, P, a8.b, b8.b));
    gpufx_write(id, vec4f(clamp(c, vec3f(0.0), vec3f(255.0)) / 255.0, mix(a.a, b.a, prog)));
}
