// Signal Glitch 2, pass 11: a second, coarser noise tear, then flicker to grey, darken and punch the contrast.

const FRAMES: f32 = 19.0;
const SMOOTH = vec4f(0.33333333, 0.0, 0.66666667, 1.0);
const DEG: f32 = 0.017453292;
const MAP_ZOOM = vec2f(3.619, 1.35);
const NOISE_SCALE = vec2f(0.4, 0.1);
const NOISE_PHASE: f32 = 1.3916667;
const OCTAVE_ZOOM: f32 = 1.7857143;
const LUMA = vec3f(0.20854, 0.702086, 0.089374);
const PIVOT: f32 = 0.43;

fn bezier_axis(a: f32, b: f32, t: f32) -> f32 {
    let s = 1.0 - t;
    return 3.0 * a * s * s * t + 3.0 * b * s * t * t + t * t * t;
}

fn ease(c: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(c.x, c.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(c.y, c.w, 0.5 * (lo + hi));
}

fn key(f: f32, f0: f32, f1: f32, v0: f32, v1: f32) -> f32 {
    return mix(v0, v1, ease(SMOOTH, clamp((f - f0) / (f1 - f0), 0.0, 1.0)));
}

fn ramp(f: f32, f0: f32, f1: f32, v0: f32, v1: f32) -> f32 {
    return mix(v0, v1, clamp((f - f0) / (f1 - f0), 0.0, 1.0));
}

// Tear strength (fraction of the width / height).
fn tear(f: f32) -> vec2f {
    if (f < 6.0) { return vec2f(0.0); }
    if (f < 7.0) { return vec2f(ramp(f, 6.0, 7.0, 0.0, 3.0), ramp(f, 6.0, 7.0, 0.0, 2.0)) / 100.0; }
    if (f < 9.0) { return vec2f(ramp(f, 7.0, 9.0, 3.0, 5.0), ramp(f, 7.0, 9.0, 2.0, 3.0)) / 100.0; }
    if (f < 18.0) { return vec2f(ramp(f, 9.0, 18.0, 5.0, 0.0), ramp(f, 9.0, 18.0, 3.0, 0.0)) / 100.0; }
    return vec2f(0.0);
}

// Colour: 1 = untouched, 0 = grey; two grey flashes at frames 8 and 10.
fn colour_amount(f: f32) -> f32 {
    if (f < 7.0) { return 1.0; }
    if (f < 8.0) { return 1.0 - key(f, 7.0, 8.0, 0.0, 1.0); }
    if (f < 9.0) { return 1.0 - key(f, 8.0, 9.0, 1.0, 0.0); }
    if (f < 10.0) { return 1.0 - key(f, 9.0, 10.0, 0.0, 1.0); }
    if (f < 11.0) { return 1.0 - key(f, 10.0, 11.0, 1.0, 0.0); }
    return 1.0;
}

fn darken(f: f32) -> f32 {
    if (f < 9.0) { return 0.0; }
    if (f < 10.0) { return ramp(f, 9.0, 10.0, 0.0, -0.4); }
    if (f < 11.0) { return ramp(f, 10.0, 11.0, -0.4, 0.0); }
    return 0.0;
}

fn contrast(f: f32) -> f32 {
    if (f < 7.0) { return 1.0; }
    if (f < 8.0) { return key(f, 7.0, 8.0, 1.0, 1.19); }
    if (f < 9.0) { return key(f, 8.0, 9.0, 1.19, 1.0); }
    if (f < 10.0) { return key(f, 9.0, 10.0, 1.0, 1.03); }
    if (f < 11.0) { return key(f, 10.0, 11.0, 1.03, 1.0); }
    return 1.0;
}

// ---- gradient noise ----

fn hash1(p: vec2f) -> f32 {
    var q = fract(p * 1324.518);
    q += dot(q, q.yx + 22.541);
    return fract((q.x + q.y) * q.y);
}

fn gradient(p: vec2f, phase: f32) -> vec2f {
    let n = hash1(p);
    let e = phase + n;
    let e0 = floor(e);
    let e1 = e0 + 1.0;
    var a = fract(p * (34.532 + e0 * 4.412 + 0.3973));
    a += dot(a, a.yx + 15.434);
    let ga = fract((a.xy + a.yx + 0.523) * a.yx + n);
    var b = fract(p * (34.532 + e1 * 4.412 + 0.3973));
    b += dot(b, b.yx + 15.434);
    let gb = fract((b.xy + b.yx + 0.523) * b.yx + n);
    return mix(ga, gb, fract(e)) * 2.0 - 1.0;
}

fn lattice(uv: vec2f, phase: f32) -> f32 {
    let g = uv * (720.0 * globals.size / min(globals.size.x, globals.size.y)) / 100.0;
    let c = floor(g);
    let t = fract(g);
    let n00 = gradient(c, phase);
    let n10 = gradient(c + vec2f(1.0, 0.0), phase);
    let n01 = gradient(c + vec2f(0.0, 1.0), phase);
    let n11 = gradient(c + vec2f(1.0, 1.0), phase);
    let s = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    let v = mix(mix(dot(n00, t), dot(n10, t - vec2f(1.0, 0.0)), s.x),
                mix(dot(n01, t - vec2f(0.0, 1.0)), dot(n11, t - vec2f(1.0, 1.0)), s.x), s.y);
    return v * 0.5 + 0.5;
}

fn spin(uv: vec2f, a: f32) -> vec2f {
    let asp = globals.size.y / globals.size.x;
    let v = vec2f(uv.x, uv.y * asp) - 0.5;
    let c = cos(a);
    let s = sin(a);
    let r = vec2f(c * v.x - s * v.y, s * v.x + c * v.y) + 0.5;
    return vec2f(r.x, r.y / asp);
}

fn noise_map(uv: vec2f, turn: f32) -> f32 {
    var q = spin(uv / NOISE_SCALE, turn) - 10.0;
    var sum = lattice(q, NOISE_PHASE);
    var total = 1.0;
    var w = 0.5;
    for (var i = 2; i <= 10; i++) {
        q *= OCTAVE_ZOOM;
        sum += lattice(q, NOISE_PHASE) * w;
        total += w;
        w *= 0.5;
    }
    return clamp(sum / total, 0.0, 1.0);
}

// ---- colour ----

fn sigmoid(x: f32, a: f32) -> vec2f {
    let s = 1.0 / (1.0 + exp(-a * (x - PIVOT)));
    return vec2f(s + PIVOT - 0.5, a * s * (1.0 - s));
}

fn punch(x: f32, a: f32) -> f32 {
    let lo = sigmoid(0.0, a);
    let hi = sigmoid(1.0, a);
    let mid = sigmoid(PIVOT, a);
    let v = sigmoid(x, a);
    // Bend the S-curve so 0 and 1 stay put.
    if (x <= PIVOT) {
        let k = (mid.y - v.y) / (mid.y - lo.y);
        return v.x + k * k * (0.0 - lo.x);
    }
    let k = (mid.y - v.y) / (mid.y - hi.y);
    return v.x + k * k * (1.0 - hi.x);
}

fn grade(c0: vec3f, f: f32) -> vec3f {
    let s = colour_amount(f);
    let base = LUMA * (1.0 - s);
    var c = clamp(vec3f(dot(c0, base + vec3f(s, 0.0, 0.0)), dot(c0, base + vec3f(0.0, s, 0.0)), dot(c0, base + vec3f(0.0, 0.0, s))), vec3f(0.0), vec3f(1.0));
    let b = darken(f);
    if (b < 0.0) {
        c = clamp(1.0 - pow(max(1.0 - (c + b * 0.01), vec3f(0.0)), vec3f(1.0 / (1.0 - b * 2.5))), vec3f(0.0), vec3f(1.0));
    }
    let k = contrast(f);
    if (k > 1.0) {
        let a = exp(8.33 * k - 12.16) + 5.82 * k - 1.72;
        c = clamp(vec3f(punch(c.r, a), punch(c.g, a), punch(c.b, a)), vec3f(0.0), vec3f(1.0));
    }
    return c;
}

fn fold1(x: f32) -> f32 {
    let m = x - 2.0 * floor(x * 0.5);
    return fract(select(m, 2.0 - m, m >= 1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let f = params.progress * FRAMES;
    let t = tear(f) * vec2f(1.0, globals.size.x / globals.size.y);
    var q = uv;
    if (t.x != 0.0 || t.y != 0.0) {
        let m = noise_map(vec2f(0.5) + (vec2f(uv.x, 1.0 - uv.y) - vec2f(0.5)) / MAP_ZOOM, key(f, 6.0, 16.0, 0.0, 360.0) * DEG);
        q = uv + (m - 0.5) * 2.0 * t * vec2f(1.0, -1.0);
    }
    let c = textureSampleLevel(warped, smp, vec2f(fold1(q.x), fold1(q.y)), 0.0).rgb;
    gpufx_write(id, vec4f(grade(c, f), 1.0));
}
