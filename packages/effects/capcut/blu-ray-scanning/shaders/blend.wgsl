// Swaps the clips behind the depth sweep and lays the tinted, glowing blue scan line on top (alpha = line strength).

const PI: f32 = 3.1415926;
// How much the glow adds to the line.
const GLOW_GAIN: f32 = 2.0;

fn sweep() -> f32 { return clamp(params.progress, 0.0, 1.0); }

fn scan_line(far: f32) -> vec3f {
    let h = far * 0.7 + 0.3;
    let m = smoothstep(sweep(), sweep() + 0.3, h);
    let band = clamp(smoothstep(0.0, 0.5, m) - smoothstep(0.5, 1.0, m), 0.0, 1.0);
    return 0.4 * band * vec3f(0.0, 0.4, 1.0);
}

// Line plus glow at a point.
fn lit(p: vec2f) -> vec3f {
    let q = clamp(p, vec2f(0.0), vec2f(1.0));
    return scan_line(textureSampleLevel(depth, smp, q, 0.0).r) + GLOW_GAIN * textureSampleLevel(glow, smp, q, 0.0).rgb;
}

fn to_hsv(c: vec3f) -> vec3f {
    let hi = max(max(c.r, c.g), c.b);
    let lo = min(min(c.r, c.g), c.b);
    let d = hi - lo;
    var hsv = vec3f(0.0, 0.0, hi);
    if (hi > lo) {
        hsv.y = d / hi;
        if (c.r == hi) { hsv.x = (c.g - c.b) / d; } else if (c.g == hi) { hsv.x = 2.0 + (c.b - c.r) / d; } else { hsv.x = 4.0 + (c.r - c.g) / d; }
        hsv.x = fract(hsv.x / 6.0);
    }
    return hsv;
}

fn from_hsv(c: vec3f) -> vec3f {
    let p = abs(fract(c.xxx + vec3f(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(vec3f(1.0), clamp(p - 1.0, vec3f(0.0), vec3f(1.0)), c.y);
}

fn ease(x: f32) -> f32 { return x * x * (3.0 - 2.0 * x); }

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = sweep();

    // Shake envelope: quick rise over the first fifth, slower fall after.
    var env: f32;
    if (p < 0.2) { env = ease(p / 0.2); } else { let r = (1.0 - p) / 0.8; env = ease(r * r); }
    let shake = 0.01 * sin(p * PI * 15.0) * env;
    let tint_shake = 0.01 * sin(p * PI * 5.0) * env;

    let h = textureSampleLevel(depth, smp, uv, 0.0).r * 0.7 + 0.3;
    let lean = (h + 0.2) / 1.2;
    let m2 = smoothstep(p - 0.4, p + 0.6, h);
    let wave = clamp(smoothstep(0.0, 0.5, m2) - smoothstep(0.5, 1.0, m2), 0.0, 1.0);
    // Image-space offsets point right and down.
    let wobble = 4.0 * vec2f(lean, lean) * shake * wave;
    let fringe = 2.0 * vec2f(lean, lean) * abs(tint_shake) * wave;

    let behind = smoothstep(p, p + 0.3, h);
    let q = clamp(uv + wobble, vec2f(0.0), vec2f(1.0));
    let a = textureSampleLevel(first, smp, q, 0.0).rgb;
    let b = textureSampleLevel(second, smp, q, 0.0).rgb;
    let base = mix(b, a, behind);

    var line = from_hsv(to_hsv(lit(uv)) + vec3f(4.0 / 360.0, 0.22, 0.0)) * 1.6;
    line.r = 0.2 * lit(uv + 0.6 * fringe).b;
    line.g = mix(line.g, lit(uv + 0.9 * fringe).b, 0.2);
    let strength = line.r + line.g + line.b;
    gpufx_write(id, vec4f(base + 1.2 * line, clamp(strength, 0.0, 1.0)));
}
