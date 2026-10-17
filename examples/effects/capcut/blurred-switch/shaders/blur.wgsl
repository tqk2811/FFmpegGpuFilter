// Horizontal gaussian blur of the shrunken dissolve, then the white/black strobe frames on top.

const TIMELINE: f32 = 1.99999;
// The strobe frames change at this rate on the animation clock.
const STROBE_FPS: f32 = 30.0;
const TAP_LIMIT: i32 = 128;

// Same keys as in reduce.wgsl.
fn blur_strength(t: f32) -> f32 {
    let times = array<f32, 7>(0.866667, 0.9, 0.933333, 0.966667, 1.0, 1.033333, 1.066667);
    let values = array<f32, 7>(0.0, 100.0, 200.0, 400.0, 200.0, 100.0, 0.0);
    var s = 0.0;
    for (var k = 0; k < 6; k++) {
        if (t >= times[k] && t < times[k + 1]) {
            s = mix(values[k], values[k + 1], (t - times[k]) / (times[k + 1] - times[k]));
        }
    }
    return s;
}

fn shrink_for(strength: f32) -> f32 {
    if (strength <= 10.0) { return 0.8; }
    if (strength <= 50.0) { return 0.7; }
    if (strength <= 200.0) { return 0.5; }
    return 0.25;
}

// Taps on each side of the centre for a given strength (grows slower for strong blurs).
fn taps_for(strength: f32) -> f32 {
    var n: f32;
    if (strength <= 10.0) {
        n = 0.8 * strength;
    } else if (strength <= 50.0) {
        n = (0.7 * strength + 2.0) * 0.78;
    } else if (strength <= 200.0) {
        n = (0.5 * strength + 10.0) * 0.66;
    } else {
        n = (0.25 * strength + 60.0) * 0.7;
    }
    if (n < 2.0) { n = floor(n + 0.5); }
    return n;
}

// Bilinear read of the shrunken copy (uv 0..1 over the copy), clamped to its edge texels.
fn shrunk(q: vec2f, grid: vec2f) -> vec4f {
    let texel = clamp(q * grid, vec2f(0.5), grid - 0.5);
    return textureSampleLevel(small, smp, texel / globals.size, 0.0);
}

// Strobe layer for animation frame `f`: straight colour + coverage.
// 24: white, 25: half-transparent white, 27/28: left half white (half, then full),
// 29/30: right half white (full, then half), 33: top half black, 34: bottom half black.
fn strobe(f: i32, uv: vec2f) -> vec4f {
    let left = uv.x < 0.5;
    let top = uv.y < 0.5;
    switch f {
        case 24: { return vec4f(1.0, 1.0, 1.0, 1.0); }
        case 25: { return vec4f(1.0, 1.0, 1.0, 0.5); }
        case 27: { return vec4f(1.0, 1.0, 1.0, select(0.0, 0.5, left)); }
        case 28: { return vec4f(1.0, 1.0, 1.0, select(0.0, 1.0, left)); }
        case 29: { return vec4f(1.0, 1.0, 1.0, select(1.0, 0.0, left)); }
        case 30: { return vec4f(1.0, 1.0, 1.0, select(0.5, 0.0, left)); }
        case 33: { return vec4f(0.0, 0.0, 0.0, select(0.0, 1.0, top)); }
        case 34: { return vec4f(0.0, 0.0, 0.0, select(1.0, 0.0, top)); }
        default: { return vec4f(0.0); }
    }
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * TIMELINE;

    let strength = blur_strength(t);
    let grid = max(floor(globals.size * shrink_for(strength)), vec2f(1.0));
    let taps = min(taps_for(strength), f32(TAP_LIMIT));
    var color = shrunk(uv, grid);
    if (taps >= 1e-5) {
        // Radius in units of a reference side (the shorter side, or half the longer one
        // if bigger), turned into uv along x. Gaussian sigma = radius / 3.
        let dims = globals.size;
        let reference = max(min(dims.x, dims.y), max(dims.x, dims.y) * 0.5);
        let radius = strength / 1000.0;
        let sigma = radius / 3.0;
        let step_x = radius / taps * reference / dims.x;
        var total = color;
        var weights = 1.0;
        for (var n = 1; n <= TAP_LIMIT; n++) {
            let k = f32(n);
            if (k > taps) { break; }
            let d = step_x * k;
            let w = exp(-0.5 * d * d / (sigma * sigma));
            // Taps outside the frame are dropped.
            if (uv.x - d >= 0.0) {
                total += shrunk(uv - vec2f(d, 0.0), grid) * w;
                weights += w;
            }
            if (uv.x + d <= 1.0) {
                total += shrunk(uv + vec2f(d, 0.0), grid) * w;
                weights += w;
            }
        }
        color = clamp(total / weights, vec4f(0.0), vec4f(1.0));
    }

    // Strobe frame shown at this time (each one is held for 1/30 s of animation time).
    let frame = i32(floor(t * STROBE_FPS + 0.5));
    let s = strobe(frame, uv);
    let rgb = s.rgb * s.a + color.rgb * (1.0 - s.a);
    gpufx_write(id, vec4f(rgb, 1.0));
}
