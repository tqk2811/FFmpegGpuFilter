@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    // FFmpeg: output plane i = input plane map_i
    gpufx_write(id, vec4f(c[params.map0], c[params.map1], c[params.map2], c[params.map3]));
}
