// Port of FFmpeg's xfade smoothleft/smoothright/smoothup/smoothdown.
// FFmpeg's progress runs 1 -> 0; here p = 1 - progress.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    let w = globals.size.x;
    let h = globals.size.y;
    let x = f32(id.x);
    let y = f32(id.y);
    let p = 1.0 - params.progress;
    var edge = 1.0 + x / w - p * 2.0;           // 0 = left
    if (params.direction == 1) { edge = 1.0 + (w - 1.0 - x) / w - p * 2.0; }
    if (params.direction == 2) { edge = 1.0 + y / h - p * 2.0; }
    if (params.direction == 3) { edge = 1.0 + (h - 1.0 - y) / h - p * 2.0; }
    let m = smoothstep(0.0, 1.0, edge);         // weight of the second clip
    gpufx_write(id, a * (1.0 - m) + b * m);
}
