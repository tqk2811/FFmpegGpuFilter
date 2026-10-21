// Bright-pass of the incoming clip: keeps the highlights that will bloom.

// Glow keyframes on the transition clock: the glow pulses three times, each pulse a
// one-frame flare followed by a fade (knots in progress units, linear in between).
var<private> GLOW_T: array<f32, 7> = array<f32, 7>(0.1, 0.133333, 0.233333, 0.266667, 0.5, 0.533333, 1.0);
var<private> GLOW_THRESHOLD: array<f32, 7> = array<f32, 7>(1.0, 0.1, 1.0, 0.1, 1.0, 0.1, 1.0);

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

// Timeline position: progress maps straight onto the keyframed timeline.
fn clock() -> f32 {
    return clamp(params.progress, 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(second, smp, gpufx_uv(id), 0.0);
    let level = glow_key(&GLOW_THRESHOLD, clock());
    let lo = clamp(level, 0.01, 1.0);
    let bright = smoothstep(vec3f(lo - 0.075 * level), vec3f(lo + 0.115), c.rgb);
    gpufx_write(id, vec4f(pow(bright, vec3f(1.0 / 2.2)), c.a));
}
