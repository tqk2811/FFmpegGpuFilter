// Rainbow-tinted bokeh lights strobe over a hard cut; the second clip starts brightened and settles back.

const SPAN: f32 = 1.26666667;      // animation length in seconds
const FPS: f32 = 30.0;
const CUT_AT: f32 = 0.53333333;    // the picture switches to the second clip here
const LIGHT_FRAMES: i32 = 38;
const FIELD_MEAN: f32 = 0.8;       // average of the raw bokeh field

// Average colour of the light layer for each of its frames.
const LIGHT_LEVEL: array<vec3f, 38> = array<vec3f, 38>(
    vec3f(0.0, 0.0, 0.0), vec3f(0.025, 0.016, 0.007), vec3f(0.066, 0.046, 0.027), vec3f(0.118, 0.086, 0.055),
    vec3f(0.167, 0.124, 0.077), vec3f(0.218, 0.164, 0.102), vec3f(0.256, 0.192, 0.119), vec3f(0.277, 0.209, 0.128),
    vec3f(0.286, 0.217, 0.135), vec3f(0.29, 0.222, 0.14), vec3f(0.31, 0.245, 0.16), vec3f(0.326, 0.263, 0.173),
    vec3f(0.343, 0.283, 0.19), vec3f(0.349, 0.304, 0.256), vec3f(0.343, 0.315, 0.281), vec3f(0.33, 0.371, 0.352),
    vec3f(0.37, 0.626, 0.583), vec3f(0.403, 0.416, 0.483), vec3f(0.454, 0.289, 0.346), vec3f(0.393, 0.263, 0.268),
    vec3f(0.322, 0.249, 0.226), vec3f(0.266, 0.215, 0.195), vec3f(0.195, 0.157, 0.133), vec3f(0.139, 0.111, 0.094),
    vec3f(0.103, 0.089, 0.07), vec3f(0.094, 0.086, 0.053), vec3f(0.083, 0.078, 0.048), vec3f(0.039, 0.033, 0.007),
    vec3f(0.031, 0.024, 0.005), vec3f(0.027, 0.02, 0.004), vec3f(0.023, 0.017, 0.003), vec3f(0.016, 0.012, 0.002),
    vec3f(0.014, 0.01, 0.002), vec3f(0.01, 0.007, 0.001), vec3f(0.006, 0.004, 0.001), vec3f(0.002, 0.001, 0.0),
    vec3f(0.0, 0.0, 0.0), vec3f(0.0, 0.0, 0.0),
);

// Brightening tone curve applied to luma (17 even steps from 0 to 1).
const LIFT: array<f32, 17> = array<f32, 17>(
    0.030, 0.152, 0.261, 0.377, 0.472, 0.558, 0.628, 0.692, 0.746,
    0.786, 0.824, 0.854, 0.882, 0.909, 0.949, 0.983, 0.987,
);

fn lift_curve(y: f32) -> f32 {
    let x = clamp(y, 0.0, 1.0) * 16.0;
    let i = min(i32(floor(x)), 15);
    return mix(LIFT[i], LIFT[i + 1], x - f32(i));
}

// Lifts shadows and mids while keeping each pixel's hue.
fn brighten(c: vec3f) -> vec3f {
    let y = dot(c, vec3f(0.299, 0.587, 0.114));
    if (y < 1e-4) { return vec3f(LIFT[0]); }
    return clamp(c * (lift_curve(y) / y), vec3f(0.0), vec3f(1.0));
}

fn hash_u(x: u32) -> u32 {
    var v = x * 747796405u + 2891336453u;
    v = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
    return (v >> 22u) ^ v;
}

fn rnd(cell: vec2i, salt: u32) -> f32 {
    let k = (bitcast<u32>(cell.x) * 0x9E3779B9u) ^ (bitcast<u32>(cell.y) * 0x85EBCA6Bu);
    return f32(hash_u(k + salt) & 0xFFFFu) / 65535.0;
}

fn hue(h: f32) -> vec3f {
    return clamp(abs(fract(h + vec3f(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, vec3f(0.0), vec3f(1.0));
}

// Soft out-of-focus discs of mixed colours, slowly swelling.
fn bokeh(q: vec2f, t: f32) -> vec3f {
    var acc = vec3f(0.08);
    for (var layer = 0u; layer < 2u; layer++) {
        let cell = select(0.22, 0.32, layer == 1u);
        let p = q / cell + f32(layer) * 0.37;
        let base = vec2i(floor(p));
        for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
                let c = base + vec2i(dx, dy);
                let centre = vec2f(c) + vec2f(rnd(c, layer * 9u), rnd(c, layer * 9u + 1u));
                let radius = (0.45 + 0.35 * rnd(c, layer * 9u + 2u)) * (0.8 + 0.4 * t);
                let d = length(p - centre) / radius;
                let disc = 1.0 - smoothstep(0.3, 1.0, d);
                let col = mix(hue(rnd(c, layer * 9u + 3u)), vec3f(1.0), 0.35);
                acc += col * disc * (0.3 + 0.5 * rnd(c, layer * 9u + 4u));
            }
        }
    }
    return acc;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(a, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(b, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let frame = clamp(i32(floor(t * FPS + 1e-4)), 0, LIGHT_FRAMES - 1);

    var col = a;
    if (frame >= i32(round(CUT_AT * FPS))) {
        let amount = mix(0.71, 0.0, clamp((t - 0.966667) / (1.1 - 0.966667), 0.0, 1.0));
        col = mix(b, brighten(b), amount);
    }

    let m = min(globals.size.x, globals.size.y);
    let q = (uv - 0.5) * globals.size / m;
    let light = clamp(LIGHT_LEVEL[frame] * bokeh(q, f32(frame) / f32(LIGHT_FRAMES)) / FIELD_MEAN, vec3f(0.0), vec3f(1.0));
    col = 1.0 - (1.0 - col) * (1.0 - light);
    gpufx_write(id, vec4f(col, 1.0));
}
