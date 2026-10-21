// Dispersion Trail, passes 1-2: keep the bright part of the glowing clip and blur it horizontally (red+green, then blue).
//
// The blur works on a grid at most GRID cells wide. Red, green and blue use radii of 1, 1.2 and 1.4
// times WIDTH of the grid width, for a coloured fringe. Each 0..1 result is stored as two bytes
// (coarse + fine) so the strong gain applied later does not show 8-bit banding.

const SPAN: f32 = 2.13333333;      // animation length in seconds
const SWITCH_AT: f32 = 1.0;        // before this the first clip glows, after it the second
const GRID: f32 = 240.0;
const WIDTH: f32 = 0.1;
const SPREAD = vec3f(1.0, 1.2, 1.4);
const MAX_TAPS: f32 = 30.0;
const DITHER: f32 = 1.0;

fn lin(t: f32, t0: f32, t1: f32, v0: f32, v1: f32) -> f32 {
    return mix(v0, v1, clamp((t - t0) / (t1 - t0), 0.0, 1.0));
}

fn cut_level(t: f32) -> f32 {
    if (t < SWITCH_AT) { return 0.58; }
    return lin(t, 1.533333, 2.1, 0.04, 1.0);
}

fn over_cut(v: f32, cut: f32) -> f32 {
    if (v <= cut) { return 0.0; }
    return (v - cut) / max(1.0 - cut, 1e-6);
}

// Bright part of the source: the pixel scaled by how far its channels rise over the cut level.
fn bright(q: vec2f, t: f32, cut: f32) -> vec3f {
    var c: vec3f;
    if (t < SWITCH_AT) { c = textureSampleLevel(first, smp, q, 0.0).rgb; }
    else { c = textureSampleLevel(second, smp, q, 0.0).rgb; }
    let k = over_cut(c.r, cut) + over_cut(c.g, cut) + over_cut(c.b, cut);
    return c * (k / max(c.r + c.g + c.b, 1e-6));
}

// Small arithmetic jitter in -0.5..0.5 (no trigonometry).
fn jitter(a: f32, b: f32) -> f32 {
    let q = fract(vec2f(a, b) * 13.517);
    let r = q + dot(q, q.yx + 22.541);
    return fract((r.x + r.y) * r.y) - 0.5;
}

fn pack2(v: vec2f) -> vec4f {
    let s = clamp(v, vec2f(0.0), vec2f(1.0)) * 255.0;
    return vec4f(floor(s.x) / 255.0, fract(s.x), floor(s.y) / 255.0, fract(s.y));
}

fn blurred(uv: vec2f) -> vec3f {
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let cut = cut_level(t);
    let gw = min(globals.size.x, GRID);
    let radius = WIDTH * gw * SPREAD;
    let spread = 2.0 * pow(radius / 2.4, vec3f(2.0));
    let reach = max(radius.r, max(radius.g, radius.b));
    let stride = max(1.0, reach / MAX_TAPS);
    var sum = bright(uv, t, cut);
    var total = vec3f(1.0);
    var i = 1.0;
    for (var j = 0; j < 128; j++) {
        if (i > reach || i > MAX_TAPS * stride) { break; }
        let w = step(vec3f(i), radius) * exp(-(i * i) / spread);
        let da = i + DITHER * stride * jitter(i + uv.x + 0.199, i * uv.y);
        let db = i + DITHER * stride * jitter(i + uv.x + 0.677, i * uv.y);
        sum += (bright(uv + vec2f(da / gw, 0.0), t, cut) + bright(uv - vec2f(db / gw, 0.0), t, cut)) * w;
        total += 2.0 * w;
        i += stride;
    }
    return sum / total;
}

@compute @workgroup_size(8, 8)
fn blur_rg(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let g = blurred(gpufx_uv(id));
    gpufx_write(id, pack2(g.rg));
}

@compute @workgroup_size(8, 8)
fn blur_b(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let g = blurred(gpufx_uv(id));
    gpufx_write(id, pack2(vec2f(g.b, 0.0)));
}
