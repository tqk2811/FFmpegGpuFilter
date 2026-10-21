// Angle Swap, last pass: screen the vertical glint streaks on as well.

// 0 -> 1 -> 0 triangle peaking at the cut, with a cubic ease-out.
fn peak(t: f32) -> f32 {
    let tri = select(2.0 - 2.0 * t, 2.0 * t, t < 0.5);
    let r = 1.0 - clamp(tri, 0.0, 1.0);
    return 1.0 - r * r * r;
}

const BOOST = array<f32, 6>(3.75, 3.75, 2.5, 2.5, 2.0, 2.0);

fn screen(a: vec3f, b: vec3f) -> vec3f {
    return 1.0 - (1.0 - a) * (1.0 - b);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0);
    let gain = mix(2.0, 1.0, 0.18 * peak(t));
    var layers: array<vec3f, 6>;
    layers[0] = clamp(clamp(textureSampleLevel(streak_y0, smp, uv, 0.0).rgb, vec3f(0.0), vec3f(1.0)) * gain * BOOST[0], vec3f(0.0), vec3f(1.0));
    layers[1] = clamp(clamp(textureSampleLevel(streak_y1, smp, uv, 0.0).rgb, vec3f(0.0), vec3f(1.0)) * gain * BOOST[1], vec3f(0.0), vec3f(1.0));
    layers[2] = clamp(clamp(textureSampleLevel(streak_y2, smp, uv, 0.0).rgb, vec3f(0.0), vec3f(1.0)) * gain * BOOST[2], vec3f(0.0), vec3f(1.0));
    layers[3] = clamp(clamp(textureSampleLevel(streak_y3, smp, uv, 0.0).rgb, vec3f(0.0), vec3f(1.0)) * gain * BOOST[3], vec3f(0.0), vec3f(1.0));
    layers[4] = clamp(clamp(textureSampleLevel(streak_y4, smp, uv, 0.0).rgb, vec3f(0.0), vec3f(1.0)) * gain * BOOST[4], vec3f(0.0), vec3f(1.0));
    layers[5] = clamp(clamp(textureSampleLevel(streak_y5, smp, uv, 0.0).rgb, vec3f(0.0), vec3f(1.0)) * gain * BOOST[5], vec3f(0.0), vec3f(1.0));
    var c = textureSampleLevel(streaked_x, smp, uv, 0.0).rgb;
    // Every streak level is screened on three times over.
    for (var round = 0; round < 3; round++) {
        for (var k = 0; k < 6; k++) {
            c = screen(c, layers[k]);
        }
    }
    gpufx_write(id, vec4f(c, 1.0));
}
