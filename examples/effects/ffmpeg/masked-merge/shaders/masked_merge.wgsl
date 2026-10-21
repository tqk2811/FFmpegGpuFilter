@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let b = textureSampleLevel(base, smp, uv, 0.0);
    let o = textureSampleLevel(overlay, smp, uv, 0.0);
    let m = textureSampleLevel(mask, smp, uv, 0.0).rgb;
    // FFmpeg: base * (1 - mask) + overlay * mask
    gpufx_write(id, vec4f(b.rgb * (vec3f(1.0) - m) + o.rgb * m, b.a));
}
