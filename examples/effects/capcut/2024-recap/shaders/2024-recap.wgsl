// The first clip shrinks into a rounded photo card on a phone chat screen with confetti and a greeting bubble, slides aside for the second card, which then grows back to full frame under red fireworks.

// Animation time runs over this many seconds as progress goes from 0 to 1.
const SPAN: f32 = 2.0;
// Reference canvas the card keyframes were laid out on (pixels).
const REF: vec2f = vec2f(1080.0, 1920.0);
// Pivot of every card on that canvas (pixels).
const CARD_PIVOT: vec2f = vec2f(578.5714, 1872.3404);
// Shared parent the cards hang from: position (pixels) and scale.
const PARENT_POS: vec2f = vec2f(688.0, 888.0);
const PARENT_SCALE: f32 = 0.744;
// Card placements (pixels, percent).
const FULL_POS: vec2f = vec2f(-147.563791, 1323.517884);
const FULL_SCALE: f32 = 134.6;
const REST_POS: vec2f = vec2f(44.46094, 693.74154);
const REST_SCALE: f32 = 74.677;
const ASIDE_POS: vec2f = vec2f(-215.582071, 699.117884);
// Corner radius of a card, in 1/256 of its half short edge.
const CORNER: f32 = 54.0;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, x1: f32, y1: f32, x2: f32, y2: f32) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * x1 + 3.0 * inv * s * s * x2 + s * s * s;
        let dx = 3.0 * inv * inv * x1 + 6.0 * inv * s * (x2 - x1) + 3.0 * s * s * (1.0 - x2);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * y1 + 3.0 * inv * s * s * y2 + s * s * s;
}

// Smooth in-out step between t0 and t1 (0 before, 1 after).
fn glide(t: f32, t0: f32, t1: f32) -> f32 {
    return bezier_ease(clamp((t - t0) / (t1 - t0), 0.0, 1.0), 0.33333, 0.0, 0.66667, 1.0);
}

// Pixel position on the reference canvas -> centred frame space (x spans -aspect..aspect, y up).
fn ref_point(p: vec2f, aspect: f32) -> vec2f {
    return vec2f((p.x / REF.x - 0.5) * 2.0 * aspect, (0.5 - p.y / REF.y) * 2.0);
}

struct Card {
    pos: vec2f,    // pixels on the reference canvas
    scale: f32,    // percent
    angle: f32,    // degrees, clockwise
    radius: f32,   // corner radius, 0..256
}

// Where a frame-space point lands inside a card, as a texture uv (outside 0..1 = off the card).
fn card_uv(w: vec2f, c: Card, aspect: f32) -> vec2f {
    let parent_anchor = vec2f(aspect, -1.0);
    var q = (w - ref_point(PARENT_POS, aspect)) / PARENT_SCALE - parent_anchor - ref_point(c.pos, aspect);
    let a = radians(c.angle);
    q = vec2f(cos(a) * q.x - sin(a) * q.y, sin(a) * q.x + cos(a) * q.y);
    let m = q / (c.scale / 100.0) + ref_point(CARD_PIVOT, aspect);
    let local = vec2f(m.x / aspect, m.y);
    return vec2f(local.x * 0.5 + 0.5, 0.5 - local.y * 0.5);
}

// Frame space for an output uv, normalised so the full-frame card placement maps exactly onto the frame.
fn frame_point(uv: vec2f, aspect: f32) -> vec2f {
    let full = Card(FULL_POS, FULL_SCALE, 0.0, 0.0);
    let c0 = card_uv(vec2f(0.0), full, aspect);
    let c1 = card_uv(vec2f(aspect, 1.0), full, aspect);
    // card_uv is affine without rotation: solve for the frame point that hits `uv`.
    let span = c1 - c0;
    return vec2f((uv.x - c0.x) / span.x * aspect, (uv.y - c0.y) / span.y);
}

// Coverage of a rounded card at `uv` (texture size `px`), anti-aliased over about one texel.
fn card_mask(uv: vec2f, px: vec2f, radius: f32) -> f32 {
    let half = px * 0.5;
    let r = min(half.x, half.y) * radius / 256.0;
    let d = abs(uv * px - half) - (half - vec2f(r));
    let dist = length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0) - r;
    return clamp(0.5 - dist, 0.0, 1.0);
}

// Cheap hash in [0,1).
fn hash11(n: f32) -> f32 {
    return fract(sin(n * 127.1) * 43758.5453);
}

