// The second clip is painted over the first in dry-brush strokes that sweep from the top left down to the right.

// The stroke mask lives on a 1280x720 canvas stretched to cover the output.
const CANVAS: vec2f = vec2f(1280.0, 720.0);
// The paint advances in this many held steps (15 frames at 30 fps over CapCut's 0.5 s comp).
const STEPS: f32 = 15.0;
// Direction of the brush streaks on the canvas, in degrees below the horizontal.
const STREAK_ANGLE: f32 = 30.0;

fn mix_bits(v: u32) -> u32 {
    var x = v;
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

fn lattice(c: vec2f, layer: u32) -> f32 {
    let i = vec2i(c);
    let key = mix_bits(u32(i.x + 4096) * 73856093u ^ u32(i.y + 4096) * 19349663u ^ layer * 83492791u);
    return f32(key >> 8u) / 8388608.0 - 1.0;
}

// Smooth value noise in -1..1.
fn smooth_noise(q: vec2f, layer: u32) -> f32 {
    let b = floor(q);
    let f = q - b;
    let s = f * f * (3.0 - 2.0 * f);
    let a0 = mix(lattice(b, layer), lattice(b + vec2f(1.0, 0.0), layer), s.x);
    let a1 = mix(lattice(b + vec2f(0.0, 1.0), layer), lattice(b + vec2f(1.0, 1.0), layer), s.x);
    return mix(a0, a1, s.y);
}

// Step (1..15) at which a canvas point gets painted: a broad sweep plus streaky brush noise.
fn paint_step(c: vec2f) -> f32 {
    let x = c.x / CANVAS.x;
    let y = c.y / CANVAS.y;
    let sweep = 1.9 + 8.778 * y - 3.806 * y * y - 0.452 * y * y * y
        + 0.897 * x - 2.466 * x * y + 9.732 * x * y * y
        + 3.098 * x * x - 15.721 * x * x * y + 6.906 * x * x * x;
    let a = radians(STREAK_ANGLE);
    let along = c.x * cos(a) + c.y * sin(a);
    let across = -c.x * sin(a) + c.y * cos(a);
    let coarse = smooth_noise(vec2f(along / 500.0, across / 120.0), 1u);
    let mid = smooth_noise(vec2f(along / 220.0, across / 35.0), 2u);
    let fine = smooth_noise(vec2f(along / 120.0, across / 8.0), 3u);
    return clamp(sweep + 2.5 * coarse + 1.0 * mid + 1.6 * fine, 1.5, 13.5);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = clamp(params.progress, 0.0, 1.0);
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // Exact clips at the ends of the transition.
    if (p <= 0.0) { gpufx_write(id, vec4f(a, 1.0)); return; }
    if (p >= 1.0) { gpufx_write(id, vec4f(b, 1.0)); return; }
    let screen_aspect = globals.size.x / globals.size.y;
    let canvas_aspect = CANVAS.x / CANVAS.y;
    var m = uv;
    if (canvas_aspect > screen_aspect) {
        m.x = (m.x - 0.5) * (screen_aspect / canvas_aspect) + 0.5;
    } else {
        m.y = (m.y - 0.5) * (canvas_aspect / screen_aspect) + 0.5;
    }
    let shown = min(floor(p * STEPS + 0.5), STEPS - 1.0) + 1.0;
    let painted = paint_step(m * CANVAS) <= shown;
    gpufx_write(id, vec4f(select(a, b, painted), 1.0));
}
