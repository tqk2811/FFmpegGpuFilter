@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let isz = vec2f(textureDimensions(src));
    let osz = globals.size;
    let time = globals.time;
    let on = floor((f32(globals.time_int) + globals.time_frac) * params.fps + 0.001);
    let z = clamp(gpufx_expr_zoom(isz.x, isz.y, osz.x, osz.y, time, on), 1.0, 10.0);
    let view = isz / z;
    let x = clamp(gpufx_expr_x(isz.x, isz.y, osz.x, osz.y, time, on, z), 0.0, max(isz.x - view.x, 0.0));
    let y = clamp(gpufx_expr_y(isz.x, isz.y, osz.x, osz.y, time, on, z, x), 0.0, max(isz.y - view.y, 0.0));
    let p = vec2f(x, y) + gpufx_uv(id) * view;
    gpufx_write(id, textureSampleLevel(src, smp, p / isz, 0.0));
}
