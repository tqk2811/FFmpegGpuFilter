// Port of FFmpeg's xfade wipetl/wipetr/wipebl/wipebr: the first clip shrinks into a corner.
// FFmpeg's progress runs 1 -> 0; here p = 1 - progress (the share of the first clip kept).
// FFmpeg compares with <= / > on integer sizes, which leaves one pixel of the first clip at
// the end (and of the second at the start); strict float comparisons here make both exact.
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
    // Mirror the pixel so that every corner is the top-left one.
    if (params.corner == 1 || params.corner == 3) { x = w - 1.0 - x; }
    if (params.corner == 2 || params.corner == 3) { y = h - 1.0 - y; }
    let p = 1.0 - params.progress;
    let keep_first = x < w * p && y < h * p;
    gpufx_write(id, select(b, a, keep_first));
}
