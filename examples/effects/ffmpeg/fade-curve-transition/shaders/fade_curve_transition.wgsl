@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    // FFmpeg's progress is 1 on the first clip and 0 on the second.
    let fp = 1.0 - params.progress;
    if (fp <= 0.0) { gpufx_write(id, b); return; }
    if (fp >= 1.0) { gpufx_write(id, a); return; }
    let diff = abs(a - b);
    var e: vec4f;
    if (params.curve == 0) {
        e = 1.0 + log(1.0 + diff);
    } else {
        e = 1.0 + log(2.0 - diff);
    }
    // Weight of the first clip.
    let w = pow(vec4f(fp), e);
    gpufx_write(id, a * w + b * (vec4f(1.0) - w));
}
