// Photon Portal, pass 3: vertical half of the highlight blur.

const TAP_GRID: f32 = 800.0;
const TAPS: i32 = 40;
const SPREAD: f32 = 253.125;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let stride = min(globals.size.x, globals.size.y) / TAP_GRID / globals.size.y;
    var sum = textureSampleLevel(glow_h, smp, uv, 0.0).rgb * 10.0;
    var total = 10.0;
    for (var i = 1; i <= TAPS; i++) {
        let d = f32(i);
        let w = exp(-d * d / SPREAD) * 10.0;
        let dn = uv.y + d * stride;
        let up = uv.y - d * stride;
        if (dn <= 1.0) { sum += textureSampleLevel(glow_h, smp, vec2f(uv.x, dn), 0.0).rgb * w; }
        if (up >= 0.0) { sum += textureSampleLevel(glow_h, smp, vec2f(uv.x, up), 0.0).rgb * w; }
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(sum / total, 1.0));
}
