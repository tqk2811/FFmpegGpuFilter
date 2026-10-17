// Hard cut at the midpoint hidden by a sideways block-noise scramble and a red/green/blue scale split.

// The scramble map is a 1280x720 block-noise frame stretched to cover the output.
const MAP_SIZE: vec2f = vec2f(1280.0, 720.0);
// The map changes this many times over the whole transition.
const MAP_FRAMES: f32 = 60.0;
// Mean and spread of the map's grey level (it is darker than mid grey, so the scramble drifts left).
const MAP_MEAN: f32 = 0.452;
const MAP_SPREAD: f32 = 0.695;
// Strongest sideways push, as a fraction of the width, reached at the midpoint.
const PUSH_PEAK: f32 = 0.45;
// Scale of the blue and red copies at the midpoint (green stays in between).
const SCALE_BLUE: f32 = 1.02;
const SCALE_RED: f32 = 0.98;

// Rises linearly 0 -> 1 over the first half and falls back to 0 over the second.
fn peak(p: f32) -> f32 {
    return 1.0 - abs(2.0 * p - 1.0);
}

fn mix_bits(v: u32) -> u32 {
    var x = v;
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

// Random 0..1 value for one square cell of one layer in one map frame.
fn cell_value(cell: vec2i, layer: u32, frame: u32) -> f32 {
    let key = mix_bits((u32(cell.x) * 73856093u) ^ (u32(cell.y) * 19349663u) ^ ((frame * 4u + layer) * 83492791u));
    return f32(key >> 8u) / 16777216.0;
}

// Grey level of the scramble map at a screen position: three layers of square blocks.
fn map_grey(uv: vec2f, frame: u32) -> f32 {
    let screen_aspect = globals.size.x / globals.size.y;
    let map_aspect = MAP_SIZE.x / MAP_SIZE.y;
    var m = uv;
    if (map_aspect > screen_aspect) {
        m.x = (m.x - 0.5) * (screen_aspect / map_aspect) + 0.5;
    } else {
        m.y = (m.y - 0.5) * (map_aspect / screen_aspect) + 0.5;
    }
    let px = fract(m) * MAP_SIZE;
    let a = cell_value(vec2i(floor(px / 32.0)), 0u, frame) - 0.5;
    let b = cell_value(vec2i(floor(px / 16.0)), 1u, frame) - 0.5;
    let c = cell_value(vec2i(floor(px / 8.0)), 2u, frame) - 0.5;
    return clamp(MAP_MEAN + MAP_SPREAD * (0.6 * a + 0.4 * b + 0.3 * c), 0.0, 1.0);
}

// Folds any coordinate back into 0..1 like a mirrored tile.
fn mirror(v: vec2f) -> vec2f {
    return abs((v + 1.0) - 2.0 * floor((v + 1.0) * 0.5) - 1.0);
}

// The current clip pushed sideways by the scramble map.
fn pushed(uv: vec2f, p: f32, frame: u32) -> vec4f {
    let push = (map_grey(uv, frame) - 0.5) * 2.0 * PUSH_PEAK * peak(p);
    let at = mirror(vec2f(uv.x + push, uv.y));
    if (p <= 0.5) {
        return textureSampleLevel(first, smp, at, 0.0);
    }
    return textureSampleLevel(second, smp, at, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = clamp(params.progress, 0.0, 1.0);
    let frame = u32(min(floor(p * MAP_FRAMES + 0.5), MAP_FRAMES - 1.0));
    let k = peak(p);
    let d = uv - 0.5;
    let blue_uv = mirror(d / mix(1.0, SCALE_BLUE, k) + 0.5);
    let red_uv = mirror(d / mix(1.0, SCALE_RED, k) + 0.5);
    let green_uv = mirror(0.5 * (d / mix(1.0, SCALE_BLUE, k) + d / mix(1.0, SCALE_RED, k)) + 0.5);
    let r = pushed(red_uv, p, frame).r;
    let g = pushed(green_uv, p, frame).g;
    let b = pushed(blue_uv, p, frame).b;
    gpufx_write(id, vec4f(r, g, b, 1.0));
}
