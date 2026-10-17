// Second step of the light blur where the ripple is strong, with the plain clips at the ends.

const STEP: vec2f = vec2f(0.0, 0.5 / 720.0);
// Side tap weights, nearest first, and the total they are divided by (slightly
// below their true sum, kept as in the original look: a faint brightening).
const WEIGHTS = array<f32, 4>(1.0, 0.923116, 0.83527, 0.726149);
const TOTAL: f32 = 7.929466;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    var w = WEIGHTS;
    let centre = textureSampleLevel(soft_x, smp, uv, 0.0);
    var acc = centre;
    for (var k = 0; k < 4; k++) {
        let o = STEP * f32(k + 1);
        acc += (textureSampleLevel(soft_x, smp, uv - o, 0.0) + textureSampleLevel(soft_x, smp, uv + o, 0.0)) * w[k];
    }
    gpufx_write(id, vec4f(mix(centre.rgb, acc.rgb / TOTAL, centre.a), 1.0));
}
