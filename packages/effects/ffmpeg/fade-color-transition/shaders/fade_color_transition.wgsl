// Port of FFmpeg's xfade fadeblack/fadewhite (color generalises both).
// FFmpeg's progress runs 1 -> 0; here p = 1 - progress.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    let bg = vec4f(params.color.rgb, 1.0);
    let phase = 0.2;
    let p = 1.0 - params.progress;
    // The first clip fades out over the last 20% of its time, the second fades in
    // from the first 20%, and the two are cross-faded by progress.
    let out_a = mix(bg, a, smoothstep(1.0 - phase, 1.0, p));
    let in_b = mix(b, bg, smoothstep(phase, 1.0, p));
    gpufx_write(id, out_a * p + in_b * (1.0 - p));
}
