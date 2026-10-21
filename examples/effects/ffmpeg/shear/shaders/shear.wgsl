@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = globals.size;
    let p = vec2f(id.xy);
    var s = vec2f(
        p.x + params.shx * p.y - params.shx * size.y * 0.5,
        p.y + params.shy * p.x - params.shy * size.x * 0.5);
    if (params.interp == 0) {
        s = trunc(s);
    }
    if (s.x < 0.0 || s.y < 0.0 || s.x >= size.x - 1.0 || s.y >= size.y - 1.0) {
        gpufx_write(id, params.fillcolor);
        return;
    }
    if (params.interp == 0) {
        gpufx_write(id, textureLoad(src, vec2i(s), 0));
    } else {
        gpufx_write(id, textureSampleLevel(src, smp, (s + 0.5) / size, 0.0));
    }
}
