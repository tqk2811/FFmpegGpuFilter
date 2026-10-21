// Tremor, pass 1: the outgoing clip picks up a growing vertical motion blur just before the cut.

const T0: f32 = 0.166667;   // the animation runs from 0.166667 s to 1.9 s
const T1: f32 = 1.9;
const SIGMA: f32 = 4.0;

fn bell(x: f32) -> f32 {
    return 0.39894 * exp(-0.5 * x * x / (SIGMA * SIGMA)) / SIGMA;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = mix(T0, T1, clamp(params.progress, 0.0, 1.0));
    let n = floor(mix(0.0, 17.0, clamp((t - 1.0) / 0.266667, 0.0, 1.0)));
    let centre = textureSampleLevel(first, smp, uv, 0.0);
    if (n < 1.0) {
        gpufx_write(id, centre);
        return;
    }
    // One tap is 1/720 of the shorter side.
    let step_y = min(globals.size.x, globals.size.y) / (720.0 * globals.size.y);
    var w = bell(0.0);
    var sum = centre * w;
    var total = w;
    for (var i = 1; i <= 17; i++) {
        let k = f32(i);
        if (k > n) { break; }
        w = bell(k / n * 15.0);
        sum += (textureSampleLevel(first, smp, uv + vec2f(0.0, k * step_y), 0.0)
              + textureSampleLevel(first, smp, uv - vec2f(0.0, k * step_y), 0.0)) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, clamp(sum / total, vec4f(0.0), vec4f(1.0)));
}
