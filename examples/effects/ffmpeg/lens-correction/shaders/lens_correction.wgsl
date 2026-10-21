@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = globals.size;
    let center = vec2f(floor(params.cx * size.x), floor(params.cy * size.y));
    let off = vec2f(id.xy) - center;
    // Squared radius, 1 at the corner of a frame with a centered lens (the half diagonal squared is w*w+h*h over 4).
    let r2 = dot(off, off) * 4.0 / (size.x * size.x + size.y * size.y);
    let mult = 1.0 + r2 * params.k1 + r2 * r2 * params.k2;
    let s = center + mult * off;
    let valid = s.x >= 0.0 && s.y >= 0.0 && s.x <= size.x - 1.0 && s.y <= size.y - 1.0;
    if (!valid) {
        gpufx_write(id, params.fc);
        return;
    }
    if (params.i == 0) {
        let q = clamp(vec2i(floor(s + 0.5)), vec2i(0), vec2i(size) - vec2i(1));
        gpufx_write(id, textureLoad(src, q, 0));
    } else {
        gpufx_write(id, textureSampleLevel(src, smp, (s + 0.5) / size, 0.0));
    }
}
