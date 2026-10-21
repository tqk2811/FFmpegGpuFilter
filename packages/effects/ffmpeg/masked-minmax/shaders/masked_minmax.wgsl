@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let s = textureSampleLevel(source, smp, uv, 0.0);
    let f1 = textureSampleLevel(filter1, smp, uv, 0.0).rgb;
    let f2 = textureSampleLevel(filter2, smp, uv, 0.0).rgb;
    let d1 = abs(s.rgb - f1);
    let d2 = abs(s.rgb - f2);
    // FFmpeg: maskedmin takes filter2 where |src-f2| < |src-f1|, maskedmax where it is greater
    var pick2 = (d2 < d1);
    if (params.mode == 1) { pick2 = (d2 > d1); }
    gpufx_write(id, vec4f(select(f1, f2, pick2), s.a));
}
