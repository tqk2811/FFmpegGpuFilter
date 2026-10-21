// Pass 1 of CRT 2 Digital: the first clip cut to the TV screen, bent, and run through a degraded-video-signal look (smear, edge rainbows, hue-shifted rows).

// The whole animation spans this many seconds of comp time.
const SPAN: f32 = 2.5;
// The screen cut-out is handed to its second, floor-bound copy at this comp time.
const HANDOFF: f32 = 0.96667;
// Glitch pixel unit: 1/720 of the (square) layer.
const STEP: f32 = 0.0013888889;

// Screen rectangle of the TV at rest, in 1000-px comp units, and its rounded-corner radius.
const SCREEN_MIN: vec2f = vec2f(344.0, 384.0);
const SCREEN_MAX: vec2f = vec2f(646.0, 610.0);
const SCREEN_RADIUS: f32 = 10.0;
const REST_CENTER: vec2f = vec2f(494.5, 497.0);

// Camera pull-back at the start, sampled at 30 fps (frames 0..16): zoom and screen centre.
const PULL_ZOOM = array<f32, 17>(4.6, 4.36, 4.04, 3.566, 3.088, 2.664, 2.305, 2.013, 1.779,
    1.504, 1.372, 1.261, 1.173, 1.106, 1.053, 1.018, 1.0);
const PULL_CX = array<f32, 17>(480.0, 480.0, 480.0, 481.0, 483.0, 485.0, 487.0, 488.5, 490.0,
    491.5, 492.0, 493.0, 493.5, 493.5, 494.0, 494.5, 494.5);
const PULL_CY = array<f32, 17>(494.0, 493.0, 488.5, 490.0, 491.0, 492.0, 493.5, 494.5, 495.0,
    496.0, 496.0, 496.5, 496.5, 497.0, 497.0, 497.0, 497.0);

fn ramp(t: f32, t0: f32, t1: f32) -> f32 {
    return clamp((t - t0) / (t1 - t0), 0.0, 1.0);
}

// Comp-space (0..1 square) position -> uv of the input frame (the square comp covers the frame).
fn comp_to_frame(q: vec2f) -> vec2f {
    let ratio = globals.size.x * globals.pixel_aspect / globals.size.y;
    if (ratio >= 1.0) { return vec2f(q.x, 0.5 + (q.y - 0.5) * ratio); }
    return vec2f(0.5 + (q.x - 0.5) / ratio, q.y);
}

// Rounded-rectangle coverage of the screen at video frame `f` of the pull-back, comp pixels.
fn screen_cover(px: vec2f, f: f32, aa: f32) -> f32 {
    let x = clamp(f, 0.0, 16.0);
    let i = min(u32(floor(x)), 15u);
    let w = x - f32(i);
    let zoom = mix(PULL_ZOOM[i], PULL_ZOOM[i + 1u], w);
    let center = vec2f(mix(PULL_CX[i], PULL_CX[i + 1u], w), mix(PULL_CY[i], PULL_CY[i + 1u], w));
    let half_size = (SCREEN_MAX - SCREEN_MIN) * 0.5 * zoom;
    let mid = center + ((SCREEN_MIN + SCREEN_MAX) * 0.5 - REST_CENTER) * zoom;
    let r = SCREEN_RADIUS * zoom;
    let d = abs(px - mid) - (half_size - vec2f(r));
    let dist = length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0) - r;
    return 1.0 - smoothstep(-aa, aa, dist);
}

// Arc bend of the layer (inverse mapping): returns the source position, y measured up.
fn arc_source(p: vec2f, bend: f32) -> vec2f {
    let k = 1.0 / pow(clamp(abs(bend), 1e-5, 1.0), 0.57) - 1.0;
    let x = p.x - 0.5;
    var y = p.y;
    if (bend < 0.0) { y = 1.0 - y; }
    y += k;
    let half_angle = atan2(0.5, k);
    var ny = length(vec2f(x, y)) - (sqrt(0.25 + k * k) - k) - k;
    if (bend < 0.0) { ny = 1.0 - ny; }
    let nx = 1.0 - (atan2(y, x) - (1.5707964 - half_angle)) / (half_angle * 2.0);
    return vec2f(nx, ny);
}

