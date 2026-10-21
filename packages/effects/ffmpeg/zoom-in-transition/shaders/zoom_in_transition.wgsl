fn sstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = globals.size;
    let uv = gpufx_uv(id);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    // FFmpeg's progress is 1 on the first clip and 0 on the second.
    let fp = 1.0 - params.progress;
    let zf = sstep(0.5, 1.0, fp);
    let uvz = vec2f(f32(id.x), f32(id.y)) / size;
    let z = 0.5 + (uvz - 0.5) * zf;
    let q = vec2i(ceil(z * (size - 1.0)));
    let a = textureLoad(first, clamp(q, vec2i(0), vec2i(size) - 1), 0);
    gpufx_write(id, mix(b, a, sstep(0.0, 0.5, fp)));
}
