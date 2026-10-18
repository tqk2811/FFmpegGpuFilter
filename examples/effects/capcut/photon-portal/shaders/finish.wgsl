// Photon Portal, pass 4: add the glow on top while it swells and fades.

const SCENE: f32 = 1.033333;
const SOFT: vec4f = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

fn bezier_y(x: f32, k: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 16; n++) {
        let s = (lo + hi) * 0.5;
        let r = 1.0 - s;
        if (3.0 * r * r * s * k.x + 3.0 * r * s * s * k.z + s * s * s > x) { hi = s; } else { lo = s; }
    }
    let s = (lo + hi) * 0.5;
    let r = 1.0 - s;
    return 3.0 * r * r * s * k.y + 3.0 * r * s * s * k.w + s * s * s;
}

fn glow_gain(t: f32) -> f32 {
    if (t <= 0.133333 || t >= 0.433333) { return 0.0; }
    if (t < 0.266667) { return bezier_y((t - 0.133333) / 0.133334, SOFT); }
    return 1.0 - bezier_y((t - 0.266667) / 0.166666, SOFT);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends of the transition.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress * SCENE;
    let base = textureSampleLevel(scene, smp, uv, 0.0).rgb;
    let halo = textureSampleLevel(glow, smp, uv, 0.0).rgb * glow_gain(t);
    gpufx_write(id, vec4f(clamp(base + halo, vec3f(0.0), vec3f(1.0)), 1.0));
}
