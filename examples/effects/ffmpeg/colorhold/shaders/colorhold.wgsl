@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let d = p.rgb - params.color.rgb;
    let diff = sqrt(dot(d, d) / 3.0);
    var t = select(0.0, 1.0, diff > params.similarity);
    if (params.blend >= 0.0001) {
        t = clamp((diff - params.similarity) / params.blend, 0.0, 1.0);
    }
    let a = (p.r + p.g + p.b) / 3.0;
    gpufx_write(id, vec4f(mix(p.rgb, vec3f(a), t), p.a));
}
