@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let s = textureSampleLevel(source, smp, uv, 0.0);
    let r = textureSampleLevel(reference, smp, uv, 0.0);
    let t = vec4f(params.threshold / 255.0);
    var o: vec4f;
    if (params.mode == 0) {
        // Compared on the 0..255 scale after rounding so 1-step differences do not flip on float error.
        // abs: |src - ref| <= threshold ? src : ref
        o = select(r, s, round(abs(s - r) * 255.0) <= vec4f(params.threshold));
    } else {
        // diff: ref - src <= threshold ? max(ref - threshold, 0) : src
        o = select(s, max(r - t, vec4f(0.0)), round((r - s) * 255.0) <= vec4f(params.threshold));
    }
    let on = vec4<bool>((params.planes & 1) != 0, (params.planes & 2) != 0, (params.planes & 4) != 0, (params.planes & 8) != 0);
    gpufx_write(id, select(s, o, on));
}
