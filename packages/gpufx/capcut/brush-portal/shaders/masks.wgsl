// Brush Portal, pass 1: a swirling paint-brush blob grows from the centre (r = reveal mask, g = bright rim band).

const SPAN: f32 = 2.0;        // scene seconds covered by progress 0..1
const FPS: f32 = 30.0;        // the brush animation is keyed per 30 fps frame
const FIRST_KEY: f32 = 10.0;  // frame of the first table entry
const VIDEO_ASPECT: f32 = 1.7777778; // the brush is drawn in a 16:9 frame that is scaled to fill the output
const TAU: f32 = 6.2831853;

// Radius (in frame heights) of the outer brush edge, one entry per frame from frame 10.
const OUTER = array<f32, 41>(
    0.0, 0.02, 0.06, 0.10, 0.125, 0.147, 0.193, 0.236, 0.28, 0.311,
    0.338, 0.385, 0.435, 0.461, 0.50, 0.518, 0.562, 0.593, 0.633, 0.688,
    0.716, 0.751, 0.761, 0.822, 0.851, 0.898, 0.902, 0.917, 0.992, 1.0,
    1.005, 1.06, 1.10, 1.13, 1.16, 1.19, 1.22, 1.25, 1.28, 1.30, 1.32);
// Radius of the solid core that trails behind the edge; the rim band lies between the two.
const CORE = array<f32, 41>(
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.03, 0.05, 0.07,
    0.10, 0.241, 0.282, 0.299, 0.332, 0.389, 0.425, 0.47, 0.493, 0.525,
    0.555, 0.585, 0.63, 0.689, 0.72, 0.738, 0.754, 0.826, 0.852, 0.892,
    0.903, 0.938, 0.97, 1.0, 1.03, 1.06, 1.10, 1.14, 1.18, 1.22, 1.26);

fn table(values: array<f32, 41>, f: f32) -> f32 {
    let x = clamp(f - FIRST_KEY, 0.0, 40.0);
    let i = min(u32(x), 39u);
    var v = values;
    return mix(v[i], v[i + 1u], x - f32(i));
}

fn mix_hash(n: u32) -> u32 {
    var h = n * 747796405u + 2891336453u;
    h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
    return (h >> 22u) ^ h;
}

fn lattice(x: i32, y: i32, period: i32) -> f32 {
    let wx = u32(((x % period) + period) % period);
    return f32(mix_hash(wx + mix_hash(u32(y + 4096))) & 0xffffu) / 65535.0;
}

// Value noise that repeats every `period` cells along x (so it wraps around the circle).
fn ring_noise(p: vec2f, period: i32) -> f32 {
    let c = floor(p);
    let t = p - c;
    let s = t * t * (3.0 - 2.0 * t);
    let x = i32(c.x);
    let y = i32(c.y);
    let a = mix(lattice(x, y, period), lattice(x + 1, y, period), s.x);
    let b = mix(lattice(x, y + 1, period), lattice(x + 1, y + 1, period), s.x);
    return mix(a, b, s.y);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let f = clamp(params.progress, 0.0, 1.0) * SPAN * FPS;
    let uv = gpufx_uv(id);
    if (f < FIRST_KEY) { gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0)); return; }

    // The blob starts a little low and settles on the centre.
    let centre = vec2f(0.5, mix(0.6, 0.5, smoothstep(22.0, 40.0, f)));
    // Distances in heights of the brush frame, which is scaled to cover the output without stretching.
    let aspect = globals.size.x / globals.size.y;
    let q = (uv - centre) * vec2f(aspect, 1.0) / max(1.0, aspect / VIDEO_ASPECT);
    let r = length(q);
    let turn = atan2(q.y, q.x) / TAU + 0.5;

    // Strokes run around the blob in a loose spiral: long along the angle, thin across the radius.
    let swirl = turn * 12.0 + r * 4.0 - f * 0.05;
    let strokes = 0.6 * ring_noise(vec2f(swirl, r * 45.0), 12) + 0.4 * ring_noise(vec2f(turn * 24.0, r * 110.0), 24);
    let ragged = ring_noise(vec2f(turn * 5.0 + f * 0.02, 3.5), 5) - 0.5;

    let outer = table(OUTER, f);
    let core = table(CORE, f);
    let reach = r + (strokes - 0.5) * 0.08 * max(outer, 0.1) + ragged * 0.12 * max(outer, 0.1);
    let edge = 1.0 - smoothstep(outer - 0.04, outer + 0.04, reach);

    // Early on the blob is see-through brush strokes; it fills in solid by frame 24.
    let fill = smoothstep(11.0, 24.0, f);
    let solid = clamp(fill + 0.5 - 0.5 * r / max(outer, 0.01), 0.0, 1.0);
    let brush = edge * mix(0.35 + 0.65 * strokes, 1.0, solid);

    let core_level = mix(0.5, 1.0, smoothstep(16.0, 27.0, f));
    let inside = (1.0 - smoothstep(core - 0.06, core + 0.06, reach)) * core_level;
    let rim = brush * (1.0 - inside);
    gpufx_write(id, vec4f(brush, rim, 0.0, 1.0));
}
