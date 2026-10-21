// Pass 2 of CRT 2 Digital: a weighted horizontal smear with split red/blue channels on the floor-bound copy.

const SPAN: f32 = 2.5;
const STEP: f32 = 0.0013888889;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let q = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let amount = 1.6 * clamp((t - 1.1) / 0.5, 0.0, 1.0);
    if (amount <= 0.0) {
        gpufx_write(id, textureSampleLevel(signal, smp, q, 0.0));
        return;
    }
    let stretch = min(5.0, amount * 2.0);
    let split = min(STEP * stretch, 2.0 * STEP);
    var acc = vec4f(0.0);
    var total = 0.0;
    for (var i = 0; i <= 10; i++) {
        let w = 10.0 - f32(i);
        let x = f32(i) * STEP * stretch;
        acc.r += w * textureSampleLevel(signal, smp, q + vec2f(x + split, 0.0), 0.0).r;
        let mid = textureSampleLevel(signal, smp, q + vec2f(x, 0.0), 0.0);
        acc.g += w * mid.g;
        acc.a += w * mid.a;
        acc.b += w * textureSampleLevel(signal, smp, q + vec2f(x - split, 0.0), 0.0).b;
        total += w;
    }
    acc /= total;
    gpufx_write(id, vec4f(clamp(acc.rgb, vec3f(0.0), vec3f(acc.a)), acc.a));
}