struct Look {
    bend: f32,
    smear: f32,
    hue_rows: f32,
    signal: f32,
};

fn look_at(t: f32) -> Look {
    var l: Look;
    if (t < HANDOFF) {
        l.bend = -0.65333 * ramp(t, 0.6, 1.1);
        l.smear = mix(0.01, 0.8, ramp(t, 0.0, 0.6));
        l.hue_rows = 0.62 * ramp(t, 0.0, 0.6);
        l.signal = 1.0;
    } else {
        l.bend = 0.5 * ramp(t, 0.6, 1.1);
        let g = ramp(t, 1.1, 1.6);
        l.smear = mix(0.01, 0.8, g);
        l.hue_rows = 0.62 * g;
        l.signal = mix(1.0, 0.2, g);
    }
    return l;
}

// The bent, screen-masked first clip (premultiplied), at layer position q (0..1, y down).
fn layer_at(q: vec2f, bend: f32, f: f32, aa: f32) -> vec4f {
    var src = q;
    if (abs(bend) > 1e-3) {
        let s = arc_source(vec2f(q.x, 1.0 - q.y), bend);
        if (any(s < vec2f(0.0)) || any(s > vec2f(1.0))) { return vec4f(0.0); }
        src = vec2f(s.x, 1.0 - s.y);
    }
    let cover = screen_cover(src * 1000.0, f, aa);
    if (cover <= 0.0) { return vec4f(0.0); }
    let c = textureSampleLevel(first, smp, comp_to_frame(src), 0.0).rgb;
    return vec4f(c * cover, cover);
}

fn to_ycc(c: vec3f) -> vec3f {
    let y = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
    return vec3f(y, (c.b - y) * 0.565, (c.r - y) * 0.713);
}
fn from_ycc(c: vec3f) -> vec3f {
    return vec3f(c.x + 1.403 * c.z, c.x - 0.344 * c.y - 0.714 * c.z, c.x + 1.77 * c.y);
}
fn luma(c: vec3f) -> f32 {
    return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
}

// Small fract-based hash of a 2-D input (no trigonometry), 0..1.
fn row_hash(p: vec2f) -> f32 {
    var a = fract(p * 1324.5179);
    a += vec2f(dot(a, a.yx + vec2f(22.541)));
    return fract((a.x + a.y) * a.y);
}

