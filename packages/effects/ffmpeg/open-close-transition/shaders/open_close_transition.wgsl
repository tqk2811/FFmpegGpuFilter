// Port of FFmpeg's xfade circleopen/circleclose, vertopen/vertclose, horzopen/horzclose.
// FFmpeg's progress runs 1 -> 0; here p = 1 - progress.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    let cx = floor(globals.size.x * 0.5);
    let cy = floor(globals.size.y * 0.5);
    let p = 1.0 - params.progress;
    var m = 0.0;                                // weight of the second clip
    if (params.shape == 0) {
        // Circle: distance to the center over the center-to-corner distance.
        let d = length(vec2f(f32(id.x) - cx, f32(id.y) - cy)) / length(vec2f(cx, cy));
        if (params.direction == 0) {
            m = 1.0 - smoothstep(0.0, 1.0, d + (p - 0.5) * 3.0);
        } else {
            m = smoothstep(0.0, 1.0, d + (1.0 - p - 0.5) * 3.0);
        }
    } else {
        // Vertical: |x| from the center line, horizontal: |y|.
        var d = 0.0;
        if (params.shape == 1) {
            let w2 = globals.size.x * 0.5;
            d = abs((f32(id.x) - w2) / w2);
        } else {
            let h2 = globals.size.y * 0.5;
            d = abs((f32(id.y) - h2) / h2);
        }
        if (params.direction == 0) {
            m = smoothstep(0.0, 1.0, 2.0 - d - p * 2.0);
        } else {
            m = smoothstep(0.0, 1.0, 1.0 + d - p * 2.0);
        }
    }
    gpufx_write(id, a * (1.0 - m) + b * m);
}
