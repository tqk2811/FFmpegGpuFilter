// Rough depth guess for the first clip: far over the upper quarter and towards the horizon and on bright areas (sky, sun), near at the bottom.

// Half-size of the luminance blur footprint (fraction of the frame).
const REACH: f32 = 0.08;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    var lum = 0.0;
    for (var j = -3; j <= 3; j++) {
        for (var i = -3; i <= 3; i++) {
            let p = clamp(uv + vec2f(f32(i), f32(j)) * (REACH / 3.0), vec2f(0.0), vec2f(1.0));
            lum += dot(textureSampleLevel(first, smp, p, 0.0).rgb, vec3f(0.299, 0.587, 0.114));
        }
    }
    lum /= 49.0;
    // 0 = nearest, 1 = farthest.
    let below = clamp((uv.y - 0.25) / 0.68, 0.0, 1.0);
    let far = clamp(1.0 - pow(below, 1.4) + 0.2 * (lum - 0.35), 0.0, 1.0);
    gpufx_write(id, vec4f(far, far, far, 1.0));
}
