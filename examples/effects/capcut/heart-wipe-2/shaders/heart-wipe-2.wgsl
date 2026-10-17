// A heart with two faint echoes pops open over the first clip showing the second, wobbles, then swells to fill the frame.

// The heart animation runs this many frames, evenly over `progress` (24 frames per second over 2 s).
const FRAMES: i32 = 48;
// Opacity of each faint echo heart.
const ECHO_ALPHA: f32 = 0.2;
// Half the side of the square the heart distance field covers, in heart widths.
const FIELD_HALF: f32 = 0.8;
// Signed distance stored at the texture's black and white ends, in heart widths.
const FIELD_RANGE: f32 = 0.05;

// Per frame: heart centre x, y and width (units of the shorter frame side, from the frame centre),
// then each echo's x offset, y offset and width factor relative to the heart.
var<private> KEYS: array<array<f32, 9>, 48> = array<array<f32, 9>, 48>(
    array<f32, 9>(0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 1.0000, 0.0000, 0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0039, 0.1725, 0.0100, -0.0200, 0.9900, -0.0050, -0.0050, 0.9800),
    array<f32, 9>(0.0000, 0.0049, 0.3490, 0.0100, -0.0200, 0.9900, -0.0100, -0.0050, 1.0000),
    array<f32, 9>(0.0000, 0.0049, 0.5059, 0.0100, -0.0200, 0.9900, -0.0150, -0.0050, 0.9900),
    array<f32, 9>(0.0000, 0.0049, 0.6275, 0.0100, -0.0200, 0.9900, -0.0150, -0.0050, 1.0000),
    array<f32, 9>(0.0000, 0.0049, 0.6784, 0.0100, -0.0200, 1.0000, -0.0200, -0.0050, 0.9900),
    array<f32, 9>(0.0000, 0.0049, 0.6902, -0.0200, -0.0000, 1.0000, 0.0100, -0.0150, 1.0000),
    array<f32, 9>(-0.0010, 0.0049, 0.6961, -0.0200, -0.0050, 1.0000, 0.0150, -0.0150, 0.9900),
    array<f32, 9>(0.0000, 0.0059, 0.6980, -0.0200, -0.0000, 1.0000, 0.0100, -0.0150, 1.0000),
    array<f32, 9>(0.0000, 0.0059, 0.6941, -0.0200, -0.0000, 1.0000, 0.0150, -0.0150, 0.9900),
    array<f32, 9>(0.0000, 0.0049, 0.6863, -0.0200, -0.0050, 0.9900, 0.0150, -0.0150, 0.9900),
    array<f32, 9>(0.0000, 0.0049, 0.6784, -0.0200, -0.0050, 0.9900, 0.0100, -0.0100, 1.0000),
    array<f32, 9>(0.0000, 0.0049, 0.6706, -0.0200, -0.0050, 1.0000, 0.0150, -0.0100, 0.9900),
    array<f32, 9>(0.0000, 0.0059, 0.6667, -0.0250, -0.0050, 0.9900, 0.0100, -0.0100, 1.0000),
    array<f32, 9>(0.0000, 0.0059, 0.6667, -0.0250, -0.0050, 1.0000, 0.0100, -0.0100, 1.0000),
    array<f32, 9>(-0.0010, 0.0049, 0.6686, -0.0300, -0.0000, 0.9900, 0.0150, -0.0050, 1.0000),
    array<f32, 9>(0.0000, 0.0049, 0.6745, -0.0300, -0.0000, 1.0000, 0.0100, -0.0050, 1.0000),
    array<f32, 9>(0.0000, 0.0049, 0.6784, -0.0350, -0.0000, 0.9900, 0.0150, -0.0050, 0.9900),
    array<f32, 9>(0.0000, 0.0049, 0.6824, -0.0350, -0.0000, 0.9900, 0.0150, -0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0059, 0.6863, -0.0350, 0.0050, 1.0000, 0.0150, -0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0059, 0.6863, -0.0350, 0.0050, 1.0000, 0.0200, -0.0000, 0.9900),
    array<f32, 9>(0.0000, 0.0049, 0.6824, -0.0350, 0.0050, 1.0000, 0.0200, -0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0059, 0.6824, -0.0300, 0.0050, 1.0000, 0.0200, -0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0049, 0.6784, -0.0300, 0.0050, 1.0000, 0.0250, -0.0000, 0.9900),
    array<f32, 9>(0.0000, 0.0059, 0.6745, -0.0300, 0.0050, 0.9900, 0.0250, -0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0049, 0.6745, -0.0250, 0.0050, 1.0000, 0.0250, -0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0049, 0.6745, 0.0250, -0.0050, 1.0000, -0.0200, 0.0050, 1.0000),
    array<f32, 9>(0.0000, 0.0049, 0.6745, 0.0250, -0.0050, 1.0000, -0.0200, 0.0050, 1.0000),
    array<f32, 9>(-0.0010, 0.0059, 0.6765, 0.0300, -0.0050, 0.9800, -0.0150, 0.0050, 1.0000),
    array<f32, 9>(0.0000, 0.0049, 0.6784, 0.0200, -0.0050, 1.0000, -0.0150, 0.0050, 1.0000),
    array<f32, 9>(0.0000, 0.0059, 0.6784, 0.0200, -0.0050, 1.0000, -0.0150, -0.0000, 0.9900),
    array<f32, 9>(-0.0010, 0.0059, 0.6804, 0.0200, -0.0050, 0.9900, -0.0100, -0.0000, 0.9900),
    array<f32, 9>(-0.0010, 0.0059, 0.6804, 0.0150, -0.0050, 1.0000, 0.0100, -0.0050, 0.9900),
    array<f32, 9>(-0.0010, 0.0059, 0.6804, 0.0150, -0.0050, 0.9800, 0.0100, -0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0059, 0.6784, 0.0100, -0.0050, 0.9900, 0.0150, -0.0050, 0.9800),
    array<f32, 9>(0.0000, 0.0059, 0.6784, 0.0100, -0.0000, 1.0000, 0.0100, -0.0050, 0.9800),
    array<f32, 9>(0.0000, 0.0059, 0.6784, 0.0100, -0.0050, 0.9900, 0.0100, -0.0050, 0.9800),
    array<f32, 9>(-0.0010, 0.0059, 0.7824, 0.0100, -0.0000, 0.9900, 0.0150, -0.0050, 0.9800),
    array<f32, 9>(0.0000, 0.0059, 0.9686, 0.0150, -0.0050, 0.9900, 0.0100, -0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0050, 1.2430, 0.0000, 0.0000, 1.0000, 0.0000, 0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0050, 1.4810, 0.0000, 0.0000, 1.0000, 0.0000, 0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0050, 1.7330, 0.0000, 0.0000, 1.0000, 0.0000, 0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0050, 1.9720, 0.0000, 0.0000, 1.0000, 0.0000, 0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0050, 2.2860, 0.0000, 0.0000, 1.0000, 0.0000, 0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0050, 2.6200, 0.0000, 0.0000, 1.0000, 0.0000, 0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0050, 3.0000, 0.0000, 0.0000, 1.0000, 0.0000, 0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0050, 3.4500, 0.0000, 0.0000, 1.0000, 0.0000, 0.0000, 1.0000),
    array<f32, 9>(0.0000, 0.0050, 4.0000, 0.0000, 0.0000, 1.0000, 0.0000, 0.0000, 1.0000),
);

