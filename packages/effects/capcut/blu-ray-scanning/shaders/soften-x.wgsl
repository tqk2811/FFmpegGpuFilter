// First step of a light blur, applied where the ripple is strong.

const STEP: vec2f = vec2f(0.5 / 720.0, 0.0);
// Side tap weights, nearest first, and the total they are divided by (slightly
// below their true sum, kept as in the original look: a faint brightening).
const WEIGHTS = array<f32, 4>(1.0, 0.923116, 0.83527, 0.726149);
const TOTAL: f32 = 7.929466;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    var w = WEIGHTS;
    let centre = textureSampleLevel(displaced, smp, uv, 0.0);
    var acc = centre;
    for (var k = 0; k < 4; k++) {
        let o = STEP * f32(k + 1);
        acc += (textureSampleLevel(displaced, smp, uv - o, 0.0) + textureSampleLevel(displaced, smp, uv + o, 0.0)) * w[k];
    }
    gpufx_write(id, vec4f(mix(centre.rgb, acc.rgb / TOTAL, centre.a), centre.a));
}
