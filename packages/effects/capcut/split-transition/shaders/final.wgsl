// The outgoing clip splits down the middle and wipes away in two halves over a pulsing glow of the incoming clip.

// Glow keyframes on the transition clock (progress units, linear in between).
var<private> GLOW_T: array<f32, 7> = array<f32, 7>(0.1, 0.133333, 0.233333, 0.266667, 0.5, 0.533333, 1.0);
var<private> GLOW_GAIN: array<f32, 7> = array<f32, 7>(0.0, 2.28, 0.0, 2.28, 0.0, 2.49, 0.0);

fn glow_gain(t: f32) -> f32 {
    if (t <= GLOW_T[0]) { return GLOW_GAIN[0]; }
    for (var i = 1; i < 7; i++) {
        if (t <= GLOW_T[i]) {
            let k = (t - GLOW_T[i - 1]) / (GLOW_T[i] - GLOW_T[i - 1]);
            return mix(GLOW_GAIN[i - 1], GLOW_GAIN[i], k);
        }
    }
    return GLOW_GAIN[6];
}

// Wipe edge for a 0..1 wipe amount: 0 keeps the whole layer, 0.5 half of it, 1 none.
fn wipe_edge(amount: f32) -> f32 {
    return amount * 2.0 - 0.5;
}

// Outgoing clip: its left half goes in one frame at 0.1, its right half in one frame at 0.233.
fn first_amount(t: f32) -> f32 {
    if (t <= 0.1) { return 0.0; }
    if (t <= 0.133333) { return mix(0.0, 0.5, (t - 0.1) / 0.033333); }
    if (t <= 0.233333) { return 0.5; }
    if (t <= 0.266667) { return mix(0.5, 1.0, (t - 0.233333) / 0.033334); }
    return 1.0;
}

// Plain (unglowed) incoming clip on the left half, shown from 0.233 to 0.533.
fn second_amount(t: f32) -> f32 {
    if (t <= 0.233333) { return 1.0; }
    if (t <= 0.266667) { return mix(1.0, 0.5, (t - 0.233333) / 0.033334); }
    if (t <= 0.5) { return 0.5; }
    if (t <= 0.533333) { return mix(0.5, 1.0, (t - 0.5) / 0.033333); }
    return 1.0;
}

