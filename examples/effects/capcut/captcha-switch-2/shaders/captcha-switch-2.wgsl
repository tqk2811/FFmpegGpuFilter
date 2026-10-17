// A slider captcha card zooms and fades in, a cursor drags its slider to line up two rotated rings of the second clip, then the card zooms through the screen to reveal it.

// The animation runs over this many seconds of its own clock.
const SPAN: f32 = 2.0;
// The overlay artwork is laid out on a square of this many units, scaled to cover the frame.
const ART: f32 = 512.0;
// Centre of the artwork; the card zooms about this point.
const MID: f32 = 255.5;

// Per-frame (30 fps) card zoom and opacity.
const CARD_SCALE = array<f32, 60>(
    0.791, 0.791, 0.835, 0.878, 0.913, 0.939, 0.965, 0.983, 1.0, 1.0,
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.017, 1.061, 1.122, 1.209, 1.330, 1.487, 1.661, 1.870, 2.104,
    2.383, 2.670, 3.009, 3.374, 3.765, 4.172, 4.636, 5.141, 5.709, 6.337,
    7.004, 8.0, 8.0, 8.0, 8.0, 8.0, 8.0, 8.0, 8.0, 8.0);
const CARD_ALPHA = array<f32, 60>(
    0.0, 0.102, 0.2, 0.302, 0.4, 0.502, 0.6, 0.702, 0.8, 0.902,
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
// Slider knob travel, in card units.
const KNOB_SHIFT = array<f32, 60>(
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 2.0, 9.0, 18.0, 29.0, 41.0, 54.0, 65.0, 74.0, 80.0,
    83.0, 83.0, 83.0, 83.0, 83.0, 83.0, 83.0, 83.0, 83.0, 83.0,
    83.0, 83.0, 83.0, 83.0, 83.0, 83.0, 83.0, 83.0, 83.0, 83.0,
    83.0, 83.0, 83.0, 83.0, 83.0, 83.0, 83.0, 83.0, 83.0, 83.0);
// Cursor top-left corner (xy) and size factor (z, 0 = hidden), in artwork units.
const CURSOR = array<vec3f, 60>(
    vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0),
    vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0),
    vec3f(0.0), vec3f(268.0, 512.0, 1.0), vec3f(255.0, 484.0, 1.0), vec3f(241.0, 456.0, 1.0), vec3f(228.0, 430.0, 1.0),
    vec3f(216.0, 405.0, 1.0), vec3f(205.0, 382.0, 1.0), vec3f(195.0, 364.0, 1.0), vec3f(186.0, 346.0, 1.0), vec3f(181.0, 335.0, 1.0),
    vec3f(179.0, 330.0, 1.0), vec3f(181.0, 330.0, 1.0), vec3f(188.0, 330.0, 1.0), vec3f(197.0, 330.0, 1.0), vec3f(208.0, 330.0, 1.0),
    vec3f(220.0, 330.0, 1.0), vec3f(233.0, 330.0, 1.0), vec3f(244.0, 330.0, 1.0), vec3f(253.0, 330.0, 1.0), vec3f(259.0, 330.0, 1.0),
    vec3f(262.0, 330.0, 1.0), vec3f(260.0, 330.0, 1.147), vec3f(259.0, 334.0, 1.294), vec3f(260.0, 341.0, 1.412), vec3f(260.0, 351.0, 1.588),
    vec3f(261.0, 363.0, 1.735), vec3f(263.0, 377.0, 1.853), vec3f(266.0, 393.0, 1.971), vec3f(269.0, 411.0, 2.088), vec3f(272.0, 430.0, 2.235),
    vec3f(275.0, 450.0, 2.353), vec3f(279.0, 471.0, 2.47), vec3f(283.0, 493.0, 2.59), vec3f(0.0), vec3f(0.0),
    vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0),
    vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0),
    vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0));
// Inner disc while it closes (frames 31..39): radius (x) and centre height (y).
const INNER_CLOSE = array<vec2f, 9>(
    vec2f(33.70, 247.5), vec2f(33.07, 247.5), vec2f(32.18, 247.5), vec2f(30.85, 248.0), vec2f(29.04, 248.5),
    vec2f(26.17, 249.5), vec2f(22.01, 250.5), vec2f(16.35, 251.5), vec2f(8.67, 253.5));

