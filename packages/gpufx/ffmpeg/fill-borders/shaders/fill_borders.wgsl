// Source coordinate of x on one axis for the modes that copy pixels from the inside.
// lo = size of the low border, hi = size of the high border, n = size of the axis.
fn border_source(x: i32, lo: i32, hi: i32, n: i32, mode: i32) -> i32 {
    let end = n - hi; // first pixel of the high border
    var s = x;
    if (mode == 0) {
        s = clamp(x, lo, max(end - 1, lo));          // smear
    } else if (mode == 1) {
        if (x < lo) { s = 2 * lo - 1 - x; }          // mirror
        else if (x >= end) { s = 2 * end - 1 - x; }
    } else if (mode == 3) {
        if (x < lo) { s = 2 * lo - x; }              // reflect
        else if (x >= end) { s = 2 * end - 2 - x; }
    } else if (mode == 4) {
        if (x < lo) { s = end - lo + x; }            // wrap
        else if (x >= end) { s = lo + x - end; }
    }
    return clamp(s, 0, n - 1);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let n = vec2i(globals.size);
    let p = vec2i(id.xy);
    let left = min(params.left, n.x);
    let right = min(params.right, n.x);
    let top = min(params.top, n.y);
    let bottom = min(params.bottom, n.y);
    let in_border = p.x < left || p.x >= n.x - right || p.y < top || p.y >= n.y - bottom;
    let mode = params.mode;

    if (mode == 2) {
        // fixed
        if (in_border) { gpufx_write(id, params.color); }
        else { gpufx_write(id, textureLoad(src, p, 0)); }
        return;
    }
    if (mode == 5) {
        // fade: each border side blends towards the color, fully at the edge of the frame
        var c = textureLoad(src, p, 0);
        if (p.y < top) { c = mix(c, params.color, f32(top - p.y) / f32(top)); }
        if (p.y >= n.y - bottom) { c = mix(c, params.color, f32(p.y - (n.y - bottom)) / f32(bottom)); }
        if (p.x < left) { c = mix(c, params.color, f32(left - p.x) / f32(left)); }
        if (p.x >= n.x - right) { c = mix(c, params.color, f32(p.x - (n.x - right)) / f32(right)); }
        gpufx_write(id, c);
        return;
    }
    let q = vec2i(
        border_source(p.x, left, right, n.x, mode),
        border_source(p.y, top, bottom, n.y, mode));
    gpufx_write(id, textureLoad(src, q, 0));
}
