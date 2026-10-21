// Contrast Split, pass 3: at half resolution, sideways edge sharpening, faint horizontal chroma-noise streaks, a dark
// vignette and an exposure boost, all swelling in toward the cut and fading out by the end.

const SPAN: f32 = 0.99999;

fn bezier_ease(u: f32, h: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let m = 0.5 * (lo + hi);
        let r = 1.0 - m;
        let x = 3.0 * r * r * m * h.x + 3.0 * r * m * m * h.z + m * m * m;
        if (x > u) { hi = m; } else { lo = m; }
    }
    let s = 0.5 * (lo + hi);
    let r = 1.0 - s;
    return 3.0 * r * r * s * h.y + 3.0 * r * s * s * h.w + s * s * s;
}

// Shared 0 -> 1 -> 0 envelope of the grading effects: up by 0.433 s, back down by 1 s.
fn envelope(t: f32) -> f32 {
    if (t < 0.433333) { return bezier_ease(t / 0.433333, vec4f(0.45, 0.0, 0.8333333, 0.8333333)); }
    return 1.0 - bezier_ease(clamp((t - 0.433333) / (1.0 - 0.433333), 0.0, 1.0), vec4f(0.1666667, 0.1666667, 0.57, 1.0));
}

// The grading runs at half resolution: those textures hold the picture in their top-left quarter.
fn half_size(dims: vec2f) -> vec2f {
    return max(floor(dims * 0.5), vec2f(1.0));
}

fn half_uv(uv: vec2f, dims: vec2f) -> vec2f {
    let h = half_size(dims);
    return clamp(uv, 0.5 / h, 1.0 - 0.5 / h) * h / dims;
}

fn to_ycc(c: vec3f) -> vec3f {
    let y = dot(c, vec3f(0.299, 0.587, 0.114));
    return vec3f(y, (c.b - y) * 0.565, (c.r - y) * 0.713);
}

fn from_ycc(c: vec3f) -> vec3f {
    return vec3f(c.x + 1.403 * c.z, c.x - 0.344 * c.y - 0.714 * c.z, c.x + 1.77 * c.y);
}

fn grain_hash(p: vec2f) -> f32 {
    var q = fract(p * 1324.5179);
    q += dot(q, q.yx + 22.541);
    return fract((q.x + q.y) * q.y);
}

fn grain_gradient(p: vec2f, seed: f32) -> vec2f {
    var q = fract(p * (34.532 + seed * 0.3973));
    q += dot(q, q.yx + 15.434);
    let s = q.yx;
    return fract((q + s + 0.523) * s + grain_hash(p)) * 2.0 - 1.0;
}

// Smooth gradient noise on a grid of 100 reference pixels (the short side counts 720).
fn grain(p: vec2f, seed: f32, scale: vec2f) -> f32 {
    let q = p * scale / 100.0;
    let cell = floor(q);
    let f = fract(q);
    let w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let a = dot(grain_gradient(cell, seed), f);
    let b = dot(grain_gradient(cell + vec2f(1.0, 0.0), seed), f - vec2f(1.0, 0.0));
    let c = dot(grain_gradient(cell + vec2f(0.0, 1.0), seed), f - vec2f(0.0, 1.0));
    let d = dot(grain_gradient(cell + vec2f(1.0), seed), f - vec2f(1.0));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y) * 0.5 + 0.5;
}

fn to_hsl(c: vec3f) -> vec3f {
    let lo = min(min(c.r, c.g), c.b);
    let hi = max(max(c.r, c.g), c.b);
    let span = hi - lo;
    var o = vec3f(0.0, 0.0, (hi + lo) * 0.5);
    if (span != 0.0) {
        o.y = select(span / (2.0 - hi - lo), span / (hi + lo), o.z < 0.5);
        let dr = ((hi - c.r) / 6.0 + span * 0.5) / span;
        let dg = ((hi - c.g) / 6.0 + span * 0.5) / span;
        let db = ((hi - c.b) / 6.0 + span * 0.5) / span;
        if (c.r == hi) { o.x = db - dg; }
        else if (c.g == hi) { o.x = 1.0 / 3.0 + dr - db; }
        else { o.x = 2.0 / 3.0 + dg - dr; }
        o.x = fract(o.x);
    }
    return o;
}

fn from_hsl(c: vec3f) -> vec3f {
    if (c.y == 0.0) { return vec3f(c.z); }
    let b = select(c.z + c.y - c.y * c.z, c.z * (1.0 + c.y), c.z < 0.5);
    let a = 2.0 * c.z - b;
    let h = fract(c.x) * 6.0;
    let hue = clamp(vec3f(abs(h - 3.0) - 1.0, 2.0 - abs(h - 2.0), 2.0 - abs(h - 4.0)), vec3f(0.0), vec3f(1.0));
    return vec3f(a) + hue * (b - a);
}

