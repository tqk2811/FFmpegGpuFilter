// Signal Glitch 2, pass 6: brighten the picture, keep what is above half brightness and blur it horizontally.
//
// The glow is laid out on a grid at most GRID texels wide; the red, green and blue
// blur radii differ (36, 43.2, 50.4 grid texels at full width) for a coloured fringe.

const FRAMES: f32 = 19.0;
const GAMMA: f32 = 2.2;
const GRID: f32 = 360.0;
const WIDTH: f32 = 0.1;          // glow radius as a fraction of the grid width
const SPREAD = vec3f(1.0, 1.2, 1.4);
const MAX_TAPS: f32 = 30.0;
const CUT: f32 = 0.5;

fn bezier_axis(a: f32, b: f32, t: f32) -> f32 {
    let s = 1.0 - t;
    return 3.0 * a * s * s * t + 3.0 * b * s * t * t + t * t * t;
}

fn ease(c: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(c.x, c.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(c.y, c.w, 0.5 * (lo + hi));
}

fn key(f: f32, f0: f32, f1: f32, v0: f32, v1: f32, c: vec4f) -> f32 {
    return mix(v0, v1, ease(c, clamp((f - f0) / (f1 - f0), 0.0, 1.0)));
}

// Exposure boost in stops.
fn stops(f: f32) -> f32 {
    if (f < 2.0) { return 0.0; }
    if (f < 7.0) { return key(f, 2.0, 7.0, 0.0, 1.8, vec4f(0.33333333, 0.0, 0.846666598, 0.999999998)); }
    if (f < 11.0) { return key(f, 7.0, 11.0, 1.8, 2.001581, vec4f(0.124899062, -0.080575183, 0.496794385, 3.398546562)); }
    if (f < 19.0) { return key(f, 11.0, 19.0, 2.001581, 0.0, vec4f(0.277088557, 0.266028294, 0.713436483, 1.0)); }
    return 0.0;
}

fn bright_part(q: vec2f, gain: f32) -> vec3f {
    let c = textureSampleLevel(softened, smp, q, 0.0).rgb;
    let e = clamp(pow(pow(c, vec3f(GAMMA)) * gain, vec3f(1.0 / GAMMA)), vec3f(0.0), vec3f(1.0));
    let over = select(vec3f(0.0), (e - CUT) / (1.0 - CUT), e > vec3f(CUT));
    let k = (over.r + over.g + over.b) / max(e.r + e.g + e.b, 1e-6);
    return e * k;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let f = clamp(params.progress, 0.0, 1.0) * FRAMES;
    let gain = exp2(stops(f));
    let gw = floor(min(globals.size.x, GRID));
    let radius = WIDTH * min(globals.size.x, GRID) * SPREAD;
    let spread = 2.0 * pow(radius / 2.4, vec3f(2.0));
    let reach = max(radius.r, max(radius.g, radius.b));
    let stride = max(1.0, reach / MAX_TAPS);
    var sum = bright_part(uv, gain);
    var total = vec3f(1.0);
    var i = 1.0;
    for (var j = 0; j < 64; j++) {
        if (i > reach || i > MAX_TAPS * stride) { break; }
        let w = step(vec3f(i), radius) * exp(-(i * i) / spread);
        let o = vec2f(i / gw, 0.0);
        sum += (bright_part(uv + o, gain) + bright_part(uv - o, gain)) * w;
        total += 2.0 * w;
        i += stride;
    }
    gpufx_write(id, vec4f(sum / total, 1.0));
}
