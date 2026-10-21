fn luma(c: vec3f) -> f32 { return dot(c, vec3f(0.2126, 0.7152, 0.0722)); }

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let n = vec2i(globals.size);
    let p = vec2i(id.xy);
    // a map value of 128 (of 255) means no displacement
    let dx = i32(round(luma(textureLoad(xmap, p, 0).rgb) * 255.0)) - 128;
    let dy = i32(round(luma(textureLoad(ymap, p, 0).rgb) * 255.0)) - 128;
    var q = p + vec2i(dx, dy);

    if (params.edge == 0) {
        // blank
        if (q.x < 0 || q.y < 0 || q.x >= n.x || q.y >= n.y) {
            gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0));
            return;
        }
    } else if (params.edge == 1) {
        // smear
        q = clamp(q, vec2i(0), n - vec2i(1));
    } else if (params.edge == 2) {
        // wrap
        q = vec2i(((q.x % n.x) + n.x) % n.x, ((q.y % n.y) + n.y) % n.y);
    } else {
        // mirror
        if (q.x < 0) { q.x = (-q.x) % n.x; }
        if (q.y < 0) { q.y = (-q.y) % n.y; }
        if (q.x >= n.x) { q.x = n.x - (q.x % n.x) - 1; }
        if (q.y >= n.y) { q.y = n.y - (q.y % n.y) - 1; }
    }
    gpufx_write(id, textureLoad(src, q, 0));
}