fn rgb_to_hsl(c: vec3f) -> vec3f {
    let lo = min(min(c.r, c.g), c.b);
    let hi = max(max(c.r, c.g), c.b);
    let span = hi - lo;
    var hsl = vec3f(0.0, 0.0, (hi + lo) * 0.5);
    if (span > 0.0) {
        if (hsl.z < 0.5) { hsl.y = span / (hi + lo); } else { hsl.y = span / max(2.0 - hi - lo, 1e-6); }
        let dr = ((hi - c.r) / 6.0 + span * 0.5) / span;
        let dg = ((hi - c.g) / 6.0 + span * 0.5) / span;
        let db = ((hi - c.b) / 6.0 + span * 0.5) / span;
        if (c.r == hi) { hsl.x = db - dg; }
        else if (c.g == hi) { hsl.x = 0.33333334 + dr - db; }
        else { hsl.x = 0.6666667 + dg - dr; }
        hsl.x = fract(hsl.x);
    }
    return hsl;
}
fn hue_rgb(h: f32) -> vec3f {
    let x = fract(h) * 6.0;
    return clamp(vec3f(abs(x - 3.0) - 1.0, 2.0 - abs(x - 2.0), 2.0 - abs(x - 4.0)), vec3f(0.0), vec3f(1.0));
}
fn hsl_to_rgb(hsl: vec3f) -> vec3f {
    if (hsl.y == 0.0) { return vec3f(hsl.z); }
    var b: f32;
    if (hsl.z < 0.5) { b = hsl.z * (1.0 + hsl.y); } else { b = hsl.z + hsl.y - hsl.y * hsl.z; }
    let a = 2.0 * hsl.z - b;
    return vec3f(a) + hue_rgb(hsl.x) * (b - a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let q = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let f = t * 30.0;
    let lk = look_at(t);
    let aa = 1000.0 / min(globals.size.x, globals.size.y);

    // Smeared, over-sharpened low-quality look: trailing 9-tap average to the left.
    let base = layer_at(q, lk.bend, f, aa);
    var trail = base;
    var near = base;
    var tail = base;
    for (var i = 1; i <= 8; i++) {
        let s = layer_at(q - vec2f(f32(i) * STEP, 0.0), lk.bend, f, aa);
        trail += s;
        if (i <= 5) { near += s; }
        if (i == 8) { tail = s; }
    }
    var sharp = clamp(base + (base - trail / 9.0) * 0.6, vec4f(0.0), vec4f(1.0));
    var ycc = to_ycc(sharp.rgb);
    ycc = vec3f(ycc.x, mix(ycc.yz, to_ycc(tail.rgb).yz, vec2f(0.6)));
    sharp = vec4f(clamp(from_ycc(ycc), vec3f(0.0), vec3f(sharp.a)), sharp.a);
    var col = mix(base, sharp, lk.smear);

    // Mild luma sharpening against a 6-tap trailing average (strength 0.01 x 40).
    let avg = near / 6.0;
    var y2 = to_ycc(col.rgb);
    let ya = to_ycc(avg.rgb);
    y2 = vec3f(y2.x + (y2.x - ya.x) * 0.4, mix(y2.yz, ya.yz, vec2f(0.05)));
    col = vec4f(from_ycc(y2), col.a);

    // Signal edges: strongest horizontal luma step within -10..30 units, tinted by its position.
    if (lk.signal < 0.999) {
        var best = 0.0;
        var at = q.x;
        for (var k = -10; k <= 30; k += 2) {
            let a = layer_at(q - vec2f(f32(k + 1) * STEP, 0.0), lk.bend, f, aa).rgb;
            let b = layer_at(q - vec2f(f32(k - 1) * STEP, 0.0), lk.bend, f, aa).rgb;
            let g = abs(luma(a - b));
            if (g >= best) { at = q.x - f32(k) * STEP; }
            best = max(best, g);
        }
        let vy = 1.0 - q.y;
        let ahead = max(0.0, 1.0 - step(q.x, at) * (at - q.x) / STEP / 10.0);
        let behind = max(0.0, 1.0 - step(at, q.x) * (q.x - at) / STEP / 30.0);
        let strength = clamp(pow(min(0.4, best) * ahead * behind, 1.2 + row_hash(vec2f(vy)) * lk.signal), 0.0, 1.0);
        let tint = hue_rgb(fract(clamp(at, 0.0, 1.0) * 40.27)) * 0.8;
        col = vec4f(mix(col.rgb, tint, min(1.0, strength * 2.0) * (1.0 - lk.signal)), col.a);
    }
    col = clamp(col, vec4f(0.0), vec4f(1.0));

    // Hue-shifted rows: each pixel row may take a random hue, re-rolled as the amount changes.
    if (lk.hue_rows > 0.0) {
        let seed = lk.hue_rows;
        let vy = 1.0 - q.y;
        var hsl = rgb_to_hsl(col.rgb);
        if (row_hash(vec2f(seed, vy)) * 0.99 + 0.001 < lk.hue_rows) {
            hsl.x = row_hash(vec2f(seed + 17.0, vy)) * 0.99 + 0.001;
            hsl.y *= 1.0 - lk.hue_rows / 3.0;
        }
        col = vec4f(mix(col.rgb, hsl_to_rgb(hsl), lk.hue_rows), col.a);
    }
    gpufx_write(id, col);
}
