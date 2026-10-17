// Signal Glitch 2, pass 8: brighten the blurred picture and screen the glow over it.

const FRAMES: f32 = 19.0;
const GAMMA: f32 = 2.2;
const SMOOTH = vec4f(0.33333333, 0.0, 0.66666667, 1.0);

fn bezier_axis(a: f32, b: f32, t: f32) -> f32 {
    let s = 1.0 - t;
    return 3.0 * a * s * s * t + 3.0 * b * s * t * t + t * t * t;
}

fn ease(c: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(c.x, c.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(c.y, c.w, 0.5 * (lo + hi));
}

fn key(f: f32, f0: f32, f1: f32, v0: f32, v1: f32, c: vec4f) -> f32 {
    return mix(v0, v1, ease(c, clamp((f - f0) / (f1 - f0), 0.0, 1.0)));
}

fn stops(f: f32) -> f32 {
    if (f < 2.0) { return 0.0; }
    if (f < 7.0) { return key(f, 2.0, 7.0, 0.0, 1.8, vec4f(0.33333333, 0.0, 0.846666598, 0.999999998)); }
    if (f < 11.0) { return key(f, 7.0, 11.0, 1.8, 2.001581, vec4f(0.124899062, -0.080575183, 0.496794385, 3.398546562)); }
    if (f < 19.0) { return key(f, 11.0, 19.0, 2.001581, 0.0, vec4f(0.277088557, 0.266028294, 0.713436483, 1.0)); }
    return 0.0;
}

// Strength of the glow.
fn glow_gain(f: f32) -> f32 {
    if (f < 2.0) { return 0.0; }
    if (f < 7.0) { return key(f, 2.0, 7.0, 0.0, 0.2, SMOOTH); }
    if (f < 11.0) { return key(f, 7.0, 11.0, 0.2, 0.6, SMOOTH); }
    if (f < 19.0) { return key(f, 11.0, 19.0, 0.6, 0.0, SMOOTH); }
    return 0.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let f = clamp(params.progress, 0.0, 1.0) * FRAMES;
    let c = textureSampleLevel(softened, smp, uv, 0.0).rgb;
    let base = clamp(pow(pow(c, vec3f(GAMMA)) * exp2(stops(f)), vec3f(1.0 / GAMMA)), vec3f(0.0), vec3f(1.0));
    let halo = textureSampleLevel(glow, smp, uv, 0.0).rgb * glow_gain(f);
    gpufx_write(id, vec4f(1.0 - (1.0 - base) * (1.0 - halo), 1.0));
}
