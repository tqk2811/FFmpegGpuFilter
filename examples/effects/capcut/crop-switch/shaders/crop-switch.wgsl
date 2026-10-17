// Cropped panels of the second clip pop up over the first one, with drop shadows and sideways/vertical jolts, before the full second clip cuts in.

// Animation span of the whole transition, in seconds.
const SPAN: f32 = 2.0;
// The panel layout changes on a 30 fps grid, sampled half a frame late.
const STEP_FPS: f32 = 30.0;
// Panel layout grid (the layouts were drawn on a 290x512 canvas stretched to the frame).
const GRID: vec2f = vec2f(290.0, 512.0);

// One panel: x0, y0, x1, y1 on the grid, plus its tone (0 = dark, 1 = light) that drives the vertical jolt.
struct Panel {
    rect: vec4f,
    tone: f32,
}

// Panels visible in layout `n` (up to two); count returned in `.count`.
struct Layout {
    a: Panel,
    b: Panel,
    count: i32,
    split: bool,
}

fn layout_for(n: i32) -> Layout {
    var l: Layout;
    l.count = 0;
    l.split = false;
    if (n >= 4 && n <= 7) { l.a = Panel(vec4f(66.0, 22.0, 246.0, 487.0), 0.0); l.count = 1; }
    else if (n >= 8 && n <= 11) { l.a = Panel(vec4f(4.0, 298.0, 290.0, 512.0), 25.0 / 255.0); l.count = 1; }
    else if (n >= 12 && n <= 15) { l.a = Panel(vec4f(46.0, 24.0, 284.0, 147.0), 0.0); l.count = 1; }
    else if (n >= 16 && n <= 19) { l.a = Panel(vec4f(62.0, 9.0, 176.0, 492.0), 0.0); l.count = 1; }
    else if (n >= 20 && n <= 23) {
        l.a = Panel(vec4f(12.0, 29.0, 119.0, 131.0), 1.0);
        l.b = Panel(vec4f(12.0, 140.0, 119.0, 242.0), 0.0);
        l.count = 2;
    }
    else if (n >= 24 && n <= 31) { l.a = Panel(vec4f(62.0, 226.0, 290.0, 499.0), 0.0); l.count = 1; }
    else if (n >= 32 && n <= 35) { l.a = Panel(vec4f(0.0, 198.0, 290.0, 512.0), 0.0); l.count = 1; l.split = true; }
    return l;
}

// Square of a value.
fn sq(x: f32) -> f32 {
    return x * x;
}

fn inside(g: vec2f, r: vec4f) -> bool {
    return g.x >= r.x && g.x < r.z && g.y >= r.y && g.y < r.w;
}

// Tone of the split layout: dark on top, a short ramp, light at the bottom.
fn split_tone(gy: f32) -> f32 {
    let ramp = array<f32, 7>(0.0, 26.0, 73.0, 143.0, 195.0, 229.0, 254.0);
    let row = clamp(i32(floor(gy)) - 320, 0, 6);
    return ramp[row] / 255.0;
}

// Soft drop shadow hugging the panel border, strong on the right/bottom, faint on the left/top.
fn shadow_of(g: vec2f, r: vec4f) -> f32 {
    let sig = 3.3;
    let in_y = select(0.0, 1.0, g.y > r.y - 4.0 && g.y < r.w + 4.0);
    let in_x = select(0.0, 1.0, g.x > r.x - 4.0 && g.x < r.z + 4.0);
    let right = exp(-sq(g.x - (r.z + 1.5)) / (2.0 * sig * sig)) * 0.58 * in_y;
    let bottom = exp(-sq(g.y - (r.w + 1.5)) / (2.0 * sig * sig)) * 0.66 * in_x;
    let left = exp(-sq(g.x - (r.x - 0.5)) / (2.0 * sig * sig)) * 0.075 * in_y;
    let top = exp(-sq(g.y - (r.y - 5.0)) / (2.0 * sig * sig)) * 0.05 * in_x;
    return clamp(max(max(right, bottom), max(left, top)), 0.0, 1.0);
}

