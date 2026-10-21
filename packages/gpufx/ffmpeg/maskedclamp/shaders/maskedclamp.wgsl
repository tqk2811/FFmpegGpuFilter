@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let b = textureSampleLevel(base, smp, uv, 0.0);
    let d = textureSampleLevel(dark, smp, uv, 0.0);
    let br = textureSampleLevel(bright, smp, uv, 0.0);
    // FFmpeg: dst = min(max(base, dark - undershoot), bright + overshoot)
    let lo = d - vec4f(params.undershoot / 255.0);
    let hi = br + vec4f(params.overshoot / 255.0);
    let r = min(max(b, lo), hi);
    let on = vec4<bool>((params.planes & 1) != 0, (params.planes & 2) != 0, (params.planes & 4) != 0, (params.planes & 8) != 0);
    gpufx_write(id, select(b, r, on));
}
