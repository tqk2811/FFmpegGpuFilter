// Glow, a further separable step of the wide un-normalised blur (direction 1,0, gate threshold 0.0).

// Tap spacing (fraction of the frame) and gate threshold of this step.
const STEP: vec2f = vec2f(1,0) * (10.0 / 720.0);
const GATE: f32 = 0.0;
// Side tap weights, nearest first; the centre tap counts fully, the sum is not normalised.
const WEIGHTS = array<f32, 10>(0.0811, 0.076, 0.069, 0.06, 0.05, 0.04, 0.031, 0.023, 0.0163, 0.0111);

fn fetch(p: vec2f) -> vec3f {
    return textureSampleLevel(glow_b, smp, p, 0.0).rgb;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    var w = WEIGHTS;
    let centre = fetch(uv);
    var acc = centre;
    for (var k = 0; k < 10; k++) {
        let o = STEP * f32(k + 1);
        acc += (fetch(clamp(uv - o, vec2f(0.0), vec2f(1.0))) + fetch(clamp(uv + o, vec2f(0.0), vec2f(1.0)))) * w[k];
    }
    let gate = smoothstep(GATE - 0.5, GATE, dot(centre, vec3f(0.299, 0.587, 0.114)));
    gpufx_write(id, vec4f(acc * gate, 1.0));
}
