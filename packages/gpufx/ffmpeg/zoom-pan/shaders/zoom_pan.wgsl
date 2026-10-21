@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let isz = vec2f(textureDimensions(src));
    let osz = globals.size;
    let time = globals.time;
    let on = floor((f32(globals.time_int) + globals.time_frac) * params.fps + 0.001);
    // WGSL clamp of NaN is undefined, so NaN is replaced first: zoom -> 1, x/y -> 0
    let z_raw = gpufx_expr_zoom(isz.x, isz.y, osz.x, osz.y, time, on);
    let z = clamp(select(z_raw, 1.0, z_raw != z_raw), 1.0, 10.0);
    let view = isz / z;
    let x_raw = gpufx_expr_x(isz.x, isz.y, osz.x, osz.y, time, on, z);
    let x = clamp(select(x_raw, 0.0, x_raw != x_raw), 0.0, max(isz.x - view.x, 0.0));
    let y_raw = gpufx_expr_y(isz.x, isz.y, osz.x, osz.y, time, on, z, x);
    let y = clamp(select(y_raw, 0.0, y_raw != y_raw), 0.0, max(isz.y - view.y, 0.0));
    let p = vec2f(x, y) + gpufx_uv(id) * view;
    gpufx_write(id, textureSampleLevel(src, smp, p / isz, 0.0));
}