// Piecewise-linear key track: value at time t through (time, value) pairs.
fn track(t: f32, keys: array<vec2f, 8>, n: i32) -> f32 {
    var v = keys[0].y;
    for (var i = 0; i < 7; i++) {
        if (i + 1 >= n) { break; }
        let k0 = keys[i];
        let k1 = keys[i + 1];
        if (t >= k0.x && t <= k1.x) {
            v = mix(k0.y, k1.y, clamp((t - k0.x) / max(k1.x - k0.x, 1e-5), 0.0, 1.0));
        } else if (t > k1.x) {
            v = k1.y;
        }
    }
    return v;
}

// Mirror-repeat coordinates outside [0, 1].
fn mirror(p: vec2f) -> vec2f {
    let m = p - 2.0 * floor(p * 0.5);
    return clamp(select(m, 2.0 - m, m > vec2f(1.0)), vec2f(0.0), vec2f(1.0));
}

fn hash21(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

// Sparse film dust: a few tiny bright specks per 30 fps frame.
fn dust(uv: vec2f, frame: f32, aspect: f32) -> f32 {
    var a = 0.0;
    for (var k = 0; k < 5; k++) {
        let seed = vec2f(frame, f32(k));
        let c = vec2f(hash21(seed), hash21(seed + 17.3));
        let present = step(0.6, hash21(seed + 5.1));
        let d = (uv - c) * vec2f(aspect, 1.0) * 512.0;
        let rad = 0.8 + 1.2 * hash21(seed + 9.7);
        a = max(a, present * (1.0 - smoothstep(rad * 0.5, rad, length(d))) * 0.85);
    }
    return a;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let dims = vec2f(textureDimensions(first));
    let aspect = dims.x / dims.y;
    let frame = min(floor(t * STEP_FPS + 0.5), 59.0);
    let g = uv * GRID;
    let l = layout_for(i32(frame));

    // Back layer: the first clip with the panels' drop shadows.
    var col = textureSampleLevel(first, smp, uv, 0.0).rgb;
    var shade = 0.0;
    if (l.count >= 1 && !l.split) { shade = max(shade, shadow_of(g, l.a.rect)); }
    if (l.count >= 2) { shade = max(shade, shadow_of(g, l.b.rect)); }
    col = col * (1.0 - shade);

    // Panels: the second clip, nudged sideways by the panel coverage and vertically by its tone.
    var hit = false;
    var tone = 0.0;
    if (l.count >= 1 && inside(g, l.a.rect)) {
        hit = true;
        tone = select(l.a.tone, split_tone(g.y), l.split);
    }
    if (l.count >= 2 && inside(g, l.b.rect)) { hit = true; tone = l.b.tone; }
    if (hit) {
        let hx = track(t, array<vec2f, 8>(vec2f(0.633333, 0.0), vec2f(0.666667, 0.26), vec2f(0.766667, 0.26), vec2f(0.8, 0.0),
            vec2f(0.8, 0.0), vec2f(0.8, 0.0), vec2f(0.8, 0.0), vec2f(0.8, 0.0)), 4);
        let vy = track(t, array<vec2f, 8>(vec2f(0.633333, 0.0), vec2f(0.666667, 0.5), vec2f(0.766667, 0.52), vec2f(0.8, 0.0),
            vec2f(1.033333, 0.0), vec2f(1.066667, 0.18), vec2f(1.166667, 0.18), vec2f(1.2, 0.0)), 8);
        let offset = vec2f(hx, -(tone - 0.5) * 2.0 * vy * aspect);
        let panel = textureSampleLevel(second, smp, mirror(uv + offset), 0.0).rgb;
        let fade = clamp((t - 0.1) / 0.033333, 0.0, 1.0);
        col = mix(col, panel, fade);
    }

    // The whole second clip cuts in over everything.
    let full = clamp((t - 1.166667) / 0.033333, 0.0, 1.0);
    col = mix(col, textureSampleLevel(second, smp, uv, 0.0).rgb, full);

    // Faint dust on top.
    let speck = dust(uv, frame, aspect);
    col = mix(col, vec3f(1.0), speck);
    gpufx_write(id, vec4f(col, 1.0));
}
