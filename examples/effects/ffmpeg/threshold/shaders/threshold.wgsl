@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(src, smp, uv, 0.0);
    let t = textureSampleLevel(threshold, smp, uv, 0.0);
    let lo = textureSampleLevel(min_in, smp, uv, 0.0);
    let hi = textureSampleLevel(max_in, smp, uv, 0.0);
    // FFmpeg: out = in <= threshold ? min : max
    let r = select(hi, lo, a <= t);
    let on = vec4<bool>((params.planes & 1) != 0, (params.planes & 2) != 0, (params.planes & 4) != 0, (params.planes & 8) != 0);
    gpufx_write(id, select(a, r, on));
}
