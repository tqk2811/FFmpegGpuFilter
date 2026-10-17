// An upward chevron edge sweeps from the bottom to the top, revealing the second clip, with two gold chevron stripes riding behind it.

// The animation spans 2 s of comp time, sampled from a 25 fps reference; progress 1 = frame 50.
const FRAMES_PER_PROGRESS: f32 = 50.0;
// The table below starts at reference frame 10.
const TABLE_START: f32 = 10.0;
// Slope of the chevron flanks (vertical units per horizontal unit, both in screen-height units).
const FLANK_SLOPE: f32 = 0.4835;
// Stripe colour (opaque).
const STRIPE_COLOR: vec3f = vec3f(0.9608, 0.8275, 0.5451);

// Height (fraction of the reference frame, measured from the top) of the chevron tip for
// frames 10..35, landscape layout (16:9 reference).
const TIP_WIDE = array<f32, 26>(
    1.0, 0.992, 0.9678, 0.9287, 0.8763, 0.8122, 0.7376, 0.654, 0.5628, 0.4651,
    0.3627, 0.2568, 0.1488, 0.04, -0.068, -0.1738, -0.2763, -0.3738, -0.4654, -0.549,
    -0.6238, -0.6875, -0.74, -0.779, -0.805, -0.83);
// Same for the square layout (1:1 reference), used for square and portrait frames.
const TIP_SQUARE = array<f32, 26>(
    1.0, 0.994, 0.9741, 0.9426, 0.9006, 0.849, 0.7891, 0.7219, 0.6485, 0.5701,
    0.4879, 0.4026, 0.316, 0.2286, 0.1418, 0.0567, -0.0257, -0.104, -0.1774, -0.2457,
    -0.3056, -0.357, -0.3995, -0.429, -0.449, -0.465);

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(a, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(b, 1.0)); return; }

    let ratio = globals.size.x * globals.pixel_aspect / globals.size.y;
    let wide = ratio >= 1.3333;
    // Reference layout aspect; it is scaled to cover the frame, centred.
    let ref_ratio = select(1.0, 16.0 / 9.0, wide);
    var pos: vec2f;
    var unit: f32; // reference-height units per output pixel row
    if (ratio >= ref_ratio) {
        pos = vec2f((uv.x - 0.5) * ref_ratio, 0.5 + (uv.y - 0.5) * ref_ratio / ratio);
        unit = ref_ratio / ratio / globals.size.y;
    } else {
        pos = vec2f((uv.x - 0.5) * ratio, uv.y);
        unit = 1.0 / globals.size.y;
    }

    let frame = clamp(params.progress, 0.0, 1.0) * FRAMES_PER_PROGRESS;
    // Nothing is revealed before the wipe starts.
    if (frame <= TABLE_START) { gpufx_write(id, vec4f(a, 1.0)); return; }
    let f = min(frame - TABLE_START, 25.0);
    let i = min(u32(floor(f)), 24u);
    let w = f - f32(i);
    var tip: f32;
    if (wide) { tip = mix(TIP_WIDE[i], TIP_WIDE[i + 1u], w); }
    else { tip = mix(TIP_SQUARE[i], TIP_SQUARE[i + 1u], w); }
    // Stripe thickness and spacing scale with the reference width.
    let thick = select(0.04395, 0.078125, wide);
    let gap = select(0.1719, 0.3047, wide);

    // Signed depth below the chevron edge; positive = already revealed.
    let depth = pos.y - (tip + FLANK_SLOPE * abs(pos.x));
    let aa = unit * 0.75;
    let reveal = smoothstep(-aa, aa, depth);
    var col = mix(a, b, reveal);
    let s1 = smoothstep(-aa, aa, depth) * (1.0 - smoothstep(thick - aa, thick + aa, depth));
    let s2 = smoothstep(gap - aa, gap + aa, depth) * (1.0 - smoothstep(gap + thick - aa, gap + thick + aa, depth));
    col = mix(col, STRIPE_COLOR, clamp(s1 + s2, 0.0, 1.0));
    gpufx_write(id, vec4f(col, 1.0));
}
