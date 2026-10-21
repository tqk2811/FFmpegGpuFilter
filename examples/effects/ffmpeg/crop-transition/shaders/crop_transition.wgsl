// Port of FFmpeg's xfade circlecrop/rectcrop: the first clip is cropped to a shrinking
// circle/rectangle on `color`, then the second clip grows out of it.
// FFmpeg's progress runs 1 -> 0; here p = 1 - progress.
// rectcrop: FFmpeg's strict < on truncated sizes blanks the outer pixel ring even at the
// start and the end; <= on float sizes here keeps both endpoints exact.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    let bg = vec4f(params.color.rgb, 1.0);
    let w = globals.size.x;
    let h = globals.size.y;
    let cx = floor(w * 0.5);
    let cy = floor(h * 0.5);
    let dx = f32(id.x) - cx;
    let dy = f32(id.y) - cy;
    let p = 1.0 - params.progress;
    let s = abs(p - 0.5);
    var inside = false;
    if (params.shape == 0) {
        let z = pow(2.0 * s, 3.0) * length(vec2f(cx, cy));
        inside = length(vec2f(dx, dy)) <= z;
    } else {
        inside = abs(dx) <= s * w && abs(dy) <= s * h;
    }
    let clip = select(b, a, p >= 0.5);          // the first clip in the first half
    gpufx_write(id, select(bg, clip, inside));
}
