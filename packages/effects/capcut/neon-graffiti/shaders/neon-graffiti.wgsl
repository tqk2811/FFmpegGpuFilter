// Yellow neon scribbles flicker over the first clip, which jolts and stretches into a white flash; the second clip snaps back into place under the fading glow.

// The animation runs over one second of timeline, whatever the real length.
const TIMELINE: f32 = 1.0;
// The scribble overlay is drawn at this many frames per second of timeline.
const SKETCH_FPS: f32 = 24.0;
// The picture switches clips at this time.
const SWAP_AT: f32 = 0.6666667;
// Layout canvas (portrait) used for the jolt offsets, in pixels.
const CANVAS: vec2f = vec2f(504.0, 672.0);
const NEON: vec3f = vec3f(1.0, 0.93, 0.35);

// CSS-like cubic-bezier easing through (0,0) (x1,y1) (x2,y2) (1,1), solved for x by bisection.
fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(e: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 22; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(e.x, e.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(e.y, e.w, 0.5 * (lo + hi));
}

fn span01(t: f32, t0: f32, t1: f32) -> f32 { return clamp((t - t0) / (t1 - t0), 0.0, 1.0); }

// Point on a cubic path from a to d with handles b and c.
fn path(a: vec2f, b: vec2f, c: vec2f, d: vec2f, s: f32) -> vec2f {
    let r = 1.0 - s;
    return a * r * r * r + b * 3.0 * r * r * s + c * 3.0 * r * s * s + d * s * s * s;
}

fn cross2(a: vec2f, b: vec2f) -> f32 { return a.x * b.y - a.y * b.x; }

// Inverse of the bilinear map with corners p00 (u0,v0), p10, p01, p11; returns (-1,-1) when it has no solution.
fn unbilinear(p: vec2f, p00: vec2f, p10: vec2f, p01: vec2f, p11: vec2f) -> vec2f {
    let e = p10 - p00;
    let f = p01 - p00;
    let g = p00 - p10 - p01 + p11;
    let h = p - p00;
    let k2 = cross2(f, g);
    let k1 = cross2(e, f) + cross2(h, g);
    let k0 = cross2(h, e);
    var v = 0.0;
    if (abs(k2) < 1e-6) {
        if (abs(k1) < 1e-8) { return vec2f(-1e9); }
        v = -k0 / k1;
    } else {
        let disc = k1 * k1 - 4.0 * k0 * k2;
        if (disc < 0.0) { return vec2f(-1e9); }
        let w = sqrt(disc);
        v = (-k1 - w) / (2.0 * k2);
        if (v < 0.0 || v > 1.0) { v = (-k1 + w) / (2.0 * k2); }
    }
    let den = e + g * v;
    var u = 0.0;
    if (abs(den.x) >= abs(den.y) && abs(den.x) > 1e-8) {
        u = (h.x - f.x * v) / den.x;
    } else if (abs(den.y) > 1e-8) {
        u = (h.y - f.y * v) / den.y;
    } else {
        return vec2f(-1e9);
    }
    return vec2f(u, v);
}

// Corners (bottom-up: bottom left, bottom right, top left, top right) of the outgoing stretch towards the top right.
fn corners_out(s: f32) -> array<vec2f, 4> {
    return array<vec2f, 4>(
        path(vec2f(0.0, 0.0), vec2f(-0.08796, -0.00645), vec2f(-0.43981, -0.03224), vec2f(-0.52778, -0.03869), s),
        path(vec2f(1.0, 0.0), vec2f(1.01058, -0.01438), vec2f(1.05291, -0.07192), vec2f(1.06349, -0.08631), s),
        path(vec2f(0.0, 1.0), vec2f(-0.03968, 1.00198), vec2f(-0.19841, 1.00992), vec2f(-0.23810, 1.01190), s),
        path(vec2f(1.0, 1.0), vec2f(1.14947, 1.02629), vec2f(1.74735, 1.13145), vec2f(1.89683, 1.15774), s),
    );
}

// Corners of the incoming clip settling from its own skew back to the plain frame.
fn corners_in(s: f32) -> array<vec2f, 4> {
    return array<vec2f, 4>(
        path(vec2f(-0.90476, -0.11607), vec2f(-0.75397, -0.09673), vec2f(-0.15079, -0.01935), vec2f(0.0, 0.0), s),
        path(vec2f(1.33730, -0.125), vec2f(1.28108, -0.10417), vec2f(1.05622, -0.02083), vec2f(1.0, 0.0), s),
        vec2f(0.0, 1.0),
        path(vec2f(1.54762, 1.19048), vec2f(1.45635, 1.15873), vec2f(1.09127, 1.03175), vec2f(1.0, 1.0), s),
    );
}

// Jolt of the outgoing clip: canvas position of its centre, and its scale.
fn jolt_out(t: f32) -> vec3f {
    var pos = vec2f(252.0, 336.0);
    if (t >= 0.458333) { pos = mix(vec2f(252.0, 336.0), vec2f(266.0, 296.0), span01(t, 0.458333, 0.5)); }
    if (t >= 0.5) { pos = mix(vec2f(266.0, 296.0), vec2f(204.0, 396.0), span01(t, 0.5, 0.541667)); }
    if (t >= 0.541667) { pos = mix(vec2f(204.0, 396.0), vec2f(266.0, 332.0), span01(t, 0.541667, 0.583333)); }
    if (t >= 0.583333) { pos = mix(vec2f(266.0, 332.0), vec2f(224.0, 322.0), span01(t, 0.583333, 0.625)); }
    let scale = mix(1.0, 1.25, span01(t, 0.458333, 0.5));
    return vec3f(pos, scale);
}

fn jolt_in(t: f32) -> vec3f {
    var pos = mix(vec2f(224.0, 338.0), vec2f(265.0, 351.0), span01(t, 0.666667, 0.708333));
    if (t >= 0.708333) { pos = mix(vec2f(265.0, 351.0), vec2f(252.0, 336.0), span01(t, 0.708333, 0.75)); }
    let scale = mix(1.2, 1.0, span01(t, 0.666667, 0.75));
    return vec3f(pos, scale);
}

// Reads one clip through its jolt and corner stretch; edge pixels outside the picture.
fn shaped(tex: texture_2d<f32>, uv: vec2f, jolt: vec3f, c: array<vec2f, 4>) -> vec3f {
    // Undo the move and the scale about the canvas centre (top-down fractions).
    let centre = jolt.xy / CANVAS;
    let q = (uv - centre) / jolt.z + vec2f(0.5);
    // Undo the corner stretch in bottom-up space.
    let st = unbilinear(vec2f(q.x, 1.0 - q.y), c[0], c[1], c[2], c[3]);
    if (st.x < -1e8) { return vec3f(0.0); }
    // Outside the picture the border pixels stretch outwards.
    let c01 = clamp(st, vec2f(0.0), vec2f(1.0));
    return textureSampleLevel(tex, smp, vec2f(c01.x, 1.0 - c01.y), 0.0).rgb;
}

fn hash11(x: f32) -> f32 { return fract(sin(x * 127.1) * 43758.5453); }

// Glow of one hand-drawn stroke from a to b (frame fractions), wobbling with `seed`.
fn stroke(p: vec2f, a: vec2f, b: vec2f, seed: f32, aspect: f32) -> f32 {
    let sc = vec2f(aspect, 1.0);
    let pa = (p - a) * sc;
    let ba = (b - a) * sc;
    let len = max(length(ba), 1e-4);
    let h = clamp(dot(pa, ba) / (len * len), 0.0, 1.0);
    let n = vec2f(-ba.y, ba.x) / len;
    let rel = pa - ba * h;
    let wob = 0.012 * sin(h * 9.0 + seed * 6.0) + 0.006 * sin(h * 23.0 + seed * 13.0);
    let across = dot(rel, n) - wob;
    let along = dot(rel, ba / len);
    let dist = sqrt(across * across + along * along);
    return smoothstep(0.004, 0.0015, dist) + 0.35 * exp(-dist / 0.01);
}

// Neon scribbles for one overlay frame.
fn scribbles(p: vec2f, frame: i32, aspect: f32) -> f32 {
    var g = 0.0;
    if (frame >= 1 && frame <= 2) {
        // Hatching across the lower left and two long slashes.
        for (var i = 0; i < 7; i++) {
            let fi = f32(i);
            let y = 0.62 + fi * 0.035;
            g += stroke(p, vec2f(0.0, y + 0.04), vec2f(0.95 - fi * 0.08, y - 0.18 + hash11(fi) * 0.05), fi, aspect);
        }
        g += stroke(p, vec2f(0.38, 0.0), vec2f(0.95, 0.95), 7.0, aspect);
        g += stroke(p, vec2f(0.45, 0.02), vec2f(1.0, 0.9), 8.0, aspect);
    }
    if ((frame >= 5 && frame <= 10) || (frame >= 17 && frame <= 20)) {
        // A cross at the top right and slashes at the lower corners.
        g += stroke(p, vec2f(0.55, 0.27), vec2f(1.0, 0.17), 9.0, aspect);
        g += stroke(p, vec2f(0.58, 0.24), vec2f(0.98, 0.15), 10.0, aspect);
        g += stroke(p, vec2f(0.96, 0.0), vec2f(0.68, 0.45), 11.0, aspect);
        g += stroke(p, vec2f(0.0, 0.42), vec2f(0.22, 1.0), 12.0, aspect);
        g += stroke(p, vec2f(0.0, 0.62), vec2f(0.12, 1.0), 13.0, aspect);
        g += stroke(p, vec2f(0.7, 0.78), vec2f(1.0, 0.95), 14.0, aspect);
    }
    if (frame >= 10 && frame <= 12) {
        // A star burst around the middle.
        let c = vec2f(0.45, 0.55);
        for (var i = 0; i < 8; i++) {
            let a = f32(i) * 0.785398 + 0.3;
            let dir = vec2f(cos(a) / aspect, sin(a)) * (0.12 + 0.08 * hash11(f32(i) + 20.0));
            g += stroke(p, c - dir, c + dir, f32(i) + 20.0, aspect);
        }
    }
    return g;
}

// Strength of the white-yellow haze that builds into the flash and fades over the incoming clip.
fn haze(t: f32) -> f32 {
    if (t < 0.458333) { return 0.0; }
    if (t < 0.625) { return mix(0.3, 0.85, span01(t, 0.458333, 0.625)); }
    if (t < 0.729167) { return 1.0; }
    return mix(0.6, 0.0, span01(t, 0.729167, 0.8));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * TIMELINE;
    let aspect = globals.size.x / globals.size.y;

    var col: vec3f;
    if (t < SWAP_AT) {
        let s = ease(vec4f(0.166667, 0.166667, 0.833333, 0.833333), span01(t, 0.458333, 0.625));
        col = shaped(first, uv, jolt_out(t), corners_out(s));
    } else {
        let s = ease(vec4f(0.166667, 0.166667, 0.666667, 1.0), span01(t, 0.666667, 0.791667));
        col = shaped(second, uv, jolt_in(t), corners_in(s));
    }

    // Overlay light, combined with a screen blend.
    let frame = i32(floor(t * SKETCH_FPS));
    var light = NEON * min(scribbles(uv, frame, aspect), 1.5);
    let hz = haze(t);
    if (hz > 0.0) {
        let off = (uv - vec2f(0.45, 0.55)) * vec2f(aspect, 1.0);
        let ray = pow(hash11(floor((atan2(off.y, off.x) + 3.14159) * 12.0)), 3.0);
        let tint = mix(NEON, vec3f(1.0), hz);
        light += tint * clamp(hz * (0.7 + 0.5 * ray), 0.0, 1.0);
    }
    light = clamp(light, vec3f(0.0), vec3f(1.0));
    col = 1.0 - (1.0 - col) * (1.0 - light);
    gpufx_write(id, vec4f(col, 1.0));
}
