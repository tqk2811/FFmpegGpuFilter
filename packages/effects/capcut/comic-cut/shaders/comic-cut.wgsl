// The first clip cracks down the middle and tears into two paper-edged halves that fly apart over a halftone print of the second clip, under film grain.

// Animation time span (seconds) that `progress` covers.
const SPAN: f32 = 0.8;
// Times (s) of the crack stages, the tear and the switch from halftone to plain second clip.
const CRACK_THIN_END: f32 = 0.1;
const TEAR_AT: f32 = 0.23333;
const PLAIN_AT: f32 = 0.63333;
// Halftone screen: cells per frame height, screen angle (deg), edge softness and threshold bias.
const DOT_CELLS: f32 = 169.0;
const DOT_ANGLE: f32 = 45.0;
const DOT_SOFT: f32 = 0.45;
const DOT_BIAS: f32 = -0.1;
// Grain colour-balance weights and saturation.
const GRAIN_WEIGHTS: vec3f = vec3f(1.414, 0.18, 0.42);
const GRAIN_SAT: f32 = 0.66;

// Value at time t on a piecewise-linear track of up to 5 keys (times k, values v), held outside.
fn track(t: f32, k: array<f32, 5>, v: array<f32, 5>, n: i32) -> f32 {
    var kk = k;
    var vv = v;
    if (t <= kk[0]) { return vv[0]; }
    for (var i = 1; i < n; i++) {
        if (t < kk[i]) {
            return mix(vv[i - 1], vv[i], (t - kk[i - 1]) / (kk[i] - kk[i - 1]));
        }
    }
    return vv[n - 1];
}

// ---------- procedural tear shapes (lengths in 1080-px comp units) ----------

fn hash11(n: f32) -> f32 {
    return fract(sin(n * 91.3458) * 47453.5453);
}

// Smooth 1D value noise in [0, 1].
fn vnoise(x: f32) -> f32 {
    let i = floor(x);
    let f = x - i;
    let w = f * f * (3.0 - 2.0 * f);
    return mix(hash11(i), hash11(i + 1.0), w);
}

// Shared horizontal course of the tear (offset from the frame centre), v = 0..1 down the frame.
fn tear_course(v: f32) -> f32 {
    return 22.0 * sin(6.2832 * (0.9 * v + 0.12)) + 28.0 * (vnoise(v * 5.0 + 1.7) - 0.5)
        + 8.0 * (vnoise(v * 23.0 + 4.1) - 0.5) + 3.0 * (vnoise(v * 90.0) - 0.5);
}

// Torn paper edge on one half. `e` = signed distance from the cut line, positive toward the gap.
// Returns colour in .rgb and coverage in .a (white fibre band, then a soft drop shadow).
fn paper_edge(e: f32, v: f32, seed: f32, px: f32) -> vec4f {
    let outer = 20.0 + 12.0 * vnoise(v * 9.0 + seed) + 7.0 * vnoise(v * 70.0 + seed * 3.0);
    let inner = 16.0 + 6.0 * vnoise(v * 40.0 + seed * 5.0);
    let band = clamp(0.5 - (e - outer) / px, 0.0, 1.0) * clamp(0.5 + (e + inner) / px, 0.0, 1.0);
    let fibre = vnoise(v * 420.0 + floor(e * 0.35) * 13.0 + seed);
    let tone = 0.80 + 0.17 * fibre - 0.08 * smoothstep(outer - 6.0, outer, e);
    let shadow = 0.44 * (1.0 - smoothstep(8.0, 80.0, e - outer)) * step(outer, e);
    let a = band + (1.0 - band) * shadow;
    if (a <= 0.0) { return vec4f(0.0); }
    return vec4f(vec3f(tone) * band / a, a);
}

// ---------- layer helpers ----------

// Inverse of a layer transform anchored at the frame centre. `pos` is in comp units
// (1080 basis per axis), `rot` in degrees clockwise, `scl` a factor. Returns local pixels.
fn to_local(pix: vec2f, size: vec2f, pos: vec2f, rot: f32, scl: f32) -> vec2f {
    let d = pix - pos / 1080.0 * size;
    let a = radians(rot);
    let c = cos(a);
    let s = sin(a);
    let r = vec2f(c * d.x + s * d.y, -s * d.x + c * d.y);
    return 0.5 * size + r / scl;
}

fn mirror(p: vec2f) -> vec2f {
    let m = abs(p - 2.0 * floor((p + 1.0) * 0.5));
    return clamp(m, vec2f(0.0), vec2f(1.0));
}

fn inside(uv: vec2f) -> bool {
    return all(uv >= vec2f(0.0)) && all(uv <= vec2f(1.0));
}

