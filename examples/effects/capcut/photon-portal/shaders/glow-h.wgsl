// Photon Portal, pass 2: keep the bright parts of the scene and blur them horizontally.
//
// One blur tap spans short_side / 800 pixels; 40 taps per side, Gaussian weights with
// sigma 2.25 at radius 50 (2 * 2.25^2 * 50^2 / 100 = 253.125).

const TAP_GRID: f32 = 800.0;
const TAPS: i32 = 40;
const SPREAD: f32 = 253.125;

fn highlights(q: vec2f) -> vec3f {
    let c = textureSampleLevel(scene, smp, q, 0.0).rgb;
    let k = smoothstep(vec3f(0.555), vec3f(0.715), c);
    return pow(k, vec3f(0.4545454));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let stride = min(globals.size.x, globals.size.y) / TAP_GRID / globals.size.x;
    var sum = highlights(uv) * 10.0;
    var total = 10.0;
    for (var i = 1; i <= TAPS; i++) {
        let d = f32(i);
        let w = exp(-d * d / SPREAD) * 10.0;
        let rx = uv.x + d * stride;
        let lx = uv.x - d * stride;
        if (rx <= 1.0) { sum += highlights(vec2f(rx, uv.y)) * w; }
        if (lx >= 0.0) { sum += highlights(vec2f(lx, uv.y)) * w; }
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(sum / total, 1.0));
}
