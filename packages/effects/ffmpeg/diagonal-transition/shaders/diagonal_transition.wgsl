// Port of FFmpeg's xfade diagtl/diagtr/diagbl/diagbr.
// FFmpeg's progress runs 1 -> 0; here p = 1 - progress.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    let w = globals.size.x;
    let h = globals.size.y;
    var x = f32(id.x);
    var y = f32(id.y);
    // corner: 0 = top-left, 1 = top-right, 2 = bottom-left, 3 = bottom-right.
    if (params.corner == 1 || params.corner == 3) { x = w - 1.0 - x; }
    if (params.corner == 2 || params.corner == 3) { y = h - 1.0 - y; }
    let p = 1.0 - params.progress;
    let edge = 1.0 + x / w * y / h - p * 2.0;
    let m = smoothstep(0.0, 1.0, edge);         // weight of the second clip
    gpufx_write(id, a * (1.0 - m) + b * m);
}
