fn sstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = globals.size;
    let d = params.direction;
    // Position along the sweep axis, 0..1 (FFmpeg's x / w, (w - 1 - x) / w and the same for y).
    var s: f32;
    if (d == 0) { s = f32(id.x) / size.x; }
    else if (d == 1) { s = (size.x - 1.0 - f32(id.x)) / size.x; }
    else if (d == 2) { s = f32(id.y) / size.y; }
    else { s = (size.y - 1.0 - f32(id.y)) / size.y; }
    // FFmpeg's progress is 1 on the first clip and 0 on the second.
    let fp = 1.0 - params.progress;
    let smooth_v = sstep(-0.5, 0.0, s - fp * 1.5);
    let ss = select(1.0, 0.0, smooth_v <= fract(10.0 * s));
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    gpufx_write(id, mix(a, b, ss));
}
