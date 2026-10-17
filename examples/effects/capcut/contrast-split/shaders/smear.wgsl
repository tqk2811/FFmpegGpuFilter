// Contrast Split, pass 2: a weak analogue-signal look at half resolution (sideways smear, edge peaking, chroma lagging
// eight steps behind) and a warm, contrasty film grade that swells in toward the cut.

const SPAN: f32 = 0.99999;

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

// Shared 0 -> 1 -> 0 envelope of the grading effects: up by 0.433 s, back down by 1 s.
fn envelope(t: f32) -> f32 {
    if (t < 0.433333) { return bezier_ease(t / 0.433333, vec4f(0.45, 0.0, 0.8333333, 0.8333333)); }
    return 1.0 - bezier_ease(clamp((t - 0.433333) / (1.0 - 0.433333), 0.0, 1.0), vec4f(0.1666667, 0.1666667, 0.57, 1.0));
}

// The grading runs at half resolution: those textures hold the picture in their top-left quarter.
fn half_size(dims: vec2f) -> vec2f {
    return max(floor(dims * 0.5), vec2f(1.0));
}

fn half_uv(uv: vec2f, dims: vec2f) -> vec2f {
    let h = half_size(dims);
    return clamp(uv, 0.5 / h, 1.0 - 0.5 / h) * h / dims;
}

fn to_ycc(c: vec3f) -> vec3f {
    let y = dot(c, vec3f(0.299, 0.587, 0.114));
    return vec3f(y, (c.b - y) * 0.565, (c.r - y) * 0.713);
}

fn from_ycc(c: vec3f) -> vec3f {
    return vec3f(c.x + 1.403 * c.z, c.x - 0.344 * c.y - 0.714 * c.z, c.x + 1.77 * c.y);
}

// The film grade as a cubic polynomial in r, g, b.
const GRADE_R: array<f32, 20> = array<f32, 20>(0.00298634, 0.00472659, -0.0218007, 0.0316271, 0.000624193, -0.00396562, 0.00716788, -0.0430757, -0.00517578, 0.0479201, 0.748108, -0.151725, -0.0544017, -0.268794, -0.0375129, -0.0960026, 1.19206, 0.229338, 0.395473, -0.973349);
const GRADE_G: array<f32, 20> = array<f32, 20>(-0.00484396, -0.0121178, 0.0047809, 0.0135536, 0.854971, -0.177385, -0.0552957, 0.840097, 0.2037, -0.686213, 0.0408564, -0.0187444, 0.000464516, -0.124972, 0.0538145, 0.146101, -0.110337, 0.0106388, -0.0326956, 0.0719905);
const GRADE_B: array<f32, 20> = array<f32, 20>(-0.00374413, 0.563911, 1.5285, -1.11873, 9.33203e-05, -0.140954, 0.220029, -0.0396251, -0.0489989, 0.0315039, 0.0283239, -0.237263, 0.33644, 0.0269078, -0.0339127, -0.0333705, -0.0653545, -0.0636674, 0.0123493, 0.0396363);

fn poly(table: array<f32, 20>, c: vec3f) -> f32 {
    var k = table;
    let r = c.r;
    let g = c.g;
    let b = c.b;
    let terms = array<f32, 20>(1.0, b, b * b, b * b * b, g, g * b, g * b * b, g * g, g * g * b, g * g * g,
        r, r * b, r * b * b, r * g, r * g * b, r * g * g, r * r, r * r * b, r * r * g, r * r * r);
    var sum = 0.0;
    for (var i = 0u; i < 20u; i++) { sum += k[i] * terms[i]; }
    return sum;
}

fn film_grade(c: vec3f) -> vec3f {
    return clamp(vec3f(poly(GRADE_R, c), poly(GRADE_G, c), poly(GRADE_B, c)), vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let dims = vec2f(textureDimensions(composed));
    let h = half_size(dims);
    if (f32(id.x) >= h.x || f32(id.y) >= h.y) { gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0)); return; }
    let uv = (vec2f(id.xy) + 0.5) / h;
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let step = 1.0 / (dims / min(dims.x, dims.y) * 720.0);
    let here = textureSampleLevel(composed, smp, uv, 0.0).rgb;
    var trail = here;
    for (var k = 1; k <= 8; k++) {
        trail += textureSampleLevel(composed, smp, uv - vec2f(f32(k) * step.x, 0.0), 0.0).rgb;
    }
    let peaked = clamp(here + (here - trail / 9.0) * 0.6, vec3f(0.0), vec3f(1.0));
    let lagging = to_ycc(textureSampleLevel(composed, smp, uv - vec2f(8.0 * step.x, 0.0), 0.0).rgb);
    var ycc = to_ycc(peaked);
    ycc = vec3f(ycc.x, mix(ycc.yz, lagging.yz, vec2f(0.6)));
    let analogue = clamp(from_ycc(ycc), vec3f(0.0), vec3f(1.0));
    let strength = 0.8 * envelope(t);
    gpufx_write(id, vec4f(mix(analogue, film_grade(analogue), strength), 1.0));
}
