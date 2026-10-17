// Four torn-paper strips of the clips slide in from the top, bottom, left and right in turn, then the second clip cuts in whole.

// Animation time covered by progress 0..1, in seconds.
const SPAN: f32 = 1.49999;
// Time at which the plain second clip covers everything.
const FULL_CUT: f32 = 1.23333;
// Side of the square layout canvas, in canvas pixels.
const CANVAS: f32 = 720.0;

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

// Value animated from `a` to `b` between times t0 and t1.
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, curve: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, bezier_ease(x, curve));
}

fn hash11(n: f32) -> f32 {
    return fract(sin(n * 127.1) * 43758.5453);
}

// Smooth 1D value noise.
fn noise1(x: f32) -> f32 {
    let i = floor(x);
    let f = fract(x);
    let w = f * f * (3.0 - 2.0 * f);
    return mix(hash11(i), hash11(i + 1.0), w) * 2.0 - 1.0;
}

// Offset of a ripped paper edge at position s (0..1 along the edge): a slow wander plus
// finer and finer fibres, about +-0.04 overall.
fn rip(s: f32, seed: f32) -> f32 {
    var v = 0.022 * noise1(s * 3.0 + seed) + 0.012 * noise1(s * 7.0 + seed * 1.7);
    var amp = 0.006;
    var freq = 18.0;
    for (var i = 0; i < 4; i++) {
        v += amp * noise1(s * freq + seed * 3.1 + f32(i) * 11.0);
        amp *= 0.5;
        freq *= 2.3;
    }
    return v;
}

// Coverage of a mask that is opaque where `d` < 0, with a soft rim `soft` wide.
fn cover(d: f32, soft: f32) -> f32 {
    return clamp(0.5 - d / soft, 0.0, 1.0);
}

// Inside the unit square (layer bounds).
fn inside(p: vec2f) -> f32 {
    let s = step(vec2f(0.0), p) * step(p, vec2f(1.0));
    return s.x * s.y;
}

// Clip sampled at canvas pixel q (outside the clip it is transparent), premultiplied.
fn clip_at(tex: texture_2d<f32>, q: vec2f) -> vec4f {
    let p = q / CANVAS;
    let a = inside(p);
    return vec4f(textureSampleLevel(tex, smp, clamp(p, vec2f(0.0), vec2f(1.0)), 0.0).rgb * a, a);
}

fn over(dst: vec3f, src: vec4f, m: f32) -> vec3f {
    return dst * (1.0 - src.a * m) + src.rgb * m;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    if (t >= FULL_CUT) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }

    let c = uv * CANVAS;
    var col = textureSampleLevel(first, smp, uv, 0.0).rgb;
    // Rim softness of the torn edges, in strip units.
    let soft_h = 1.5 / 640.0;
    let soft_v = 1.5 / 360.0;

    // 1) Second clip drops from the top on a tall strip whose lower edge is ripped.
    if (t >= 0.16667) {
        let y = keyed(t, 0.16667, 0.3, -364.0, 360.0, vec4f(0.166667, 0.111111, 0.0, 1.0));
        let shift = vec2f(0.0, y - 640.0);
        let local = (c - shift) / vec2f(720.0, 1280.0);
        let tv = local.y + (0.5 - 0.42578125);
        let m = inside(local) * step(tv, 1.0) * cover(tv - (0.575 + rip(local.x, 3.0)), soft_h);
        col = over(col, clip_at(second, c - shift), m);
    }
    // 2) First clip rises back from the bottom on the same strip turned upside down.
    if (t >= 0.46667) {
        let y = keyed(t, 0.46667, 0.6, 1088.0, 450.0, vec4f(0.166667, 0.126785, 0.0, 1.0));
        let local = (c - vec2f(0.0, y - 640.0)) / vec2f(720.0, 1280.0);
        let tv = 1.0 - local.y;
        let m = inside(local) * cover(tv - (0.575 + rip(1.0 - local.x, 3.0)), soft_h);
        col = over(col, clip_at(first, c - vec2f(0.0, y - 358.0)), m);
    }
    // 3) Enlarged second clip slides in from the left; the strip's right edge is ripped.
    if (t >= 0.73333) {
        let x = keyed(t, 0.73333, 0.86667, -381.0, 360.0, vec4f(0.166667, 0.131354, 0.0, 1.0));
        let local = (c - vec2f(x - 360.0, 0.0)) / CANVAS;
        let m = inside(local) * cover(local.x - (0.554 + rip(local.y, 7.0)), soft_v);
        let q = (c - vec2f(x - 360.0, 0.0) - vec2f(382.245, 315.41)) / 1.205 + 360.0;
        col = over(col, clip_at(second, q), m);
    }
    // 4) Second clip slides in from the right; the strip's left edge is ripped and, once
    //    settled, always tucks under the left strip so no gap opens between them.
    if (t >= 1.0) {
        let x = keyed(t, 1.0, 1.13333, 810.0, 360.0, vec4f(0.166667, 0.166667, 0.0, 1.0));
        let shift = vec2f(x - 360.0, 0.0);
        let local = (c - shift) / CANVAS;
        let m = inside(local) * cover(min(0.516 + rip(local.y, 13.0), 0.544 + rip(local.y, 7.0)) - local.x, soft_v);
        col = over(col, clip_at(second, c - shift), m);
    }
    gpufx_write(id, vec4f(col, 1.0));
}
