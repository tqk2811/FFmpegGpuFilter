// A phone spins up from the bottom, its lock screen slides away, and the camera dives into its screen showing the second clip.

// Animation length (seconds of comp time) mapped onto progress 0..1.
const SPAN: f32 = 2.0;
// The phone is laid out on a 640x360 reference canvas, cover-fitted to the frame.
const CANVAS: vec2f = vec2f(640.0, 360.0);
// Phone centre at rest on the reference canvas.
const REST: vec2f = vec2f(319.5, 184.5);
// Half size of the phone body, its outer corner radius and its thickness.
const BODY: vec2f = vec2f(64.0, 131.0);
const BODY_R: f32 = 20.0;
const DEPTH: f32 = 12.0;
// Half size and corner radius of the glass inside the bezel.
const GLASS: vec2f = vec2f(58.0, 126.0);
const GLASS_R: f32 = 15.0;
// How far below its rest spot the phone starts (reference pixels).
const RISE: f32 = 318.0;
// Horizontal field of view of the virtual camera, in degrees.
const FOV_X: f32 = 39.6;
// Sub-frames averaged for motion blur, over half a 30 fps frame of comp time.
const BLUR_TAPS: i32 = 10;
const SHUTTER: f32 = 1.0 / 60.0;
// Phone zoom (relative to rest) sampled once per 30 fps comp frame, from frame 40 on.
const ZOOM_START: f32 = 40.0;
const ZOOM: array<f32, 17> = array<f32, 17>(
    1.0, 1.017, 1.13, 1.48, 1.97, 2.43, 2.91, 3.38, 3.84,
    4.28, 4.67, 5.02, 5.28, 5.45, 5.6, 5.75, 5.9);
const INK: vec3f = vec3f(0.05, 0.05, 0.058);
const SHELL: vec3f = vec3f(0.07, 0.07, 0.075);
const RIM: vec3f = vec3f(0.55, 0.56, 0.58);
const GLYPH: vec3f = vec3f(0.82, 0.85, 0.93);

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

fn ease_span(t: f32, t0: f32, t1: f32, c: vec4f) -> f32 {
    return bezier_ease(clamp((t - t0) / (t1 - t0), 0.0, 1.0), c.x, c.y, c.z, c.w);
}