// Paper confetti falling from the top right over the white screen.
fn confetti(px: vec2f, size: vec2f, t: f32) -> vec4f {
    let unit = min(size.x, size.y);
    var acc = vec4f(0.0);
    for (var i = 0; i < 90; i++) {
        let fi = f32(i);
        let born = hash11(fi + 3.1) * 1.4;
        let age = t - born;
        if (age <= 0.0) { continue; }
        let start = vec2f(size.x * (0.35 + 0.75 * hash11(fi + 7.7)), -0.05 * size.y);
        let drift = vec2f(-0.25 - 0.3 * hash11(fi + 1.3), 0.35 + 0.4 * hash11(fi + 5.9)) * unit;
        let sway = vec2f(sin(age * 6.0 + fi) * 0.02 * unit, 0.0);
        let centre = start + drift * age + vec2f(0.0, 0.25 * unit) * age * age + sway;
        let spin = age * (4.0 + 6.0 * hash11(fi + 9.2)) + fi;
        var d = px - centre;
        d = vec2f(cos(spin) * d.x - sin(spin) * d.y, sin(spin) * d.x + cos(spin) * d.y);
        let half = vec2f(0.006, 0.0025 + 0.002 * abs(sin(spin * 1.7))) * unit;
        let e = abs(d) - half;
        let cover = clamp(0.5 - max(e.x, e.y), 0.0, 1.0);
        if (cover <= 0.0) { continue; }
        let pick = hash11(fi + 11.4);
        var col = vec3f(0.95, 0.25, 0.4);
        if (pick > 0.66) { col = vec3f(1.0, 0.82, 0.25); } else if (pick > 0.33) { col = vec3f(0.35, 0.8, 0.95); }
        acc = vec4f(mix(acc.rgb, col, cover), max(acc.a, cover));
    }
    return acc;
}

// Rounded-rectangle signed distance (pixels).
fn rbox(p: vec2f, half: vec2f, r: f32) -> f32 {
    let d = abs(p) - half + vec2f(r);
    return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0) - r;
}

// Chat input bar along the bottom: camera button, apps button and the message field with its send button.
fn chat_bar(px: vec2f, size: vec2f, base: vec3f) -> vec3f {
    let unit = min(size.x, size.y);
    let y = size.y - 0.067 * unit;
    let grey = vec3f(0.36, 0.36, 0.38);
    var col = base;
    // Camera: rounded body with a lens ring.
    let cam = px - vec2f(0.075 * unit, y);
    let body = rbox(cam, vec2f(0.026, 0.019) * unit, 0.005 * unit);
    col = mix(col, grey, clamp(0.5 - body, 0.0, 1.0));
    let lens = abs(length(cam) - 0.009 * unit) - 0.0025 * unit;
    col = mix(col, base, clamp(0.5 - min(lens, length(cam) - 0.004 * unit), 0.0, 1.0));
    // Apps: grey disc with a white letter-like mark.
    let app = px - vec2f(0.215 * unit, y);
    col = mix(col, grey, clamp(0.5 - (length(app) - 0.026 * unit), 0.0, 1.0));
    let stroke = 0.0035 * unit;
    let leg1 = abs(dot(app, normalize(vec2f(0.94, 0.34)))) - stroke;
    let leg2 = abs(dot(app, normalize(vec2f(0.94, -0.34)))) - stroke;
    let bar = abs(app.y - 0.006 * unit) - stroke;
    let inside = length(app) - 0.017 * unit;
    let mark = max(min(min(leg1, leg2), bar), inside);
    col = mix(col, vec3f(1.0), clamp(0.5 - mark, 0.0, 1.0));
    // Message field: pill outline with a green send button at the right end.
    let left = 0.30 * unit;
    let right = size.x - 0.03 * unit;
    let field = px - vec2f((left + right) * 0.5, y);
    let half = vec2f((right - left) * 0.5, 0.03 * unit);
    let ring = abs(rbox(field, half, half.y)) - 0.0018 * unit;
    col = mix(col, vec3f(0.78, 0.78, 0.8), clamp(0.5 - ring, 0.0, 1.0));
    let send = px - vec2f(right - 0.032 * unit, y);
    col = mix(col, vec3f(0.55, 0.85, 0.6), clamp(0.5 - (length(send) - 0.021 * unit), 0.0, 1.0));
    let shaft = rbox(send - vec2f(0.0, 0.002 * unit), vec2f(0.0022, 0.010) * unit, 0.002 * unit);
    let head = max(abs(send.x) * 0.8 + (send.y + 0.009 * unit) * 0.6 - 0.005 * unit, -(send.y + 0.012 * unit));
    col = mix(col, vec3f(1.0), clamp(0.5 - min(shaft, max(head, send.y - 0.002 * unit)), 0.0, 1.0));
    return col;
}

// Greeting bubble in the top-left corner: slides up and fades in early on.
fn greeting(px: vec2f, size: vec2f, t: f32) -> vec4f {
    let show = clamp((t - 0.36) / 0.2, 0.0, 1.0);
    if (show <= 0.0) { return vec4f(0.0); }
    let unit = min(size.x, size.y);
    let w = 0.30 * unit;
    let box_size = vec2f(w, w * 0.25);
    let origin = vec2f(0.055 * unit, 0.045 * unit + (1.0 - show) * 0.012 * unit);
    let uv = (px - origin) / box_size;
    if (any(uv < vec2f(0.0)) || any(uv > vec2f(1.0))) { return vec4f(0.0); }
    let c = textureSampleLevel(bubble, smp, uv, 0.0);
    return vec4f(c.rgb, c.a * show);
}