// Grey halftone of the second clip at layer uv (screen maths done y-up).
fn halftone(uv: vec2f, size: vec2f) -> vec3f {
    let texel = 1.0 / size;
    // The screen reads a reduced-resolution copy; a small box filter stands in for it.
    var c = vec3f(0.0);
    c += textureSampleLevel(second, smp, uv + vec2f(-1.0, -1.0) * texel, 0.0).rgb;
    c += textureSampleLevel(second, smp, uv + vec2f(1.0, -1.0) * texel, 0.0).rgb;
    c += textureSampleLevel(second, smp, uv + vec2f(-1.0, 1.0) * texel, 0.0).rgb;
    c += textureSampleLevel(second, smp, uv + vec2f(1.0, 1.0) * texel, 0.0).rgb;
    let lum = dot(c * 0.25, vec3f(0.299, 0.587, 0.114));
    var q = vec2f(uv.x, 1.0 - uv.y) - 0.5;
    q.x *= size.x / size.y;
    let a = radians(DOT_ANGLE);
    q = vec2f(cos(a) * q.x - sin(a) * q.y, sin(a) * q.x + cos(a) * q.y) + 1.0;
    let cell = fract(q * DOT_CELLS);
    let r = length(cell - 0.5);
    return vec3f(smoothstep(-DOT_SOFT, DOT_SOFT, lum - r + DOT_BIAS));
}

// ---------- film grain ----------

fn grain_hash(p: vec2f, seed: f32) -> vec2f {
    var h = fract(vec3f(p.x, p.y, p.x) * vec3f(0.1031, 0.103, 0.0973));
    h += vec3f(dot(h, h.yzx + 33.33 + seed));
    return fract((h.xx + h.yz) * h.zy) * 2.0 - 1.0;
}

fn grain_gradient(p: vec2f, cell: f32, seed: f32) -> f32 {
    let i = floor(p / cell);
    let f = fract(p / cell);
    let w = f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let n00 = dot(grain_hash(i * cell, seed), f);
    let n10 = dot(grain_hash((i + vec2f(1.0, 0.0)) * cell, seed), f - vec2f(1.0, 0.0));
    let n01 = dot(grain_hash((i + vec2f(0.0, 1.0)) * cell, seed), f - vec2f(0.0, 1.0));
    let n11 = dot(grain_hash((i + 1.0) * cell, seed), f - 1.0);
    return mix(mix(n00, n10, w.x), mix(n01, n11, w.x), w.y);
}

fn grain_layered(p: vec2f, grain_size: f32, seed: f32) -> f32 {
    let lv = 2.0 / max(0.1, grain_size);
    let o = floor(lv);
    let c0 = pow(2.0, o);
    let c1 = pow(2.0, o + 1.0);
    let g0 = 0.6 * (grain_gradient(p * 500.0, 500.0 / c0, seed) * 0.5 + 0.5)
        + 0.4 * (grain_gradient(p * 300.0, 300.0 / c0, seed) * 0.5 + 0.5);
    let g1 = 0.6 * (grain_gradient(p * 500.0, 500.0 / c1, seed) * 0.5 + 0.5)
        + 0.4 * (grain_gradient(p * 300.0, 300.0 / c1, seed) * 0.5 + 0.5);
    return mix(g0, g1, fract(lv));
}

fn overlay_ch(b: f32, n: f32) -> f32 {
    if (b < 0.5) { return 2.0 * b * n; }
    return 1.0 - 2.0 * (1.0 - b) * (1.0 - n);
}

fn film_grain(base: vec3f, uv: vec2f, size: vec2f, t: f32) -> vec3f {
    var p = vec2f(uv.x, 1.0 - uv.y);
    p.x *= size.x / size.y;
    let seed = (t * 1000.0) % 100.0;
    // Per-channel grain, contrast-stretched.
    var n = vec3f(grain_layered(p, 0.22, seed), grain_layered(p, 0.22, seed + 2.0), grain_layered(p, 0.22, seed + 4.0));
    n = (n - 0.5) * 11.0 + 0.5;
    // Saturation adjustment of the grain colour.
    let w = GRAIN_WEIGHTS / ((GRAIN_WEIGHTS.x + GRAIN_WEIGHTS.y + GRAIN_WEIGHTS.z) / 0.02);
    let k = 50.0 - GRAIN_SAT * 100.0;
    let wr = w.x * k;
    let wg = w.y * k;
    let wb = w.z * k;
    let g = vec3f(
        dot(n, vec3f(1.0 - wg - wr, wr, wg)),
        dot(n, vec3f(wb, 1.0 - wb - wg, wg)),
        dot(n, vec3f(wb, wr, 1.0 - wb - wr)));
    // Film blend: overlay, lifted by a screen of the bright grain in the darker areas.
    let ov = vec3f(overlay_ch(base.r, g.r), overlay_ch(base.g, g.g), overlay_ch(base.b, g.b));
    let lift = max(1.0 - (1.0 - g) / 0.5, vec3f(0.0));
    let shade = 0.5 * smoothstep(0.58824, 0.5098, dot(base, vec3f(0.299, 0.587, 0.114)));
    let film = mix(ov, 1.0 - (1.0 - ov) * (1.0 - lift), vec3f(shade));
    let strength = mix(0.33, 0.9, clamp(t / 0.5, 0.0, 1.0)) / 10.0;
    return mix(base, film, strength);
}