// Card layout, in card units (the artwork at zoom 1).
const CARD_CENTER: vec2f = vec2f(255.75, 255.5);
const CARD_HALF: vec2f = vec2f(100.25, 110.0);
const CARD_ROUND: f32 = 9.5;
const HOLE_CENTER: vec2f = vec2f(255.5, 247.5);
const HOLE_RADIUS: f32 = 57.5;
const BAR_MIN: vec2f = vec2f(174.0, 321.0);
const BAR_MAX: vec2f = vec2f(337.0, 350.0);
const KNOB_MIN: vec2f = vec2f(177.0, 322.0);
const KNOB_MAX: vec2f = vec2f(206.0, 348.0);
const TITLE_MIN: vec2f = vec2f(171.0, 165.0);
const TITLE_MAX: vec2f = vec2f(341.0, 177.0);
const HINT_MIN: vec2f = vec2f(215.0, 332.0);
const HINT_MAX: vec2f = vec2f(329.0, 340.0);
// Rows of the text atlas (in texels of the 1024x96 image).
const TITLE_TEX: vec4f = vec4f(0.0, 0.0, 680.0, 48.0);
const HINT_TEX: vec4f = vec4f(0.0, 56.0, 456.0, 32.0);
// Cursor sprite size at factor 1, in artwork units.
const CURSOR_SIZE: vec2f = vec2f(34.0, 44.0);

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let s = 0.5 * (lo + hi);
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

// Value animated from `a` to `b` between times t0 and t1 with the given easing curve.
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, curve: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, bezier_ease(x, curve));
}