// Light wash laid over the picture, 30 steps over the transition. Per step, for the left
// half then the right half: colour = c0 + c1*d + c2*d^2 and opacity = a0 + a1*d + a2*d^2,
// with d the distance from the frame centre. Packed as 12 floats (3 vec4) per step.
var<private> WASH: array<vec4f, 90> = array<vec4f, 90>(
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000),
    vec4f(0.9996, -0.4240, 0.0216, 0.8506), vec4f(0.0565, -0.0032, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000),
    vec4f(1.0009, -0.4279, 0.0577, 0.6392), vec4f(0.0976, 0.0019, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.3638, -0.0004),
    vec4f(0.9996, -0.4255, 0.0886, 0.4232), vec4f(0.1061, -0.0009, 0.0000, 0.0000), vec4f(0.0000, -0.0005, 0.3253, -0.0004),
    vec4f(0.9989, -0.4179, 0.1017, 0.2119), vec4f(0.0728, -0.0034, 0.0000, 0.0000), vec4f(0.0000, -0.0005, 0.2912, -0.0005),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 1.0003, -0.3011), vec4f(0.0132, 0.8508, 0.0381, 0.0008),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.9999, -0.2797), vec4f(0.0143, 0.7647, 0.0505, 0.0009),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 1.0001, -0.2650), vec4f(0.0153, 0.6794, 0.0544, 0.0034),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.9998, -0.2459), vec4f(0.0214, 0.5962, 0.0580, 0.0024),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.9981, -0.2007), vec4f(0.0074, 0.5088, 0.0540, 0.0001),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.9994, -0.1662), vec4f(0.0035, 0.4235, 0.0416, 0.0016),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.9988, -0.0985), vec4f(0.0102, 0.3406, 0.0272, -0.0060),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 1.0000, 0.0000), vec4f(0.0000, 0.2549, 0.0000, 0.0000),
    vec4f(0.9996, -0.4241, 0.0218, 0.8506), vec4f(0.0565, -0.0032, 0.9994, -0.4117), vec4f(0.0164, 0.8748, 0.0454, 0.0002),
    vec4f(1.0007, -0.4438, 0.0470, 0.7296), vec4f(0.0862, 0.0021, 1.0000, -0.4279), vec4f(0.0392, 0.7524, 0.0809, 0.0002),
    vec4f(1.0008, -0.4767, 0.0780, 0.6074), vec4f(0.1154, -0.0013, 1.0008, -0.4769), vec4f(0.0782, 0.6074, 0.1154, -0.0013),
    vec4f(1.0002, -0.5240, 0.1200, 0.4880), vec4f(0.1207, 0.0132, 1.0002, -0.5242), vec4f(0.1204, 0.4879, 0.1209, 0.0130),
    vec4f(0.0000, 0.0000, 0.0000, -0.0004), vec4f(0.2171, -0.0005, 0.0000, 0.0000), vec4f(0.0000, -0.0004, 0.2170, -0.0003),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.1819, -0.0003, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.1818, -0.0001),
    vec4f(0.0000, 0.0000, 0.0000, -0.0002), vec4f(0.1481, 0.0000, 0.0000, 0.0000), vec4f(0.0000, -0.0002, 0.1482, 0.0000),
    vec4f(0.0000, 0.0000, 0.0000, -0.0001), vec4f(0.1084, -0.0001, 0.0000, 0.0000), vec4f(0.0000, -0.0001, 0.1084, -0.0001),
    vec4f(0.0000, 0.0000, 0.0000, -0.0001), vec4f(0.0741, 0.0001, 0.0000, 0.0000), vec4f(0.0000, -0.0001, 0.0741, 0.0001),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0339, 0.0004, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0338, 0.0004),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000),
    vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000), vec4f(0.0000, 0.0000, 0.0000, 0.0000)
);

fn wash_value(k: i32, base: i32, d: f32) -> vec2f {
    let i = k * 12 + base;
    let c = vec3f(WASH[i / 4][i % 4], WASH[(i + 1) / 4][(i + 1) % 4], WASH[(i + 2) / 4][(i + 2) % 4]);
    let a = vec3f(WASH[(i + 3) / 4][(i + 3) % 4], WASH[(i + 4) / 4][(i + 4) % 4], WASH[(i + 5) / 4][(i + 5) % 4]);
    let col = c.x + c.y * d + c.z * d * d;
    let alpha = a.x + a.y * d + a.z * d * d;
    return clamp(vec2f(col, alpha), vec2f(0.0), vec2f(1.0));
}

// Timeline position: progress maps straight onto the keyframed timeline.
fn clock() -> f32 {
    return clamp(params.progress, 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clock();

    // Incoming clip with the glow added on top.
    let incoming = textureSampleLevel(second, smp, uv, 0.0).rgb;
    var glow = textureSampleLevel(glow_v, smp, uv, 0.0) * glow_gain(t);
    if (glow.a > 1.0) { glow /= glow.a; }
    var color = min(incoming + glow.rgb, vec3f(1.0));

    // Plain incoming clip on the left of its wipe edge.
    if (1.0 - uv.x >= wipe_edge(second_amount(t))) { color = incoming; }
    // Outgoing clip on the right of its wipe edge.
    if (uv.x >= wipe_edge(first_amount(t))) { color = textureSampleLevel(first, smp, uv, 0.0).rgb; }

    // Wash, scaled to cover the frame without stretching.
    let k = clamp(i32(floor(t * 30.0 + 0.5)), 0, 29);
    let cover = globals.size / max(globals.size.x, globals.size.y);
    let d = length((uv - 0.5) * cover);
    var wash = wash_value(k, 0, d);
    if (uv.x >= 0.5) { wash = wash_value(k, 6, d); }
    color = mix(color, vec3f(wash.x), wash.y);
    gpufx_write(id, vec4f(color, 1.0));
}