fn overlay(base: f32, top: f32) -> f32 {
    return select(1.0 - 2.0 * (1.0 - base) * (1.0 - top), 2.0 * base * top, base < 0.5);
}

fn chroma_noise(c_in: vec3f, uv: vec2f, amount: f32, scale: vec2f) -> vec3f {
    var c = c_in;
    let p = uv * vec2f(2.3255813, 112.35955) - 10.0;
    let seed = amount;
    var n = vec3f(grain(p, seed, scale), grain(p - vec2f(1.01, 0.137), seed, scale), grain(p - vec2f(1.73, 0.659), seed, scale));
    let luma = dot(c, vec3f(0.299, 0.587, 0.114));
    n.x *= 0.92 + luma * 0.05 + amount * 0.05;
    n.y *= 0.85 + luma * 0.18 + amount * 0.05;
    n = clamp(n, vec3f(0.0), vec3f(1.0));
    var hsl = to_hsl(n);
    hsl.y = min(1.0, hsl.y * (1.0 + amount * 10.0));
    n = clamp(from_hsl(hsl), vec3f(0.0), vec3f(1.0));
    c = mix(c, n, amount * 0.5);
    let o = vec3f(overlay(c.r, n.r), overlay(c.g, n.g), overlay(c.b, n.b));
    let lift = max(1.0 - (1.0 - n) / 0.5, vec3f(0.0));
    let shade = 0.5 * smoothstep(0.5882353, 0.5098039, dot(c, vec3f(0.299, 0.587, 0.114)));
    let o2 = mix(o, 1.0 - (1.0 - o) * (1.0 - lift), vec3f(shade));
    return mix(c, o2, min(0.8, amount * 10.0));
}

// Vignette remap of the amount slider to opacity.
fn vignette_opacity(a: f32) -> f32 {
    let o = a * (0.791515 + a * (-0.120212 + a * (19.1491 + a * (-64.6869 + a * (88.4132 + a * (-56.7089 + a * 14.1622))))));
    return clamp(o, 0.0, 1.0);
}

// S-shaped falloff from the centre (midpoint 0.5 and full feather: pivot 0.3857, power 3.049).
const VIG_REACH: f32 = 0.70710678 + 0.2875;
const VIG_PIVOT: f32 = 0.385692;
const VIG_POWER: f32 = 3.048780;

fn vignette_falloff(x: f32) -> f32 {
    if (x < VIG_PIVOT) { return VIG_PIVOT * pow(x / VIG_PIVOT, VIG_POWER); }
    return 1.0 - (1.0 - VIG_PIVOT) * pow((1.0 - x) / (1.0 - VIG_PIVOT), VIG_POWER);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let dims = vec2f(textureDimensions(smeared));
    let h = half_size(dims);
    if (f32(id.x) >= h.x || f32(id.y) >= h.y) { gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0)); return; }
    let uv = (vec2f(id.xy) + 0.5) / h;
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let env = envelope(t);
    let unit = dims / min(dims.x, dims.y) * 720.0;
    let step = 1.0 / unit;

    // Sideways sharpening against the average of the pixel and the few to its left.
    let here = textureSampleLevel(smeared, smp, half_uv(uv, dims), 0.0).rgb;
    let sharp = 0.02 * env;
    let reach = min(floor(5.0 * env + 0.5), 20.0);
    var sum = here;
    for (var k = 1; k <= 20; k++) {
        if (f32(k) > reach) { break; }
        sum += textureSampleLevel(smeared, smp, half_uv(uv - vec2f(f32(k) * step.x, 0.0), dims), 0.0).rgb;
    }
    let avg = to_ycc(sum / (reach + 1.0));
    let own = to_ycc(here);
    let ycc = vec3f(own.x + (own.x - avg.x) * sharp * 40.0, mix(own.yz, avg.yz, vec2f(min(1.0, sharp * 5.0))));
    var c = clamp(from_ycc(ycc), vec3f(0.0), vec3f(1.0));

    c = chroma_noise(c, uv, 0.02 * env, unit);

    // Black vignette.
    let fall = vignette_falloff(clamp(length(uv - 0.5) / VIG_REACH, 0.0, 1.0));
    c = c * (1.0 - fall * vignette_opacity(0.5 * env));

    // Exposure in stops, applied in linear light.
    let gain = pow(2.0, env);
    c = clamp(pow(pow(max(c, vec3f(0.0)), vec3f(2.2)) * gain, vec3f(1.0 / 2.2)), vec3f(0.0), vec3f(1.0));
    gpufx_write(id, vec4f(c, 1.0));
}
