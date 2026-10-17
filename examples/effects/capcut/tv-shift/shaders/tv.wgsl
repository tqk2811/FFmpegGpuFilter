// TV Shift, pass 2: desaturate, overlay flickering dark TV scanlines, then a vertical gaussian smear across the fade.
//
// Scene time is progress * 2 s. Saturation drops to 60% over 0.3..0.433 s and returns by
// 0.933 s; the scanlines (about 76 lines per frame height, a 30 fps animation) show from
// frame 10 to 25; the vertical blur strength ramps 0 -> 400 -> 0 over 0.867..1.067 s.

const PI: f32 = 3.14159265;
const LINES_PER_HEIGHT: f32 = 76.2195;  // 500 / 6.56
const LINE_PHASE: f32 = 2.2;
const LINE_SHADE: f32 = 0.035;
const LUMA: vec3f = vec3f(0.20854, 0.702086, 0.089374);

// Peak scanline opacity of each animation frame 10..25.
const LINE_ALPHA = array<f32, 16>(0.059, 0.207, 0.351, 0.494, 0.536, 0.544, 0.555, 0.567,
    0.575, 0.587, 0.599, 0.606, 0.618, 0.573, 0.317, 0.055);

// Piecewise-linear value through (time, value) keys.
fn blur_strength(t: f32) -> f32 {
    let keys = array<vec2f, 7>(vec2f(0.866667, 0.0), vec2f(0.9, 100.0), vec2f(0.933333, 200.0),
        vec2f(0.966667, 400.0), vec2f(1.0, 200.0), vec2f(1.033333, 100.0), vec2f(1.066667, 0.0));
    if (t <= keys[0].x || t >= keys[6].x) { return 0.0; }
    var v = 0.0;
    for (var i = 0; i < 6; i++) {
        if (t >= keys[i].x && t < keys[i + 1].x) {
            v = mix(keys[i].y, keys[i + 1].y, (t - keys[i].x) / (keys[i + 1].x - keys[i].x));
        }
    }
    return v;
}

fn saturation_shift(t: f32) -> f32 {
    if (t < 0.3 || t >= 0.933333) { return 0.0; }
    if (t < 0.433333) { return -0.4 * (t - 0.3) / 0.133333; }
    if (t < 0.866667) { return -0.4; }
    return -0.4 * (1.0 - (t - 0.866667) / 0.066666);
}

// Tap count for a blur strength, as tiers that trade taps for range.
fn tap_count(s: f32) -> f32 {
    var n: f32;
    if (s <= 10.0) { n = 0.8 * s; }
    else if (s <= 50.0) { n = (0.7 * s + 2.0) * 0.78; }
    else if (s <= 200.0) { n = (0.5 * s + 10.0) * 0.66; }
    else { n = (0.25 * s + 60.0) * 0.7; }
    if (n < 2.0) { n = floor(n + 0.5); }
    return n;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = params.progress;
    // Exact clips at the ends, so the cut in and out is seamless.
    if (p <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (p >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = p * 2.0;

    var colour = textureSampleLevel(mixed, smp, uv, 0.0).rgb;
    let strength = blur_strength(t);
    let taps = tap_count(strength);
    if (taps > 1e-5) {
        let dims = vec2f(globals.size);
        let base = max(min(dims.x, dims.y), max(dims.x, dims.y) * 0.5);
        let radius = strength / 1000.0;
        let sigma = radius / 3.0;
        let step = radius / taps * base / dims.y;
        var acc = colour;
        var total = 1.0;
        for (var i = 1; i <= 128; i++) {
            let fi = f32(i);
            if (fi > taps) { break; }
            let d = step * fi;
            let w = exp(-0.5 * d * d / (sigma * sigma));
            let up = uv.y - d;
            let down = uv.y + d;
            if (up >= 0.0) {
                acc += textureSampleLevel(mixed, smp, vec2f(uv.x, up), 0.0).rgb * w;
                total += w;
            }
            if (down <= 1.0) {
                acc += textureSampleLevel(mixed, smp, vec2f(uv.x, down), 0.0).rgb * w;
                total += w;
            }
        }
        colour = clamp(acc / total, vec3f(0.0), vec3f(1.0));
    }

    let k = saturation_shift(t) + 1.0;
    let grey = LUMA * (1.0 - k);
    colour = clamp(vec3f(dot(colour, grey + vec3f(k, 0.0, 0.0)), dot(colour, grey + vec3f(0.0, k, 0.0)),
        dot(colour, grey + vec3f(0.0, 0.0, k))), vec3f(0.0), vec3f(1.0));

    let frame = i32(floor(t * 30.0)) - 10;
    if (frame >= 0 && frame < 16) {
        let wave = 0.5 + 0.5 * cos(2.0 * PI * (uv.y * LINES_PER_HEIGHT * 6.56 - LINE_PHASE) / 6.56);
        colour = mix(colour, vec3f(LINE_SHADE), LINE_ALPHA[frame] * wave);
    }
    gpufx_write(id, vec4f(colour, 1.0));
}