// ---------- scene ----------

// One torn half of the first clip with its paper edge, composited over `under`.
// side = +1 right half, -1 left half.
fn torn_half(under: vec3f, pix: vec2f, size: vec2f, unit: f32, t: f32, side: f32) -> vec3f {
    let keys = array<f32, 5>(0.1, 0.23333, 0.36667, 0.5, 0.63333);
    var xs = array<f32, 5>(540.0, 480.15925, 336.3919, 127.09824, -23.504362);
    var ys = array<f32, 5>(540.0, 540.0, 506.0, 567.0, 510.0);
    var rs = array<f32, 5>(0.0, 0.0, -2.5, -7.0, -7.5);
    var seed = 37.0;
    if (side > 0.0) {
        xs = array<f32, 5>(540.0, 600.84333, 741.61325, 952.90154, 1095.5063);
        ys = array<f32, 5>(540.0, 540.0, 581.0, 504.0, 604.0);
        rs = array<f32, 5>(0.0, 0.0, -2.0, 6.0, 7.0);
        seed = 11.0;
    }
    let pos = vec2f(track(t, keys, xs, 5), track(t, keys, ys, 5));
    let scl = mix(1.0, 1.08, clamp((t - 0.1) / 0.13333, 0.0, 1.0));
    let local = to_local(pix, size, pos, track(t, keys, rs, 5), scl);
    let luv = local / size;
    let v = luv.y;
    let dx = (local.x - 0.5 * size.x) / unit;
    // Each half's cut wanders slightly off the shared course.
    let cut = tear_course(v) + 7.0 * (vnoise(v * 13.0 + seed) - 0.5);
    let e = -side * (dx - cut);
    let px = 1.0 / (unit * scl);
    var col = under;
    if (inside(luv)) {
        let body = clamp(0.5 - e / px, 0.0, 1.0);
        col = mix(col, textureSampleLevel(first, smp, luv, 0.0).rgb, body);
    }
    let edge = paper_edge(e, v, seed, px);
    return mix(col, edge.rgb, edge.a);
}

// Crack drawn over the whole first clip before it tears; `wide` picks the second, wider stage.
fn crack(under: vec3f, pix: vec2f, size: vec2f, unit: f32, wide: bool) -> vec3f {
    let v = pix.y / size.y;
    let dx = (pix.x - 0.5 * size.x) / unit - tear_course(v);
    let px = 1.0 / unit;
    var half = 0.0;
    var tone = 0.0;
    var gap = 1.0;
    if (wide) {
        half = 20.0 + 8.0 * vnoise(v * 20.0 + 3.0) + 3.0 * vnoise(v * 110.0);
        tone = 0.86 + 0.08 * vnoise(v * 380.0 + floor(dx * 0.3) * 7.0);
    } else {
        half = 2.5 + 4.5 * vnoise(v * 30.0 + 9.0);
        tone = 0.9 + 0.1 * vnoise(v * 300.0);
        gap = smoothstep(0.18, 0.3, vnoise(v * 14.0 + 5.0));
    }
    let a = clamp(0.5 - (abs(dx) - half) / px, 0.0, 1.0) * gap;
    return mix(under, vec3f(tone), a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let size = globals.size;
    let pix = uv * size;
    let unit = min(size.x, size.y) / 1080.0;

    var col = vec3f(0.0);
    if (t < TEAR_AT) {
        // Whole first clip, pushed in slightly, with the crack opening down the middle.
        let scl = mix(1.02, 1.06, clamp(t / CRACK_THIN_END, 0.0, 1.0));
        col = textureSampleLevel(first, smp, 0.5 + (uv - 0.5) / scl, 0.0).rgb;
        col = crack(col, pix, size, unit, t >= CRACK_THIN_END);
    } else {
        if (t < PLAIN_AT) {
            let k3 = array<f32, 5>(0.23333, 0.36667, 0.5, 9.0, 9.0);
            let bx = array<f32, 5>(539.5, 549.4225, 546.09488, 0.0, 0.0);
            let by = array<f32, 5>(548.125, 531.58817, 561.5509, 0.0, 0.0);
            let bs = array<f32, 5>(0.888, 0.905, 0.95, 0.0, 0.0);
            let br = array<f32, 5>(-0.5, 1.8, -2.8, 0.0, 0.0);
            let l = to_local(pix, size, vec2f(track(t, k3, bx, 3), track(t, k3, by, 3)), track(t, k3, br, 3), track(t, k3, bs, 3));
            col = halftone(mirror(l / size), size);
        } else {
            let l = to_local(pix, size, vec2f(536.125, 538.0), -1.2, 0.99);
            col = textureSampleLevel(second, smp, mirror(l / size), 0.0).rgb;
        }
        col = torn_half(col, pix, size, unit, t, 1.0);
        col = torn_half(col, pix, size, unit, t, -1.0);
    }
    gpufx_write(id, vec4f(clamp(film_grain(col, uv, size, t), vec3f(0.0), vec3f(1.0)), 1.0));
}