// Signed distance to a rounded box.
fn box_dist(p: vec2f, center: vec2f, half: vec2f, r: f32) -> f32 {
    let q = abs(p - center) - (half - vec2f(r));
    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Coverage of the inside of a distance field, `aa` units wide at the edge.
fn fill(d: f32, aa: f32) -> f32 {
    return clamp(0.5 - d / aa, 0.0, 1.0);
}

// Clip `tex` turned by `deg` degrees (clockwise) and scaled by `k` about the frame centre;
// `w` = 0 where the moved clip leaves the frame.
fn turned(tex: texture_2d<f32>, px: vec2f, dims: vec2f, deg: f32, k: f32) -> vec4f {
    if (k < 1e-4) { return vec4f(0.0); }
    let a = radians(deg);
    let v = (px - 0.5 * dims) / k;
    let src = 0.5 * dims + vec2f(v.x * cos(a) + v.y * sin(a), -v.x * sin(a) + v.y * cos(a));
    let uv = src / dims;
    if (any(uv < vec2f(0.0)) || any(uv > vec2f(1.0))) { return vec4f(0.0); }
    return vec4f(textureSampleLevel(tex, smp, uv, 0.0).rgb, 1.0);
}

// Text atlas coverage for a box of the card.
fn text_mask(p: vec2f, lo: vec2f, hi: vec2f, cell: vec4f) -> f32 {
    let f = (p - lo) / (hi - lo);
    if (any(f < vec2f(0.0)) || any(f > vec2f(1.0))) { return 0.0; }
    let uv = (cell.xy + f * cell.zw) / vec2f(1024.0, 96.0);
    return textureSampleLevel(text, smp, uv, 0.0).a;
}

// Over-composite premultiplied `top` onto `under`.
fn over(under: vec4f, top: vec4f) -> vec4f {
    return top + under * (1.0 - top.a);
}

// The captcha card (premultiplied), drawn at card point `p`, `aa` card units per pixel.
fn card_layer(p: vec2f, aa: f32, knob: f32) -> vec4f {
    // Soft drop shadow, nudged slightly down and right.
    let ds = box_dist(p - vec2f(0.5, 0.8), CARD_CENTER, CARD_HALF, CARD_ROUND);
    let dh = length(p - HOLE_CENTER);
    let open = fill(dh - HOLE_RADIUS, aa);
    var shade = 0.31 * exp(-max(ds, 0.0) * max(ds, 0.0) / 9.0) * (1.0 - open);
    var acc = vec4f(0.0, 0.0, 0.0, shade);

    let body = fill(box_dist(p, CARD_CENTER, CARD_HALF, CARD_ROUND), aa) * (1.0 - open);
    // Bevel just outside the hole: a light lip, then a grey falloff.
    var tone = 1.0;
    if (dh < HOLE_RADIUS + 1.0) { tone = 0.99; } else { tone = mix(0.86, 1.0, smoothstep(HOLE_RADIUS + 1.0, HOLE_RADIUS + 4.5, dh)); }
    let bar = fill(box_dist(p, 0.5 * (BAR_MIN + BAR_MAX), 0.5 * (BAR_MAX - BAR_MIN), 6.0), aa);
    tone = mix(tone, 0.87, bar);
    tone = mix(tone, 0.58, text_mask(p, HINT_MIN, HINT_MAX, HINT_TEX) * bar);
    // Slider knob with a right-pointing arrow.
    let kp = p - vec2f(knob, 0.0);
    let knob_cov = fill(box_dist(kp, 0.5 * (KNOB_MIN + KNOB_MAX), 0.5 * (KNOB_MAX - KNOB_MIN), 5.0), aa);
    tone = mix(tone, 1.0, knob_cov);
    let head = max(max(kp.x - 203.0, 191.0 - kp.x), abs(kp.y - 335.0) - 6.5 * (203.0 - kp.x) / 12.0);
    let shaft = max(max(kp.x - 191.5, 180.0 - kp.x), abs(kp.y - 335.0) - 2.5);
    tone = mix(tone, 0.87, fill(min(head, shaft), aa) * knob_cov);
    tone = mix(tone, 0.23, text_mask(p, TITLE_MIN, TITLE_MAX, TITLE_TEX));
    acc = over(acc, vec4f(vec3f(tone) * body, body));
    return acc;
}

// Thin white ring with a soft dark halo outside it (premultiplied).
fn ring_layer(dist: f32, r: f32, width: f32, aa: f32) -> vec4f {
    let d = dist - r;
    let halo = select(0.0, 0.45 * exp(-0.8 * (d - 0.5 * width) / max(width / 1.3, 1e-3)), d > 0.5 * width);
    let line = clamp((0.5 * width + 0.5 * aa - abs(d)) / aa, 0.0, 1.0);
    return over(vec4f(0.0, 0.0, 0.0, halo), vec4f(vec3f(line), line));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let frame = clamp(i32(floor(t * 30.0 + 0.5)), 0, 59);
    let dims = vec2f(textureDimensions(first));
    let px = uv * dims;

    // Artwork coordinates: the square artwork covers the frame (cropped on the long side).
    let aspect = dims.x / dims.y;
    var q = uv;
    if (aspect < 1.0) { q.x = (uv.x - 0.5) * aspect + 0.5; } else { q.y = (uv.y - 0.5) / aspect + 0.5; }
    q *= ART;
    let aa = ART / max(dims.x, dims.y);

    let zoom = CARD_SCALE[frame];
    let fade = CARD_ALPHA[frame];
    let early = select(1.0, fade, frame < 10);

    // Outer disc: the second clip turned back from +60 degrees.
    let swing = vec4f(0.33333, 0.0, 0.66667, 1.0);
    let turn_outer = keyed(t, 0.666667, 1.0, 60.0, 0.0, swing);
    let outer_c = vec2f(MID, MID - 8.3 * zoom);
    let outer_m = fill(length(q - outer_c) - 64.2 * zoom, aa) * early;
    let a_clip = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b_outer = turned(second, px, dims, turn_outer, 1.0);
    let base1 = mix(a_clip, b_outer.rgb, outer_m * b_outer.a);

    // Inner disc: the second clip turned back from -60 degrees, shrinking away once aligned.
    var inner_r = 0.0;
    var inner_c = vec2f(MID, MID - 8.0 * zoom);
    if (frame <= 30) {
        inner_r = 34.06 * zoom;
    } else if (frame < 40) {
        let e = INNER_CLOSE[frame - 31];
        inner_r = e.x;
        inner_c = vec2f(MID, e.y);
    }
    let turn_inner = keyed(t, 0.666667, 1.0, -60.0, 0.0, swing);
    let shrink = keyed(t, 1.0, 1.333333, 1.0, 0.0, vec4f(0.33333, 0.0, 0.83333, 0.83333));
    let inner_d = length(q - inner_c);
    var color = base1;
    if (inner_r > 0.0) {
        let inner_m = fill(inner_d - inner_r, aa) * early;
        let b_inner = turned(second, px, dims, turn_inner, shrink);
        color = mix(color, b_inner.rgb, inner_m * b_inner.a);
    }

    // Overlay: ring, card, cursor.
    var top = vec4f(0.0);
    if (frame <= 37 && inner_r > 0.0) {
        top = over(top, ring_layer(inner_d, inner_r - 0.2, 1.3 * zoom, aa));
    }
    if (fade > 0.0) {
        let p = vec2f(MID) + (q - vec2f(MID)) / zoom;
        top = over(top, card_layer(p, aa / zoom, KNOB_SHIFT[frame]));
    }
    let cur = CURSOR[frame];
    if (cur.z > 0.0) {
        let f = (q - cur.xy) / (CURSOR_SIZE * cur.z);
        if (all(f >= vec2f(0.0)) && all(f <= vec2f(1.0))) {
            let s = textureSampleLevel(hand, smp, f, 0.0);
            top = over(top, vec4f(s.rgb * s.a, s.a));
        }
    }
    top *= fade;
    gpufx_write(id, vec4f(top.rgb + color * (1.0 - top.a), 1.0));
}
