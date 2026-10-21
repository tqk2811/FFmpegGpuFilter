@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let d = c.rgb - params.color.rgb;
    let diff = sqrt(dot(d, d) / 3.0);
    var alpha = select(0.0, 1.0, diff > params.similarity);
    if (params.blend >= 0.0001) {
        alpha = clamp((diff - params.similarity) / params.blend, 0.0, 1.0);
    }
    gpufx_write(id, vec4f(c.rgb, c.a * alpha));
}
