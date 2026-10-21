// Brush Portal, pass 5: the second clip is painted in through the brush, its rim shows a glowing negative, and a light-leak wash is screened on top.

const SPAN: f32 = 2.0;
const FPS: f32 = 30.0;
const FIRST_ENDS: f32 = 1.7;         // the outgoing clip stops feeding the composite here
const LAST_FRAME: f32 = 1.9666667;   // from here the plain incoming clip is shown
const GLOW_GAIN: f32 = 0.3;
const LEAK_OPACITY: f32 = 0.7;
const LEAK_FIRST: f32 = 10.0;        // light leak visible on frames 10..39
const LEAK_LAST: f32 = 40.0;

// Average colour of the light leak per frame (frames 10..39) and how much brighter its top half is (top, bottom).
const LEAK_RGB = array<vec3f, 30>(
    vec3f(0.06, 0.07, 0.08), vec3f(0.08, 0.09, 0.10), vec3f(0.31, 0.18, 0.21), vec3f(0.32, 0.18, 0.22),
    vec3f(0.42, 0.23, 0.29), vec3f(0.37, 0.26, 0.38), vec3f(0.40, 0.36, 0.52), vec3f(0.41, 0.38, 0.54),
    vec3f(0.24, 0.33, 0.49), vec3f(0.34, 0.43, 0.58), vec3f(0.34, 0.42, 0.57), vec3f(0.29, 0.43, 0.55),
    vec3f(0.28, 0.41, 0.53), vec3f(0.30, 0.39, 0.49), vec3f(0.32, 0.41, 0.51), vec3f(0.30, 0.39, 0.48),
    vec3f(0.28, 0.37, 0.46), vec3f(0.40, 0.48, 0.57), vec3f(0.49, 0.45, 0.53), vec3f(0.51, 0.49, 0.64),
    vec3f(0.59, 0.56, 0.76), vec3f(0.48, 0.49, 0.70), vec3f(0.49, 0.50, 0.71), vec3f(0.47, 0.52, 0.71),
    vec3f(0.27, 0.40, 0.62), vec3f(0.25, 0.36, 0.57), vec3f(0.26, 0.35, 0.53), vec3f(0.27, 0.32, 0.45),
    vec3f(0.22, 0.31, 0.48), vec3f(0.24, 0.33, 0.48));
const LEAK_TILT = array<vec2f, 30>(
    vec2f(0.10, 0.04), vec2f(0.12, 0.06), vec2f(0.27, 0.20), vec2f(0.27, 0.21), vec2f(0.37, 0.26),
    vec2f(0.40, 0.27), vec2f(0.38, 0.47), vec2f(0.44, 0.45), vec2f(0.35, 0.36), vec2f(0.54, 0.35),
    vec2f(0.50, 0.38), vec2f(0.48, 0.37), vec2f(0.44, 0.38), vec2f(0.42, 0.37), vec2f(0.51, 0.31),
    vec2f(0.49, 0.29), vec2f(0.37, 0.36), vec2f(0.38, 0.59), vec2f(0.31, 0.67), vec2f(0.39, 0.70),
    vec2f(0.52, 0.76), vec2f(0.46, 0.65), vec2f(0.43, 0.69), vec2f(0.45, 0.69), vec2f(0.36, 0.50),
    vec2f(0.35, 0.44), vec2f(0.36, 0.40), vec2f(0.27, 0.42), vec2f(0.34, 0.34), vec2f(0.33, 0.37));

fn mix_hash(n: u32) -> u32 {
    var h = n * 747796405u + 2891336453u;
    h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
    return (h >> 22u) ^ h;
}

fn unit_hash(n: u32) -> f32 {
    return f32(mix_hash(n) & 0xffffu) / 65535.0;
}

// Soft out-of-focus light leak: the measured frame colour, shaped by a few drifting blurry blobs.
fn light_leak(uv: vec2f, f: f32) -> vec3f {
    let i = min(u32(clamp(f - LEAK_FIRST, 0.0, 29.0)), 29u);
    var rgb = LEAK_RGB;
    var tilt = LEAK_TILT;
    let base = rgb[i];
    let mean = max((base.r + base.g + base.b) / 3.0, 0.001);
    let tb = tilt[i];
    let shade = mix(tb.x, tb.y, uv.y) / mean;
    // A new set of blobs every 6 frames, each drifting slowly.
    let shot = u32(f / 6.0);
    let age = f / 6.0 - f32(shot);
    var spots = 0.0;
    for (var k = 0u; k < 4u; k++) {
        let seed = shot * 16u + k * 4u;
        let at = vec2f(unit_hash(seed), unit_hash(seed + 1u)) + (vec2f(unit_hash(seed + 2u), unit_hash(seed + 3u)) - 0.5) * 0.3 * age;
        let d = (uv - at) * vec2f(1.0, 0.56);
        spots += exp(-dot(d, d) / 0.012);
    }
    return clamp(base * shade * (0.7 + 0.3 * spots) + vec3f(0.35) * spots * mean, vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = params.progress;
    let incoming = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (p <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(p, 0.0, 1.0) * SPAN;
    if (p >= 1.0 || t >= LAST_FRAME) { gpufx_write(id, vec4f(incoming, 1.0)); return; }
    let f = t * FPS;

    let m = textureSampleLevel(masks, smp, uv, 0.0);
    var under = vec3f(0.0);
    if (t < FIRST_ENDS) { under = textureSampleLevel(first, smp, uv, 0.0).rgb; }
    let shown = mix(under, incoming, m.r);
    let glow = (1.0 - shown) + textureSampleLevel(glow_v, smp, uv, 0.0).rgb * GLOW_GAIN;
    var col = mix(shown, glow, m.g);
    if (f >= LEAK_FIRST && f < LEAK_LAST) {
        let leak = light_leak(uv, f);
        let screened = col + leak - col * leak;
        col = mix(col, screened, LEAK_OPACITY);
    }
    gpufx_write(id, vec4f(clamp(col, vec3f(0.0), vec3f(1.0)), 1.0));
}
