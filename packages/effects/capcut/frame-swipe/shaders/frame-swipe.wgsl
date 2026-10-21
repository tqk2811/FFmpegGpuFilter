// Frame Swipe, pass 2: a strong sideways motion blur peaking at the cut, inside a band that leaves black bars at the top and bottom,
// with a brighter, slightly pink and softer colour grade faded in over the picture.

const SPAN: f32 = 1.99999;
const SMOOTH: vec4f = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);
const RISE: vec4f = vec4f(0.1666667, 0.1666667, 0.6666667, 1.0);
const FALL: vec4f = vec4f(0.3333333, 0.0, 0.8333333, 1.0);
const FALL_BAND: vec4f = vec4f(0.3333333, 0.0, 0.8333333, 0.8333333);

fn bezier_ease(u: f32, h: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let m = 0.5 * (lo + hi);
        let r = 1.0 - m;
        let x = 3.0 * r * r * m * h.x + 3.0 * r * m * m * h.z + m * m * m;
        if (x > u) { hi = m; } else { lo = m; }
    }
    let s = 0.5 * (lo + hi);
    let r = 1.0 - s;
    return 3.0 * r * r * s * h.y + 3.0 * r * s * s * h.w + s * s * s;
}

fn track(t: f32, t0: f32, t1: f32, v0: f32, v1: f32, h: vec4f) -> f32 {
    if (t < t0) { return v0; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, bezier_ease((t - t0) / (t1 - t0), h));
}

// How strongly the graded band covers the picture: fades in over 0.24 s and out from 1.69 s.
fn cover(t: f32) -> f32 {
    if (t < 0.240007) { return track(t, 0.0, 0.240007, 0.0, 1.0, SMOOTH); }
    if (t < 1.693327) { return 1.0; }
    return track(t, 1.693327, 1.959993, 1.0, 0.0, SMOOTH);
}

// Blur strength (0..1000 scale): 0 -> 300 at the cut -> 0 by 1.6 s.
fn blur_strength(t: f32) -> f32 {
    if (t < 1.0) { return track(t, 0.480013, 1.0, 0.0, 300.0, RISE); }
    return track(t, 1.0, 1.6, 300.0, 0.0, FALL);
}

// Share of the height cut away at the top and at the bottom of the band.
fn bar_size(t: f32) -> f32 {
    var w: f32;
    if (t < 1.0) { w = track(t, 0.480013, 1.0, 0.3, 0.33, RISE); } else { w = track(t, 1.0, 1.6, 0.33, 0.3, FALL_BAND); }
    return 2.0 * w - 0.5;
}

// Taps per side for a strength, as the original sizes its blur.
fn tap_count(s: f32) -> f32 {
    var k: vec3f;
    if (s <= 10.0) { k = vec3f(0.8, 0.0, 1.0); }
    else if (s <= 50.0) { k = vec3f(0.7, 2.0, 0.78); }
    else if (s <= 200.0) { k = vec3f(0.5, 10.0, 0.66); }
    else if (s <= 500.0) { k = vec3f(0.25, 60.0, 0.7); }
    else { k = vec3f(0.125, 100.0, 0.8); }
    let n = (k.x * s + k.y) * k.z;
    return select(n, floor(n + 0.5), n < 2.0);
}

// Gaussian-weighted sideways blur: radius = strength / 1000 of the reference size, sigma a third of it.
fn sideways_blur(uv: vec2f, s: f32) -> vec3f {
    let here = textureSampleLevel(composed, smp, uv, 0.0).rgb;
    let n = tap_count(s);
    if (n < 1e-5) { return here; }
    let dims = vec2f(textureDimensions(composed));
    let reference = max(min(dims.x, dims.y), max(dims.x, dims.y) * 0.5);
    let radius = s / 1000.0;
    let sigma = radius / 3.0;
    let step = radius / n * reference / dims.x;
    var sum = here;
    var weight = 1.0;
    let count = min(i32(floor(n)), 1024);
    for (var i = 1; i <= count; i++) {
        let d = step * f32(i);
        let w = exp(-0.5 * d * d / (sigma * sigma));
        let left = uv.x - d;
        let right = uv.x + d;
        if (left >= 0.0) { sum += w * textureSampleLevel(composed, smp, vec2f(left, uv.y), 0.0).rgb; weight += w; }
        if (right <= 1.0) { sum += w * textureSampleLevel(composed, smp, vec2f(right, uv.y), 0.0).rgb; weight += w; }
    }
    return clamp(sum / weight, vec3f(0.0), vec3f(1.0));
}

