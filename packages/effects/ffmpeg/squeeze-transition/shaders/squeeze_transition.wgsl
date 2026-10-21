@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = globals.size;
    let uv = gpufx_uv(id);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    // FFmpeg's progress is 1 on the first clip and 0 on the second.
    let fp = 1.0 - params.progress;
    if (fp <= 0.0) {
        gpufx_write(id, b);
        return;
    }
    let vertical = params.direction == 1;
    let pos = select(f32(id.y), f32(id.x), vertical);
    let len = select(size.y, size.x, vertical);
    let z = 0.5 + (pos / max(len - 1.0, 1.0) - 0.5) / fp;
    if (z < 0.0 || z > 1.0) {
        gpufx_write(id, b);
        return;
    }
    let src = i32(round(z * (len - 1.0)));
    let q = select(vec2i(i32(id.x), src), vec2i(src, i32(id.y)), vertical);
    gpufx_write(id, textureLoad(first, q, 0));
}
