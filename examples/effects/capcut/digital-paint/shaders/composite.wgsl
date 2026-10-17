// Digital Paint, pass 7: the glowing first clip is painted over by brush strokes revealing a black-dot halftone of the second clip, then a second set of strokes reveals the glowing second clip; each layer punches in with a zoom blur.

const SPAN: f32 = 2.0;          // scene seconds covered by progress 0..1
const FRAME: f32 = 1.0 / 30.0;  // the zoom blur trails over one 30 fps frame
const MASK_FPS: f32 = 25.0;     // the stroke masks advance in 25 fps steps
const MASK_DELAY: f32 = 18.0;   // the second stroke set runs 18 mask frames later
const TILT: f32 = 0.34906585;   // stroke direction, 20 degrees below horizontal

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

// Four-key track (rest 1 -> peak -> hold -> rest 1), eased with the given curve.
fn track(t: f32, keys: vec4f, peak: f32, hold: f32, curve: vec4f) -> f32 {
    if (t <= keys.x || t >= keys.w) { return 1.0; }
    if (t < keys.y) { return mix(1.0, peak, bezier_ease((t - keys.x) / (keys.y - keys.x), curve)); }
    if (t < keys.z) { return mix(peak, hold, bezier_ease((t - keys.y) / (keys.z - keys.y), curve)); }
    return mix(hold, 1.0, bezier_ease((t - keys.z) / (keys.w - keys.z), curve));
}

// Zoom of a layer at scene time t: the first clip's layer pulses at 0.3 s, both second-clip layers at 1.53 s.
fn zoom(t: f32, late: bool) -> vec2f {
    var keys = vec4f(0.3, 0.333333, 0.433333, 0.466667);
    if (late) { keys = vec4f(1.533333, 1.566667, 1.7, 1.733333); }
    let sx = track(t, keys, 1.4, 1.4, vec4f(0.33, 0.0, 0.67, 1.0));
    let sy = track(t, keys, 1.4, 1.412, vec4f(0.33333333, 0.0, 0.66666667, 1.0));
    return vec2f(sx, sy);
}

fn luma(c: vec3f) -> f32 { return dot(c, vec3f(0.299, 0.587, 0.114)); }

// The first (0) or second (1) clip with its glow added (blend "add" onto an 8-bit target).
fn glowing(which: i32, q: vec2f) -> vec3f {
    var base: vec4f;
    var halo: vec4f;
    if (which == 0) {
        base = textureSampleLevel(first, smp, q, 0.0);
        halo = textureSampleLevel(glow_a, smp, q, 0.0);
    } else {
        base = textureSampleLevel(second, smp, q, 0.0);
        halo = textureSampleLevel(glow_b, smp, q, 0.0);
    }
    var g = halo * 1.17;
    if (g.a > 1.0) { g = g / g.a; }
    return clamp(base.rgb + g.rgb, vec3f(0.0), vec3f(1.0));
}

// Black-dot halftone of the second clip: 159 cells across the height, grid turned -30 degrees.
fn halftone(q: vec2f) -> vec3f {
    let lum = luma(textureSampleLevel(second, smp, q, 0.0).rgb);
    var p = vec2f(q.x, 1.0 - q.y) - 0.5;
    p.x *= globals.size.x / globals.size.y;
    let ang = radians(-30.0);
    let cs = cos(ang);
    let sn = sin(ang);
    p = vec2f(cs * p.x - sn * p.y, sn * p.x + cs * p.y) + 1.0;
    let cell = fract(p * 159.0);
    let hole = 1.0 - length(cell - 0.5);
    return vec3f(smoothstep(-0.34, 0.34, lum - hole + 0.1));
}

// Layer 0 = glowing first clip, 1 = halftone second clip, 2 = glowing second clip.
fn layer(which: i32, q: vec2f) -> vec3f {
    if (which == 1) { return halftone(q); }
    return glowing(select(1, 0, which == 0), q);
}

fn mirror(q: vec2f) -> vec2f {
    let m = q - 1.0;
    return abs(m - 2.0 * floor(m / 2.0) - 1.0);
}

fn dither_hash(a: f32, b: f32) -> f32 {
    var h = fract(vec2f(a, b) * 13.517);
    h += dot(h, h.yx + 22.541);
    return fract((h.x + h.y) * h.y);
}

// Path point f (about 0..1) through six zoomed copies of the layer, linear between them.
fn along(f: f32, pts: array<vec2f, 6>) -> vec2f {
    let seg = clamp(i32(floor(f * 5.0)), 0, 4);
    return mix(pts[seg], pts[seg + 1], vec2f(f * 5.0 - f32(seg)));
}

