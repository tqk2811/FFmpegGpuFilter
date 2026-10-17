// Glow, first horizontal step: wide blur of the scan line, gated by the line's own brightness.

// Tap spacing (fraction of the frame) and gate threshold of this step.
const STEP: vec2f = vec2f(1,0) * (10.0 / 720.0);
const GATE: f32 = 0.5;
// Side tap weights, nearest first; the centre tap counts fully, the sum is not normalised.
const WEIGHTS = array<f32, 10>(0.0811, 0.076, 0.069, 0.06, 0.05, 0.04, 0.031, 0.023, 0.0163, 0.0111);

// Scan sweep position at this progress; a pixel lights up as the sweep crosses its depth.
fn sweep() -> f32 { return clamp(params.progress, 0.0, 1.0); }

// Blue line drawn where the sweep front crosses the pixel's depth, at 0.4 brightness.
fn scan_line(far: f32) -> vec3f {
    let h = far * 0.7 + 0.3;
    let m = smoothstep(sweep(), sweep() + 0.3, h);
    let band = clamp(smoothstep(0.0, 0.5, m) - smoothstep(0.5, 1.0, m), 0.0, 1.0);
    return 0.4 * band * vec3f(0.0, 0.4, 1.0);
}

fn fetch(p: vec2f) -> vec3f {
    return scan_line(textureSampleLevel(depth, smp, p, 0.0).r);
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
