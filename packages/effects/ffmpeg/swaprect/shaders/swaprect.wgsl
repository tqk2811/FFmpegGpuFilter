// Swaps two rectangles of the same size. Positions and size come as fractions of the frame and
// are turned into whole pixels like FFmpeg's swaprect does with its expressions.
// Like FFmpeg, the rectangle is shrunk so it fits in the frame at both places (w = min(w, W-x1, W-x2), same for h);
// nothing is swapped only when the shrunk size is not positive.
// The first rectangle wins where the two overlap.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let W = i32(globals.size.x);
    let H = i32(globals.size.y);
    let p = vec2i(id.xy);

    let want = vec2i(i32(params.w * globals.size.x), i32(params.h * globals.size.y));
    let a = vec2i(clamp(i32(params.x1 * globals.size.x), 0, W - 1), clamp(i32(params.y1 * globals.size.y), 0, H - 1));
    let b = vec2i(clamp(i32(params.x2 * globals.size.x), 0, W - 1), clamp(i32(params.y2 * globals.size.y), 0, H - 1));
    let size = vec2i(min(want.x, min(W - a.x, W - b.x)), min(want.y, min(H - a.y, H - b.y)));
    let fits = size.x > 0 && size.y > 0;

    var q = p;
    if (fits) {
        let ra = p - a;
        let rb = p - b;
        if (ra.x >= 0 && ra.y >= 0 && ra.x < size.x && ra.y < size.y) {
            q = b + ra;
        } else if (rb.x >= 0 && rb.y >= 0 && rb.x < size.x && rb.y < size.y) {
            q = a + rb;
        }
    }
    gpufx_write(id, textureLoad(src, q, 0));
}
