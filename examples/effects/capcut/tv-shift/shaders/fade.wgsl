// TV Shift, pass 1: the first clip fades out to black while the second fades in over it.
//
// `progress` 0..1 spans 2 s of scene time; the fade runs over 0.933..1.067 s.

const FADE_START: f32 = 0.933333;
const FADE_END: f32 = 1.066667;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * 2.0;
    let x = clamp((t - FADE_START) / (FADE_END - FADE_START), 0.0, 1.0);
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // Both layers carry their own opacity over a black background.
    gpufx_write(id, vec4f(b * x + a * (1.0 - x) * (1.0 - x), 1.0));
}
