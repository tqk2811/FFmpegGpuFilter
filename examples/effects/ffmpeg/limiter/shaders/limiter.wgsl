@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let top = f32((1u << u32(clamp(params.depth, 1, 16))) - 1u);
    let lo = min(f32(params.min), top) / top;
    let hi = max(min(f32(params.max), top) / top, lo);
    let planes = u32(params.planes);
    var c = vec4f(p.g, p.b, p.r, p.a);
    for (var i = 0u; i < 4u; i++) {
        if ((planes & (1u << i)) != 0u) {
            c[i] = clamp(c[i], lo, hi);
        }
    }
    gpufx_write(id, vec4f(c.z, c.x, c.y, c.w));
}