// Signed distance to a rounded box of half size `h` and corner radius `r`.
fn rbox(p: vec2f, h: vec2f, r: f32) -> f32 {
    let q = abs(p) - h + r;
    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Distance to the segment a-b.
fn seg(p: vec2f, a: vec2f, b: vec2f) -> f32 {
    let pa = p - a;
    let ba = b - a;
    return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

// Distance to a "1" whose stem is centred on x = cx.
fn one(p: vec2f, cx: f32) -> f32 {
    let stem = seg(p, vec2f(cx, -84.0), vec2f(cx, -66.3));
    let flag = seg(p, vec2f(cx - 0.5, -84.0), vec2f(cx - 6.5, -79.0));
    return min(stem, flag);
}

// Lock screen in rest-scale phone coordinates: clock "11:17" and the home bar (0..1 ink).
fn lock_ink(p: vec2f) -> f32 {
    var d = min(one(p, -22.4), one(p, -11.1));
    d = min(d, one(p, 7.5));
    d = min(d, seg(p, vec2f(14.2, -84.0), vec2f(24.3, -84.0)));
    d = min(d, seg(p, vec2f(24.3, -84.0), vec2f(16.9, -66.3)));
    let dots = min(length(p - vec2f(-3.5, -80.5)), length(p - vec2f(-3.5, -70.1))) - 2.1;
    let clock = clamp(1.9 - d, 0.0, 1.0);
    let bar = clamp(0.5 - rbox(p - vec2f(0.0, 123.5), vec2f(20.5, 1.0), 1.0), 0.0, 1.0);
    return max(max(clock, clamp(0.5 - dots, 0.0, 1.0)), bar * 0.9);
}

// Phone scale relative to rest at comp time t.
fn phone_scale(t: f32) -> f32 {
    if (t < 1.0) { return 1.08; }
    let f = t * 30.0 - ZOOM_START;
    if (f < 0.0) {
        return 1.0 + 0.08 * (1.0 - ease_span(t, 1.0, 1.33333, vec4f(0.33333, 0.0, 0.26351, 1.0)));
    }
    let i = min(u32(f), 15u);
    return mix(ZOOM[i], ZOOM[i + 1u], clamp(f - f32(i), 0.0, 1.0)) * (1.0 + max(f - 16.0, 0.0) * 0.03);
}

// Point on the plane z = c of a box spun `a` radians about its vertical axis, seen
// through pixel offset `x` (from the pivot) with focal length `fl`. Returns (u, depth).
fn unspin(x: f32, a: f32, c: f32, fl: f32) -> vec2f {
    let ca = cos(a);
    let sa = sin(a);
    let u = (x * fl + x * c * ca - fl * c * sa) / (fl * ca + x * sa);
    return vec2f(u, -u * sa + c * ca);
}

// The phone and its screen at comp time t, for pixel `px`. Premultiplied colour + coverage.
fn phone(px: vec2f, size: vec2f, fit: f32, t: f32) -> vec4f {
    let e = ease_span(t, 0.0, 1.0, vec4f(0.33333, 0.0, 0.0, 1.0));
    let a = radians(360.0 * (1.0 - e));
    let sc = phone_scale(t);
    let fl = 0.5 * CANVAS.x / tan(radians(FOV_X * 0.5));
    // Reference-canvas offset from the phone centre, in rest-scale units.
    let canvas_p = (px - 0.5 * size) / fit + 0.5 * CANVAS;
    let d = (canvas_p - (REST + vec2f(0.0, RISE * (1.0 - e)))) / sc;
    let flr = fl / sc;
    let ca = cos(a);
    // Front glass faces the camera while cos(a) > 0, the back otherwise.
    let face_z = select(DEPTH * 0.5, -DEPTH * 0.5, ca > 0.0);
    let hit = unspin(d.x, a, face_z, flr);
    let q = vec2f(hit.x, d.y * (flr + hit.y) / flr);
    let body = rbox(q, BODY, BODY_R);
    if (body < 1.0) {
        let cover = clamp(0.5 - body * sc, 0.0, 1.0);
        if (ca <= 0.0) { return vec4f(SHELL * cover, cover); }
        let glass = rbox(q, GLASS, GLASS_R);
        let island = rbox(q - vec2f(0.0, -119.0), vec2f(16.5, 5.0), 5.0);
        let inside = clamp(0.5 - glass * sc, 0.0, 1.0) * clamp(island * sc + 0.5, 0.0, 1.0);
        // The second clip is its own full-frame layer, spun and lifted with the phone.
        let lift = 0.5 * (1.0 - e);
        let zoom_b = 1.0 + 0.05 * (1.0 - ease_span(t, 1.0, 1.33333, vec4f(0.33333, 0.0, 0.26351, 1.0)));
        let flb = 0.5 * size.x / tan(radians(FOV_X * 0.5));
        let rel = px - size * vec2f(0.5, 0.5 + lift);
        let hb = unspin(rel.x, a, 0.0, flb);
        let bp = vec2f(hb.x, rel.y * (flb + hb.y) / flb) / zoom_b;
        let buv = clamp(bp / size + 0.5, vec2f(0.0), vec2f(1.0));
        var screen = textureSampleLevel(second, smp, buv, 0.0).rgb;
        // The lock screen rides with the phone, then slides up and away (in phone units, so it stays gone).
        let slide = 372.0 * ease_span(t, 1.0, 1.5, vec4f(0.33333, 0.0, 0.0, 1.0));
        let ink = lock_ink(q + vec2f(0.0, slide));
        screen = 1.0 - (1.0 - screen) * (1.0 - GLYPH * ink);
        return vec4f(mix(INK, screen, inside) * cover, cover);
    }
    // Edge of the phone, visible while it turns side-on.
    let side = select(-BODY.x, BODY.x, sin(a) > 0.0);
    let sa = sin(a);
    let z = (flr * side * ca - d.x * flr + d.x * side * sa) / (d.x * ca - flr * sa);
    if (abs(z) > DEPTH * 0.5) { return vec4f(0.0); }
    let depth = -side * sa + z * ca;
    let y = d.y * (flr + depth) / flr;
    let edge = abs(y) - (BODY.y - BODY_R * 0.4);
    let cover = clamp(0.5 - edge * sc, 0.0, 1.0) * clamp((DEPTH * 0.5 - abs(z)) * 2.0, 0.0, 1.0);
    let shade = 0.75 + 0.25 * cos(z / DEPTH * 3.14159);
    return vec4f(RIM * shade * cover, cover);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress * SPAN;
    let size = globals.size;
    let px = uv * size;
    let fit = max(size.x / CANVAS.x, size.y / CANVAS.y);
    var acc = vec4f(0.0);
    for (var k = 0; k < BLUR_TAPS; k++) {
        let tk = t + SHUTTER * ((f32(k) + 0.5) / f32(BLUR_TAPS) - 0.5);
        acc += phone(px, size, fit, clamp(tk, 0.0, SPAN));
    }
    acc /= f32(BLUR_TAPS);
    let back = textureSampleLevel(first, smp, uv, 0.0).rgb;
    gpufx_write(id, vec4f(acc.rgb + back * (1.0 - acc.a), 1.0));
}
