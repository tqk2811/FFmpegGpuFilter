// Ripples the image with an animated turbulence near the sweep front and splits red/green there.

// The noise pattern changes once per frame of a 1.4667 s transition at 30 fps.
const FRAMES: f32 = 44.0;

fn sweep() -> f32 { return clamp(params.progress, 0.0, 1.0); }

fn mirror(p: vec2f) -> vec2f {
    let m = p - 2.0 * floor(p * 0.5);
    return clamp(select(m, 2.0 - m, m > vec2f(1.0)), vec2f(0.0), vec2f(1.0));
}

fn hash3(p: vec3f) -> f32 {
    var q = fract(p * vec3f(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn value_noise(p: vec3f) -> f32 {
    let i = floor(p);
    let f = p - i;
    let w = f * f * (3.0 - 2.0 * f);
    let n00 = mix(hash3(i), hash3(i + vec3f(1.0, 0.0, 0.0)), w.x);
    let n10 = mix(hash3(i + vec3f(0.0, 1.0, 0.0)), hash3(i + vec3f(1.0, 1.0, 0.0)), w.x);
    let n01 = mix(hash3(i + vec3f(0.0, 0.0, 1.0)), hash3(i + vec3f(1.0, 0.0, 1.0)), w.x);
    let n11 = mix(hash3(i + vec3f(0.0, 1.0, 1.0)), hash3(i + vec3f(1.0, 1.0, 1.0)), w.x);
    return mix(mix(n00, n10, w.y), mix(n01, n11, w.y), w.z);
}

// Grey turbulence in [0, 1] standing in for a displacement map, a new pattern each frame.
fn turbulence(q: vec2f, frame: f32) -> f32 {
    var sum = 0.0;
    var amp = 0.5;
    var s = vec3f(q * 4.0, frame * 0.37);
    for (var o = 0; o < 4; o++) {
        sum += amp * value_noise(s);
        s = vec3f(s.xy * 2.03 + 1.7, s.z * 1.3);
        amp *= 0.5;
    }
    return clamp((sum / 0.9375 - 0.5) * 1.3 + 0.42, 0.0, 1.0);
}

fn ease(x: f32) -> f32 { return x * x * (3.0 - 2.0 * x); }

fn bump(m: f32) -> f32 { return clamp(smoothstep(0.0, 0.5, m) - smoothstep(0.5, 1.0, m), 0.0, 1.0); }

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = sweep();

    // Ripple fades out over the second half and is gone by 95 %.
    var fade = 1.0;
    if (p > 0.5) {
        fade = ease((1.0 - p) / 0.5);
        if (p > 0.8) { fade *= fade; }
        if (p > 0.95) { fade = 0.0; }
    }

    let h = textureSampleLevel(depth, smp, uv, 0.0).r * 0.7 + 0.3;
    let near_front = bump(smoothstep(p - 0.18, p + 0.24, h));

    // Map coordinates: frame fitted by its short side, flipped, shrunk by 1.3, turning with progress.
    let aspect = globals.size / min(globals.size.x, globals.size.y);
    var q = (uv - 0.5) * aspect;
    q.y = -q.y;
    let ang = 3.0 * p * 0.785;
    let cs = cos(ang);
    let sn = sin(ang);
    q = vec2f(q.x * cs + q.y * sn, -q.x * sn + q.y * cs) / 1.3 + 0.5;
    let frame = floor(p * FRAMES + 0.5);
    let n = turbulence(mirror(2.0 * q), frame) * 2.0 - 1.0;
    // Same nudge on both axes (right and up).
    let offset = vec2f(0.05 * n, -0.05 * n);

    let amount = near_front * fade;
    var c = textureSampleLevel(blended, smp, mirror(uv + offset * amount), 0.0).rgb;

    let front = bump(smoothstep(p, p + 0.3, h));
    let ahead = step(p + 0.12, h);
    let scatter = (smoothstep(0.0, 0.4, front) - smoothstep(0.4, 0.8, front)) * ahead;
    let red = textureSampleLevel(blended, smp, mirror(uv + 2.01 * offset * scatter), 0.0).b;
    let green = textureSampleLevel(blended, smp, mirror(uv - 3.015 * offset * scatter), 0.0).b;
    c.r = mix(c.r, red, 0.3 * scatter);
    c.g = mix(c.g, green, 0.3 * scatter);
    gpufx_write(id, vec4f(c, amount));
}
