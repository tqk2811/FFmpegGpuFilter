// Lays the glow over the scrambled frame (screen) and blurs the result horizontally for the unsharp mask.

// Unsharp-mask blur radius in output pixels; the Gaussian sigma is radius / 2.5.
const SHARP_RADIUS: f32 = 35.0;
const SHARP_TAPS: i32 = 31;

fn glowing(uv: vec2f) -> vec3f {
    let base = textureSampleLevel(warped, smp, uv, 0.0).rgb;
    let glow = textureSampleLevel(glow_a, smp, uv, 0.0).rgb;
    return 1.0 - (1.0 - base) * (1.0 - glow);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let radius = SHARP_RADIUS / globals.size.x;
    let sigma = radius / 2.5;
    let step = 2.0 * radius / f32(SHARP_TAPS - 1);
    var acc = vec3f(0.0);
    var total = 0.0;
    for (var i = 0; i < SHARP_TAPS; i++) {
        let off = -radius + f32(i) * step;
        let x = uv.x + off;
        // Taps that fall off the frame are left out, not clamped.
        if (x >= 0.0 && x <= 1.0) {
            let w = exp(-0.5 * off * off / (sigma * sigma));
            acc += w * glowing(vec2f(x, uv.y));
            total += w;
        }
    }
    gpufx_write(id, vec4f(acc / total, 1.0));
}
