// One step of the glow chain: the image is squared, screened with a coarse (downsampled) copy of itself and scaled by the exposure.

// Gamma the glow works in.
const GLOW_GAMMA: f32 = 2.0;

fn peak(p: f32) -> f32 {
    return 1.0 - abs(2.0 * p - 1.0);
}

// Coarse copy: average of a 2x2 group taken every `step` pixels, stretched back with bilinear filtering.
fn coarse(src: texture_2d<f32>, uv: vec2f, step: f32, squared: bool) -> vec3f {
    let grid = max(floor(globals.size / step), vec2f(1.0));
    let c = uv * grid - 0.5;
    let base = floor(c);
    let f = c - base;
    var acc = vec3f(0.0);
    for (var j = 0; j < 2; j++) {
        for (var i = 0; i < 2; i++) {
            let cell = clamp(base + vec2f(f32(i), f32(j)), vec2f(0.0), grid - 1.0);
            let w = select(1.0 - f.x, f.x, i == 1) * select(1.0 - f.y, f.y, j == 1);
            let v = textureSampleLevel(src, smp, (cell + 0.5) / grid, 0.0).rgb;
            acc += w * select(v, v * v, squared);
        }
    }
    return acc;
}

// `first_step` is true for the step that reads the frame itself (it is squared once more on the way in).
fn glow_step(id: vec3u, src: texture_2d<f32>, step: f32, index: f32, first_step: bool) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    var here = textureSampleLevel(src, smp, uv, 0.0).rgb;
    let low = coarse(src, uv, step, first_step);
    if (first_step) {
        here = pow(here, vec3f(GLOW_GAMMA));
    }
    // Weight of this step: falls off with the step number.
    let weight = GLOW_GAMMA / index * pow(0.05, 1.0 / 8.0);
    let a = pow(here, vec3f(GLOW_GAMMA));
    let b = pow(low, vec3f(GLOW_GAMMA));
    let screened = 1.0 - (1.0 - a) * (1.0 - b);
    let lit = (screened * weight + a * (1.0 - weight)) * peak(clamp(params.progress, 0.0, 1.0));
    gpufx_write(id, vec4f(clamp(pow(max(lit, vec3f(0.0)), vec3f(1.0 / GLOW_GAMMA)), vec3f(0.0), vec3f(1.0)), 1.0));
}

// Step 1 reads the scrambled frame.
@compute @workgroup_size(8, 8)
fn step_1(@builtin(global_invocation_id) id: vec3u) { glow_step(id, warped, 2.0, 1.0, true); }