// Colour grade (more exposure, a magenta tint, softer contrast and highlights, lifted mids), fitted as
// a 9-knot curve on each channel, a 9-knot curve on the brightest channel and a cubic cross term.
const OWN_R: array<f32, 9> = array<f32, 9>(-0.00687948, 0.0372451, 0.0908005, 0.161138, 0.198338, 0.188081, 0.193921, 0.216786, 0.258577);
const OWN_G: array<f32, 9> = array<f32, 9>(-0.00323079, 0.0673936, 0.13287, 0.186263, 0.209128, 0.165533, 0.13226, 0.114336, 0.121128);
const OWN_B: array<f32, 9> = array<f32, 9>(-0.0064829, 0.0432989, 0.0997933, 0.169806, 0.197879, 0.177884, 0.177054, 0.195518, 0.235686);
const TOP_R: array<f32, 9> = array<f32, 9>(0.0, -0.0128726, -0.0192248, 0.0202212, 0.0320102, 0.0352419, 0.0363036, 0.0350783, 0.0351549);
const TOP_G: array<f32, 9> = array<f32, 9>(0.0, -0.0142667, -0.0256492, 0.0113586, 0.0200894, 0.0226737, 0.0248308, 0.02595, 0.0293486);
const TOP_B: array<f32, 9> = array<f32, 9>(0.0, -0.00934393, -0.014474, 0.0265272, 0.0363716, 0.0396428, 0.0417225, 0.0432043, 0.0454002);
const MIX_R: array<f32, 19> = array<f32, 19>(0.0406335, -0.0795096, 0.0413859, 0.17213, -0.00912922, 0.0443701, -0.0849691, -0.0135635, 0.099858, 0.898207, -0.0216926, -0.0239632, -0.372148, -0.00413514, -0.0554779, 0.114754, 0.033082, 0.254037, -0.332464);
const MIX_G: array<f32, 19> = array<f32, 19>(0.0331428, -0.0673877, 0.0364834, 0.639879, -0.00773856, -0.0159775, 0.718624, 0.0215689, -0.540573, 0.068878, -0.0396988, 0.0198245, -0.0155893, 0.0128886, -0.00213461, -0.144654, 0.0260445, 0.0282131, 0.0650299);
const MIX_B: array<f32, 19> = array<f32, 19>(0.84371, 0.311728, -0.451352, 0.129911, -0.193949, 0.130273, -0.151855, -0.0145431, 0.0974888, 0.0605339, -0.0392345, 0.00559636, -0.0299841, 0.0383824, 0.00419244, -0.102051, 0.0153797, 0.00798773, 0.0516596);

fn knots(table: array<f32, 9>, v: f32) -> f32 {
    var k = table;
    let x = clamp(v, 0.0, 1.0) * 8.0;
    let i = min(u32(floor(x)), 7u);
    let f = x - f32(i);
    return mix(k[i], k[i + 1u], f);
}

fn cubic(table: array<f32, 19>, c: vec3f) -> f32 {
    var k = table;
    let r = c.r;
    let g = c.g;
    let b = c.b;
    let terms = array<f32, 19>(b, b * b, b * b * b, g, g * b, g * b * b, g * g, g * g * b, g * g * g,
        r, r * b, r * b * b, r * g, r * g * b, r * g * g, r * r, r * r * b, r * r * g, r * r * r);
    var sum = 0.0;
    for (var i = 0u; i < 19u; i++) { sum += k[i] * terms[i]; }
    return sum;
}

fn grade(c: vec3f) -> vec3f {
    let top = max(c.r, max(c.g, c.b));
    let r = knots(OWN_R, c.r) + knots(TOP_R, top) + cubic(MIX_R, c);
    let g = knots(OWN_G, c.g) + knots(TOP_G, top) + cubic(MIX_G, c);
    let b = knots(OWN_B, c.b) + knots(TOP_B, top) + cubic(MIX_B, c);
    return clamp(vec3f(r, g, b), vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let base = textureSampleLevel(composed, smp, uv, 0.0).rgb;
    let amount = cover(t);
    if (amount <= 0.0) { gpufx_write(id, vec4f(base, 1.0)); return; }
    let bar = bar_size(t);
    let inside = uv.y >= bar && 1.0 - uv.y >= bar;
    var colour: vec3f;
    if (inside) {
        colour = mix(base, grade(sideways_blur(uv, blur_strength(t))), amount);
    } else {
        // The cut-away bars are see-through in the graded layer, so covering darkens the picture there twice.
        colour = base * (1.0 - amount) * (1.0 - amount);
    }
    gpufx_write(id, vec4f(colour, 1.0));
}
