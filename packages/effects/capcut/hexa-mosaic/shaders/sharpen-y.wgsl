// Finishes the unsharp mask with the vertical blur and sharpens the glowing frame by it.

const SHARP_RADIUS: f32 = 35.0;
const SHARP_TAPS: i32 = 31;
// Strongest sharpening, reached at the midpoint.
const SHARP_PEAK: f32 = 0.35;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = clamp(params.progress, 0.0, 1.0);
    // Exact clips at the ends of the transition.
    if (p <= 0.0) {
        gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    if (p >= 1.0) {
        gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    let base = textureSampleLevel(warped, smp, uv, 0.0).rgb;
    let glow = textureSampleLevel(glow_a, smp, uv, 0.0).rgb;
    let sharp_in = 1.0 - (1.0 - base) * (1.0 - glow);
    let radius = SHARP_RADIUS / globals.size.y;
    let sigma = radius / 2.5;
    let step = 2.0 * radius / f32(SHARP_TAPS - 1);
    var acc = vec3f(0.0);
    var total = 0.0;
    for (var i = 0; i < SHARP_TAPS; i++) {
        let off = -radius + f32(i) * step;
        let y = uv.y + off;
        if (y >= 0.0 && y <= 1.0) {
            let w = exp(-0.5 * off * off / (sigma * sigma));
            acc += w * textureSampleLevel(blur_x, smp, vec2f(uv.x, y), 0.0).rgb;
            total += w;
        }
    }
    let detail = sharp_in - acc / total;
    // A zero threshold sharpens every pixel that differs from its blur.
    let amount = SHARP_PEAK * (1.0 - abs(2.0 * p - 1.0));
    gpufx_write(id, vec4f(clamp(sharp_in + amount * detail, vec3f(0.0), vec3f(1.0)), 1.0));
}
