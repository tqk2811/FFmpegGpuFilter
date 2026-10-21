// Port of FFmpeg's xfade radial: a clock-hand sweep with a soft edge around the center.
// FFmpeg's progress runs 1 -> 0; here p = 1 - progress. FFmpeg turns the hand by 2.5 pi
// (the last angle then still blends a little); the sweep here is 2 * (pi + 1), just enough
// for the second clip to be fully shown at progress 1.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    let cx = floor(globals.size.x * 0.5);
    let cy = floor(globals.size.y * 0.5);
    let p = 1.0 - params.progress;
    let sweep = 2.0 * (3.14159265 + 1.0);
    let edge = atan2(f32(id.x) - cx, f32(id.y) - cy) - (p - 0.5) * sweep;
    let m = smoothstep(0.0, 1.0, edge);         // weight of the second clip
    gpufx_write(id, a * (1.0 - m) + b * m);
}