// Coverage (0..1) of one heart of width `w` centred at `c`, at point `p` (shorter-side units), anti-aliased over a pixel.
fn heart_cover(p: vec2f, c: vec2f, w: f32, px_per_unit: f32) -> f32 {
    if (w <= 0.0) { return 0.0; }
    let q = (p - c) / w;
    if (any(abs(q) >= vec2f(FIELD_HALF))) { return 0.0; }
    let tex = (q + FIELD_HALF) / (2.0 * FIELD_HALF);
    let v = textureSampleLevel(heart_sdf, smp, tex, 0.0).r;
    let dist_px = (v - 0.5) * 2.0 * FIELD_RANGE * w * px_per_unit;
    return clamp(0.5 - dist_px, 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    let frame = clamp(i32(floor(params.progress * f32(FRAMES) + 0.5)), 0, FRAMES - 1);
    // The last frame of the animation is the second clip everywhere.
    if (frame == FRAMES - 1) { gpufx_write(id, vec4f(b, 1.0)); return; }
    let k = KEYS[frame];
    let size = globals.size.xy;
    let unit = min(size.x, size.y);
    let p = (uv - 0.5) * size / unit;
    let c = vec2f(k[0], k[1]);
    let solid = heart_cover(p, c, k[2], unit);
    let echo1 = heart_cover(p, c + vec2f(k[3], k[4]), k[2] * k[5], unit);
    let echo2 = heart_cover(p, c + vec2f(k[6], k[7]), k[2] * k[8], unit);
    let hide = (1.0 - solid) * (1.0 - ECHO_ALPHA * echo1) * (1.0 - ECHO_ALPHA * echo2);
    gpufx_write(id, vec4f(mix(b, a, hide), 1.0));
}
