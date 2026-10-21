// Brush Portal, pass 4: Gaussian blur of the highlights along y (radius 50, sigma 2.25, steps of 1/800 of the short side).

const RADIUS: f32 = 50.0;
const SIGMA: f32 = 2.25;
const STEPS_PER_SIDE: f32 = 800.0;
const TAPS: i32 = 40; // 8 * RADIUS / 10

fn tap(q: vec2f) -> vec4f {
    if (q.x < 0.0 || q.x > 1.0 || q.y < 0.0 || q.y > 1.0) { return vec4f(0.0); }
    return textureSampleLevel(blur_h, smp, q, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let stride = vec2f(0.0, 1.0) / (globals.size / min(globals.size.x, globals.size.y) * STEPS_PER_SIDE);
    let spread = 2.0 * SIGMA * SIGMA * RADIUS * RADIUS / 100.0;
    var sum = tap(uv) * 10.0;
    var total = 10.0;
    for (var i = 1; i <= TAPS; i++) {
        let d = f32(i);
        let w = exp(-d * d / spread) * 10.0;
        sum += (tap(uv + stride * d) + tap(uv - stride * d)) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, sum / total);
}
