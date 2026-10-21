@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let n = vec2i(globals.size);
    let p = vec2i(id.xy);
    let c = textureLoad(src, p, 0);

    // a cell width or height of 0 (or less) takes the size of the input
    var cw = params.width;
    if (cw <= 0) { cw = n.x; }
    var ch = params.height;
    if (ch <= 0) { ch = n.y; }
    let m = vec2i(((p.x - params.x) % cw + cw) % cw, ((p.y - params.y) % ch + ch) % ch);
    if (!(m.x < params.thickness || m.y < params.thickness)) {
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
