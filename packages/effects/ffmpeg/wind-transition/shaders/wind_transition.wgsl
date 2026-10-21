fn sstep_rev(x: f32) -> f32 {
    // FFmpeg's smoothstep(0, -0.2, x).
    let t = clamp(x / -0.2, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = globals.size;
    let d = params.direction;
    var f: f32;
    var r: f32;
    if (d < 2) {
        let v = sin(f32(id.y) * 78.233) * 43758.545;
        r = v - floor(v);
        f = f32(id.x) / size.x;
    } else {
        let v = sin(f32(id.x) * 12.9898) * 43758.545;
        r = v - floor(v);
        f = f32(id.y) / size.y;
    }
    if (d == 0 || d == 2) { f = 1.0 - f; }
    // FFmpeg's (1 - progress) is the `progress` of this effect.
    let m = sstep_rev(f * (1.0 - 0.2) + 0.2 * r - params.progress * (1.0 + 0.2));
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    gpufx_write(id, mix(a, b, m));
}
