// Vertical half of the gaussian blur that spreads the highlights into a glow.

// Glow keyframes on the transition clock: the glow pulses three times, each pulse a
// one-frame flare followed by a fade (knots in progress units, linear in between).
var<private> GLOW_T: array<f32, 7> = array<f32, 7>(0.1, 0.133333, 0.233333, 0.266667, 0.5, 0.533333, 1.0);
var<private> GLOW_RADIUS: array<f32, 7> = array<f32, 7>(0.0, 100.0, 0.0, 100.0, 0.0, 100.0, 0.0);

fn glow_key(values: ptr<private, array<f32, 7>>, t: f32) -> f32 {
    if (t <= GLOW_T[0]) { return (*values)[0]; }
    for (var i = 1; i < 7; i++) {
        if (t <= GLOW_T[i]) {
            let k = (t - GLOW_T[i - 1]) / (GLOW_T[i] - GLOW_T[i - 1]);
            return mix((*values)[i - 1], (*values)[i], k);
        }
    }
    return (*values)[6];
}

// Width of the gaussian relative to the radius.
const SIGMA: f32 = 4.0;

// Taps that fall outside the frame add nothing but still count in the weight sum,
// so the glow fades toward the borders.
fn tap(uv: vec2f) -> vec4f {
    let inside = step(0.0, uv.y) * step(uv.y, 1.0);
    return textureSampleLevel(glow_h, smp, uv, 0.0) * inside;
}

// Timeline position: progress maps straight onto the keyframed timeline.
fn clock() -> f32 {
    return clamp(params.progress, 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let radius = glow_key(&GLOW_RADIUS, clock());
    // One tap step is 1/800 of the shorter side.
    let step_uv = vec2f(0.0, 1.0) / (globals.size / min(globals.size.x, globals.size.y) * 800.0);
    var sum = textureSampleLevel(glow_h, smp, uv, 0.0) * 10.0;
    var total = 10.0;
    let spread = 2.0 * SIGMA * SIGMA * radius * radius / 100.0;
    let count = i32(floor(0.8 * radius));
    for (var i = 1; i <= count; i++) {
        let fi = f32(i);
        let w = exp(-fi * fi / spread) * 10.0;
        sum += (tap(uv + step_uv * fi) + tap(uv - step_uv * fi)) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, sum / total);
}