// A layer scaled about the centre, smeared between its previous- and current-frame zoom.
fn zoomed_layer(which: i32, uv: vec2f, t: f32) -> vec3f {
    let late = which != 0;
    let now = zoom(t, late);
    let before = zoom(t - FRAME, late);
    if (all(now == before)) { return layer(which, mirror((uv - 0.5) / now + 0.5)); }
    var pts: array<vec2f, 6>;
    for (var i = 0; i < 6; i++) {
        let w = 0.5 * f32(i) / 5.0 + 0.75;
        pts[i] = (uv - 0.5) / mix(before, now, vec2f(w)) + 0.5;
    }
    let n = floor(12.0 + 12.0 * smoothstep(0.0, 0.2, length(pts[5] - pts[0])));
    let gl = vec2f(uv.x, 1.0 - uv.y);
    var sum = vec3f(0.0);
    for (var k = 0; k < 24; k++) {
        let fk = f32(k);
        if (fk >= n) { break; }
        let f = fk / (n - 1.0) + (dither_hash(fk + gl.x, fk * gl.y) - 0.5) / n;
        sum += layer(which, mirror(along(f, pts)));
    }
    return sum / n;
}

fn hash21(p: vec2f) -> f32 {
    var q = fract(p * vec2f(0.1031, 0.1030));
    q += dot(q, q.yx + 33.33);
    return fract((q.x + q.y) * q.x);
}

fn value_noise(p: vec2f) -> f32 {
    let c = floor(p);
    let f = p - c;
    let w = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(c), hash21(c + vec2f(1.0, 0.0)), w.x),
               mix(hash21(c + vec2f(0.0, 1.0)), hash21(c + vec2f(1.0, 1.0)), w.x), w.y);
}

// Brush-stroke reveal (0 = not painted, 1 = painted) at mask frame f: four slanted bands are
// painted one after another from the top-right corner down, alternating stroke direction,
// with dry-brush bristle streaks behind each stroke head.
fn strokes(uv: vec2f, f: f32) -> f32 {
    if (f < 9.5) { return 0.0; }
    if (f >= 30.0) { return 1.0; }
    let dir = vec2f(cos(TILT), sin(TILT));
    let nrm = vec2f(-sin(TILT), cos(TILT));
    let span = sin(TILT) + cos(TILT);
    let rel = uv - vec2f(1.0, 0.0);
    let across = dot(rel, nrm) / span;               // 0 at the top-right corner, 1 at the bottom-left
    let lengthwise = (dot(rel, dir) + cos(TILT)) / span; // 0 .. 1 along the stroke
    let edges = array<f32, 4>(0.0, 0.28, 0.39, 0.65);
    let starts = array<f32, 4>(9.5, 15.5, 19.5, 23.5);
    let ends = array<f32, 4>(15.5, 19.5, 23.5, 30.0);
    let wobble = (value_noise(vec2f(lengthwise * 9.0, 3.0)) - 0.5) * 0.03;
    let a = clamp(across + wobble, 0.0, 1.0);
    var band = 0;
    for (var i = 1; i < 4; i++) { if (a >= edges[i]) { band = i; } }
    let h = clamp((f - starts[band]) / (ends[band] - starts[band]), 0.0, 1.0);
    if (h <= 0.0) { return 0.0; }
    if (h >= 1.0) { return 1.0; }
    let head = 1.0 - (1.0 - h) * (1.0 - h);
    var x = lengthwise;
    if (band % 2 == 0) { x = 1.0 - lengthwise; }
    let bristle = value_noise(vec2f(x * 4.0, a * 140.0));
    let edge = head * 1.15 - 0.075 + (bristle - 0.5) * 0.12;
    let cover = smoothstep(edge + 0.03, edge - 0.03, x);
    let streak = value_noise(vec2f(x * 2.5, a * 260.0));
    return cover * (1.0 - 0.45 * (1.0 - head) * smoothstep(0.55, 0.9, streak));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let frame = floor(t * MASK_FPS + 0.5);
    let paint1 = strokes(uv, frame);
    let paint2 = strokes(uv, frame - MASK_DELAY);

    var c = vec3f(0.0);
    if (t < 1.933333 && paint1 < 1.0 && paint2 < 1.0) { c = zoomed_layer(0, uv, t); }
    if (t >= 0.333333 && paint1 > 0.0 && paint2 < 1.0) { c = mix(c, zoomed_layer(1, uv, t), paint1); }
    if (t >= 1.066667 && paint2 > 0.0) { c = mix(c, zoomed_layer(2, uv, t), paint2); }
    gpufx_write(id, vec4f(c, 1.0));
}
