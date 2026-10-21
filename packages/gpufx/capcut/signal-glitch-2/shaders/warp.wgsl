// Signal Glitch 2, pass 10: tear the picture sideways along a spinning noise field and add glowing interference bands.

const FRAMES: f32 = 19.0;
const COMP: f32 = 1280.0;
const SMOOTH = vec4f(0.33333333, 0.0, 0.66666667, 1.0);
const DEG: f32 = 0.017453292;
const MAP_ZOOM = vec2f(2.084, 3.106);     // the noise map is shown enlarged
const NOISE_SCALE = vec2f(0.011, 0.1);
const NOISE_PHASE: f32 = 3.35;            // fixed evolution of the noise
const OCTAVE_ZOOM: f32 = 1.7857143;
const SEQ_FRAMES: f32 = 20.0;

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

// Horizontal tear, comp pixels.
fn tear_x(f: f32) -> f32 {
    if (f < 6.0) { return 0.0; }
    if (f < 7.0) { return key(f, 6.0, 7.0, 0.0, 30.0); }
    if (f < 9.0) { return key(f, 7.0, 9.0, 30.0, 69.0); }
    if (f < 16.0) { return key(f, 9.0, 16.0, 69.0, 0.0); }
    return 0.0;
}

// Vertical tear, comp pixels.
fn tear_y(f: f32) -> f32 {
    if (f < 6.0) { return 0.0; }
    if (f < 7.0) { return key(f, 6.0, 7.0, 0.0, 1.5); }
    if (f < 9.0) { return key(f, 7.0, 9.0, 1.5, 1.0); }
    if (f < 16.0) { return key(f, 9.0, 16.0, 1.0, 0.0); }
    return 0.0;
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

// Ten octaves, each 1.79x finer and half as strong.
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

// ---- interference bands (drawn here, no texture) ----

fn hash2(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(12.9898, 78.233))) * 43758.5453);
}

fn streaks(q: vec2f, seed: f32) -> f32 {
    let g = vec2f(q.x * 9.0 + seed * 3.1, q.y * 260.0);
    let c = floor(g);
    let t = fract(g);
    let s = t * t * (3.0 - 2.0 * t);
    let v = mix(mix(hash2(c + seed), hash2(c + vec2f(1.0, 0.0) + seed), s.x),
                mix(hash2(c + vec2f(0.0, 1.0) + seed), hash2(c + vec2f(1.0, 1.0) + seed), s.x), s.y);
    return v * v;
}

fn band(y: f32, centre: f32, half: f32) -> f32 {
    let d = abs(y - centre) / half;
    return exp(-d * d * 2.0);
}

// Bands in the square overlay: a wide purple/green one near the top, a thin red line
// and a blue/cyan one lower down, plus faint speckle; strength follows the frame.
fn overlay(q: vec2f, frame: i32) -> vec3f {
    var level = array<f32, 20>(0.0, 0.0, 0.12, 0.14, 0.47, 0.46, 0.83, 0.86, 0.75, 0.77,
                               0.8, 0.4, 0.8, 0.75, 0.65, 0.5, 0.45, 0.01, 0.0, 0.0);
    let k = level[clamp(frame, 0, 19)];
    if (k <= 0.0) { return vec3f(0.0); }
    let seed = f32(frame) * 7.13;
    let tint = streaks(q * vec2f(0.5, 0.3), seed + 2.0);
    let top = band(q.y, 0.04, 0.02) * mix(vec3f(0.55, 0.3, 0.75), vec3f(0.3, 0.75, 0.5), tint);
    let line = band(q.y, 0.19, 0.003) * vec3f(0.85, 0.2, 0.45);
    let low = band(q.y, 0.37, 0.012) * smoothstep(0.03, 0.1, q.x) * mix(vec3f(0.2, 0.35, 0.95), vec3f(0.3, 0.85, 0.85), tint);
    let speck = select(0.0, 0.08, hash2(floor(q * vec2f(640.0, 640.0)) + seed) > 0.985) * step(0.42, q.y);
    return k * ((top + low) * streaks(q, seed) * 1.6 + line * (0.4 + 0.6 * streaks(q, seed + 5.0)) + vec3f(speck));
}

fn overlay_at(uv: vec2f, frame: i32) -> vec3f {
    // Fill the frame with the square overlay (crop the longer side); nothing outside it.
    let a = globals.size.x / globals.size.y;
    var q = uv;
    if (a > 1.0) { q.y = (uv.y - 0.5) / a + 0.5; } else { q.x = (uv.x - 0.5) * a + 0.5; }
    if (any(q < vec2f(0.0)) || any(q > vec2f(1.0))) { return vec3f(0.0); }
    return overlay(q, frame);
}

fn fold1(x: f32) -> f32 {
    let m = x - 2.0 * floor(x * 0.5);
    return fract(select(m, 2.0 - m, m >= 1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = clamp(params.progress, 0.0, 1.0);
    let f = p * FRAMES;
    let frame = i32(floor(p * SEQ_FRAMES));
    let hx = tear_x(f) / COMP;
    let hy = tear_y(f) / COMP * globals.size.x / globals.size.y;
    var q = uv;
    if (hx != 0.0 || hy != 0.0) {
        let m = noise_map(vec2f(0.5) + (vec2f(uv.x, 1.0 - uv.y) - vec2f(0.5)) / MAP_ZOOM, mix(0.0, 360.0, clamp((f - 6.0) / 10.0, 0.0, 1.0)) * DEG);
        let d = (m - 0.5) * 2.0;
        q = uv + vec2f(d * hx, -d * hy);
    }
    let r = vec2f(fold1(q.x), fold1(q.y));
    let c = textureSampleLevel(streaked, smp, r, 0.0).rgb;
    gpufx_write(id, vec4f(min(c + overlay_at(r, frame), vec3f(1.0)), 1.0));
}
