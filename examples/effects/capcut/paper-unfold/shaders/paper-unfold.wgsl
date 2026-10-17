// Crumpled newspaper sheets climb up over the first clip while a torn edge reveals the second clip from the bottom, with white scratch streaks and a short exposure flash.

// Animation span of the whole transition, in seconds.
const SPAN: f32 = 1.458333;
// Frame rate the torn shapes are stepped on (each step is sampled half a frame late).
const STEP_FPS: f32 = 24.0;
// The newspaper layer plays between these times.
const PAPER_IN: f32 = 0.333333;
const PAPER_OUT: f32 = 1.125;
// The scratch streaks play between these times.
const SCRATCH_OUT: f32 = 1.208333;
// The exposure flash (+1 stop in linear light) between these times.
const FLASH_IN: f32 = 0.916667;
const FLASH_OUT: f32 = 1.125;

// Reveal edge of the second clip per 24 fps frame: mean height from the top, and half the spread.
fn reveal_edge(n: i32) -> vec2f {
    let mean = array<f32, 35>(
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.945, 0.945, 0.804, 0.804, 0.778, 0.778, 0.778,
        0.519, 0.519, 0.392, 0.392, 0.392, 0.326, 0.326, 0.159, 0.159, 0.085, 0.085, 0.085,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    let spread = array<f32, 35>(
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.087, 0.087, 0.153, 0.153, 0.089, 0.089, 0.089,
        0.059, 0.059, 0.09, 0.09, 0.09, 0.123, 0.123, 0.069, 0.069, 0.061, 0.061, 0.061,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    let i = clamp(n, 0, 34);
    return vec2f(mean[i], spread[i]);
}

// Newspaper sheet per held drawing: top edge mean, half spread, bottom edge mean, and the drawing seed.
fn sheet_shape(k: i32) -> vec4f {
    let shapes = array<vec4f, 8>(
        vec4f(0.907, 0.10, 1.10, 1.0), vec4f(0.749, 0.096, 1.10, 2.0),
        vec4f(0.728, 0.086, 1.10, 3.0), vec4f(0.443, 0.058, 0.986, 4.0),
        vec4f(0.283, 0.102, 0.85, 5.0), vec4f(0.223, 0.136, 0.963, 6.0),
        vec4f(0.042, 0.054, 0.648, 7.0), vec4f(0.004, 0.015, 0.676, 8.0));
    return shapes[clamp(k, 0, 7)];
}

// Which held drawing a sheet / scratch frame belongs to (drawings are held 2 or 3 frames).
fn held_drawing(n: i32) -> i32 {
    let starts = array<i32, 9>(0, 2, 4, 7, 9, 12, 14, 16, 19);
    var k = 0;
    for (var i = 1; i < 9; i++) {
        if (n >= starts[i]) { k = i; }
    }
    return k;
}

// Integer PCG hash; inputs are snapped to 1/16 steps first so tiny float
// differences between backends cannot change the result.
fn pcg(v: u32) -> u32 {
    let s = v * 747796405u + 2891336453u;
    let w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}

fn unit(h: u32) -> f32 {
    return f32(h >> 8u) * (1.0 / 16777216.0);
}

fn snap(x: f32) -> u32 {
    return bitcast<u32>(i32(round(x * 16.0)));
}

fn hash11(x: f32) -> f32 {
    return unit(pcg(snap(x)));
}

fn hash21(p: vec2f) -> f32 {
    return unit(pcg(snap(p.x) ^ pcg(snap(p.y))));
}

// Smooth 1D value noise in -1..1.
fn noise1(x: f32, seed: f32) -> f32 {
    let i = floor(x);
    let f = x - i;
    let w = f * f * (3.0 - 2.0 * f);
    return mix(hash11(i + seed * 57.0), hash11(i + 1.0 + seed * 57.0), w) * 2.0 - 1.0;
}

// Torn edge profile in -1..1: broad waves plus fine jags.
fn torn(x: f32, seed: f32) -> f32 {
    let broad = noise1(x * 3.0, seed) * 0.65 + noise1(x * 7.0, seed + 3.0) * 0.25;
    let fine = noise1(x * 60.0, seed + 7.0) * 0.07 + noise1(x * 180.0, seed + 9.0) * 0.03;
    return broad + fine;
}

fn noise2(p: vec2f) -> f32 {
    let i = floor(p);
    let f = p - i;
    let w = f * f * (3.0 - 2.0 * f);
    let a = hash21(i);
    let b = hash21(i + vec2f(1.0, 0.0));
    let c = hash21(i + vec2f(0.0, 1.0));
    let d = hash21(i + vec2f(1.0, 1.0));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// Grey newspaper print: columns of text lines with the odd headline, on crumpled paper.
fn newsprint(q: vec2f, seed: f32) -> f32 {
    let p = q + vec2f(seed * 0.37, seed * 0.21);
    let col_w = 0.21;
    let cx = fract(p.x / col_w) * col_w;
    let col_id = floor(p.x / col_w);
    var ink = 0.0;
    if (cx > 0.012) {
        let headline = hash21(vec2f(col_id, floor(p.y / 0.11) + seed)) > 0.8;
        let pitch = select(0.0125, 0.035, headline);
        let fill = select(0.55, 0.7, headline);
        let line = floor(p.y / pitch);
        let ly = fract(p.y / pitch);
        if (ly < fill) {
            let word_w = select(0.03, 0.07, headline);
            let word = floor((cx + hash11(line) * 0.05) / word_w);
            let wx = fract((cx + hash11(line) * 0.05) / word_w);
            let word_len = 0.55 + 0.4 * hash21(vec2f(word, line + col_id * 31.0));
            if (wx < word_len) {
                let glyph = hash21(floor(vec2f(p.x / (pitch * 0.45), p.y / (pitch * 0.25))));
                ink = select(0.55, 0.9, glyph > 0.35);
            }
        }
    }
    let crumple = (noise2(p * 9.0) - 0.5) * 0.35 + (noise2(p * 23.0) - 0.5) * 0.15;
    let paper = 0.86 + crumple;
    return clamp(mix(paper, 0.12, ink), 0.0, 1.0);
}

// One white scratch streak per index: thin slanted segment.
fn scratch(uv: vec2f, aspect: f32, seed: vec2f, top: f32) -> f32 {
    let c = vec2f(hash21(seed), mix(top, 1.0, hash21(seed + 3.1)));
    let ang = radians(-12.0 - 30.0 * hash21(seed + 5.7));
    let dir = vec2f(cos(ang), sin(ang));
    let len = 0.05 + 0.18 * hash21(seed + 7.3);
    let d = (uv - c) * vec2f(aspect, 1.0);
    let along = dot(d, dir);
    let across = abs(dot(d, vec2f(-dir.y, dir.x)));
    let width = 0.0012 + 0.0015 * hash21(seed + 9.9);
    let body = 1.0 - smoothstep(width * 0.5, width, across);
    let ends = 1.0 - smoothstep(len * 0.6, len, abs(along));
    return body * ends * (0.5 + 0.5 * hash21(seed + 13.0));
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
    let px = 1.0 / dims.y;

    var col = textureSampleLevel(first, smp, uv, 0.0).rgb;

    // Newspaper sheets over the first clip.
    if (t >= PAPER_IN && t < PAPER_OUT) {
        let n = clamp(i32(floor((t - PAPER_IN) * STEP_FPS + 0.5)), 0, 18);
        let s = sheet_shape(held_drawing(n));
        let top = s.x + s.y * torn(uv.x, s.w);
        let bottom = s.z + 0.04 * torn(uv.x, s.w + 20.0);
        let a = smoothstep(top - px, top + px, uv.y) * (1.0 - smoothstep(bottom - px, bottom + px, uv.y));
        if (a > 0.0) {
            let grey = newsprint(vec2f(uv.x * aspect, uv.y) * 0.8, s.w);
            // Darker fold shading just under the torn top edge.
            let lip = 1.0 - 0.35 * exp(-max(uv.y - top, 0.0) * 60.0);
            col = mix(col, vec3f(grey * lip), a);
        }
    }

    // The second clip rises behind a torn edge.
    let frame = i32(floor(t * STEP_FPS + 0.5));
    let e = reveal_edge(frame);
    var reveal = 0.0;
    if (frame >= 27) {
        reveal = 1.0;
    } else if (e.x < 1.0) {
        let edge = e.x + e.y * torn(uv.x + 0.31, 40.0 + f32(frame / 2));
        reveal = smoothstep(edge - px, edge + px, uv.y);
    }
    col = mix(col, textureSampleLevel(second, smp, uv, 0.0).rgb, reveal);

    // White scratch streaks, screen-blended.
    if (t >= PAPER_IN && t < SCRATCH_OUT) {
        let n = clamp(i32(floor((t - PAPER_IN) * STEP_FPS + 0.5)), 0, 20);
        let k = held_drawing(n);
        let tops = array<f32, 9>(0.84, 0.79, 0.77, 0.54, 0.44, 0.41, 0.25, 0.2, 0.05);
        let counts = array<i32, 9>(3, 6, 10, 16, 24, 24, 24, 26, 32);
        var lit = 0.0;
        for (var i = 0; i < 32; i++) {
            if (i >= counts[k]) { break; }
            lit = max(lit, scratch(uv, aspect, vec2f(f32(k) * 13.0, f32(i)), tops[k]));
        }
        col = 1.0 - (1.0 - col) * (1.0 - vec3f(lit));
    }

    // Exposure flash: one stop brighter in linear light.
    if (t >= FLASH_IN && t < FLASH_OUT) {
        let lin = pow(clamp(col, vec3f(0.0), vec3f(1.0)), vec3f(2.2)) * 2.0;
        col = pow(lin, vec3f(1.0 / 2.2));
    }
    gpufx_write(id, vec4f(col, 1.0));
}