// One firework burst: a ring of sparks that expands and fades; returns screen-blend light.
fn burst(px: vec2f, centre: vec2f, reach: f32, t: f32, t0: f32, seed: f32) -> vec3f {
    let age = (t - t0) / 1.0;
    if (age <= 0.0 || age >= 1.0) { return vec3f(0.0); }
    let grow = 1.0 - (1.0 - age) * (1.0 - age) * (1.0 - age);
    let d = px - centre;
    let r = length(d) / reach;
    let ang = atan2(d.y, d.x);
    let rays = 48.0;
    let cell = floor(ang / 6.28318 * rays + 0.5);
    let jitter = hash11(cell + seed);
    let ring = grow * (0.75 + 0.25 * jitter);
    let spark = exp(-((r - ring) / 0.035) * ((r - ring) / 0.035)) * step(0.5, fract(r * 14.0 + jitter * 3.0) + 0.3);
    let core = exp(-pow(r / (0.6 * grow + 0.05), 2.0)) * 0.25 * (1.0 - age);
    let fade = (1.0 - age) * (1.0 - age);
    let tint = mix(vec3f(1.0, 0.12, 0.2), vec3f(1.0, 0.5, 0.7), jitter);
    return tint * (spark + core) * fade * 2.4;
}

fn fireworks(px: vec2f, size: vec2f, t: f32) -> vec3f {
    let unit = min(size.x, size.y);
    var light = burst(px, size * vec2f(0.32, 0.22), 0.21 * unit, t, 0.55, 1.0);
    light += burst(px, size * vec2f(0.68, 0.16), 0.26 * unit, t, 0.85, 7.0);
    light += burst(px, size * vec2f(0.30, 0.72), 0.28 * unit, t, 0.95, 13.0);
    // Everything has burnt out by the end.
    return light * (1.0 - glide(t, 1.7, 2.0));
}

fn card_over(col: vec3f, w: vec2f, c: Card, aspect: f32, clip_is_second: bool, px_size: vec2f) -> vec3f {
    let uv = card_uv(w, c, aspect);
    if (any(uv < vec2f(-0.01)) || any(uv > vec2f(1.01))) { return col; }
    let cover = card_mask(clamp(uv, vec2f(0.0), vec2f(1.0)), px_size, c.radius) * step(-0.001, min(uv.x, uv.y)) * step(max(uv.x, uv.y), 1.001);
    var tex: vec3f;
    if (clip_is_second) {
        tex = textureSampleLevel(second, smp, clamp(uv, vec2f(0.0), vec2f(1.0)), 0.0).rgb;
    } else {
        tex = textureSampleLevel(first, smp, clamp(uv, vec2f(0.0), vec2f(1.0)), 0.0).rgb;
    }
    return mix(col, tex, cover);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let size = globals.size.xy;
    let aspect = size.x / size.y;
    let px = uv * size;
    let w = frame_point(uv, aspect);

    // Phone screen: white page with confetti and the greeting, chat bar at the bottom.
    var col = vec3f(1.0);
    let paper = confetti(px, size, t);
    col = mix(col, paper.rgb, paper.a);
    let hello = greeting(px, size, t);
    col = mix(col, hello.rgb, hello.a);
    col = chat_bar(px, size, col);

    // First clip card shrinking from full frame, then sliding aside (drawn above the second until 0.72 s).
    let shrink = glide(t, 0.2, 0.56);
    let first_front = Card(
        mix(mix(FULL_POS, REST_POS, shrink), ASIDE_POS, glide(t, 0.56, 0.72)),
        mix(FULL_SCALE, REST_SCALE, shrink), 0.0, CORNER * glide(t, 0.2, 0.28));
    // Later the first card slides back to the middle, now underneath the second.
    let first_back = Card(mix(ASIDE_POS, REST_POS, glide(t, 0.72, 1.08)), REST_SCALE, 0.0, CORNER);
    // Second clip card: tilted and slightly smaller behind, settles, then grows to full frame.
    let settle = glide(t, 1.16, 1.24);
    let grow = glide(t, 1.24, 1.56);
    let second_card = Card(
        mix(mix(vec2f(44.46094, 676.74154), REST_POS, settle), FULL_POS, grow),
        mix(mix(72.477, REST_SCALE, settle), FULL_SCALE, grow),
        mix(3.3, 0.0, settle),
        CORNER * (1.0 - glide(t, 1.494102, 1.56)));

    let dims = vec2f(textureDimensions(first));
    if (t >= 0.72) { col = card_over(col, w, first_back, aspect, false, dims); }
    col = card_over(col, w, second_card, aspect, true, dims);
    if (t < 0.72) { col = card_over(col, w, first_front, aspect, false, dims); }

    // Fireworks screened over everything.
    let light = clamp(fireworks(px, size, t), vec3f(0.0), vec3f(1.0));
    col = 1.0 - (1.0 - col) * (1.0 - light);
    gpufx_write(id, vec4f(col, 1.0));
}
