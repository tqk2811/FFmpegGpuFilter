@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let n = vec2i(globals.size);
    let p = vec2i(id.xy);
    let c = textureLoad(src, p, 0);

    let bx = params.x;
    let by = params.y;
    // a width or height of 0 (or less) takes the size of the input
    var bw = params.width;
    if (bw <= 0) { bw = n.x; }
    var bh = params.height;
    if (bh <= 0) { bh = n.y; }
    var t = params.thickness;
    if (params.fill != 0u) { t = 1000000; }

    let inside = p.x >= max(bx, 0) && p.x < min(bx + bw, n.x) && p.y >= max(by, 0) && p.y < min(by + bh, n.y);
    let on_edge = (p.y - by < t) || (by + bh - 1 - p.y < t) || (p.x - bx < t) || (bx + bw - 1 - p.x < t);
    if (!(inside && on_edge)) {
        gpufx_write(id, c);
        return;
    }
    if (params.invert != 0u) {
        gpufx_write(id, vec4f(1.0 - c.rgb, c.a));
    } else if (params.replace != 0u) {
        gpufx_write(id, params.color);
    } else {
        gpufx_write(id, vec4f(mix(c.rgb, params.color.rgb, params.color.a), c.a));
    }
}
