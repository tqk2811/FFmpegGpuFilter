// Angle Swap: pick small glints out of the brightest spots (only where a spot stands out
// from its blurred surroundings and no other bright area sits nearby), tint them with a
// shifting rainbow and keep them in a sparse scatter of noisy cells.

// One cubic Bezier segment of a keyframed track: (x1, y1) and (x4, y4) are the
// keys, (x2, y2) and (x3, y3) the handles, all in (progress, value) space.
// The progress is solved by bisection, then the value is read off the curve.
fn bez(q: f32, a: f32, b: f32, c: f32, d: f32) -> f32 {
    let p = 1.0 - q;
    return a * p * p * p + 3.0 * b * p * p * q + 3.0 * c * p * q * q + d * q * q * q;
}

fn segment(x: f32, x1: f32, x2: f32, x3: f32, x4: f32, y1: f32, y2: f32, y3: f32, y4: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 17; i++) {
        let mid = (lo + hi) * 0.5;
        if (bez(mid, x1, x2, x3, x4) > x) { hi = mid; } else { lo = mid; }
    }
    return bez((lo + hi) * 0.5, y1, y2, y3, y4);
}

// Exposure in stops: 0 -> 0.5 at the cut -> 0.
fn exposure_curve(t: f32) -> f32 {
    if (t <= 0.0 || t >= 1.0) { return 0.0; }
    if (t < 0.5) { return segment(t, 0.0, 0.4628895, 0.49995, 0.5, 0.0, 0.0, 0.5, 0.5); }
    return segment(t, 0.5, 0.50005, 0.6412568, 1.0, 0.5, 0.5, 0.0, 0.0);
}

// 0 -> 1 -> 0 triangle peaking at the cut, with a cubic ease-out.
fn peak(t: f32) -> f32 {
    let tri = select(2.0 - 2.0 * t, 2.0 * t, t < 0.5);
    let r = 1.0 - clamp(tri, 0.0, 1.0);
    return 1.0 - r * r * r;
}

fn bell(x: f32) -> f32 {
    return 0.39894 * exp(-0.5 * x * x / 16.0) / 4.0;
}

fn bright(c: vec3f) -> f32 {
    return smoothstep(0.5, 1.0, dot(c, vec3f(0.299, 0.587, 0.114)));
}

fn energy(q: vec2f) -> f32 {
    let c = textureSampleLevel(moved, smp, q, 0.0).rgb;
    return dot(c, c) * 0.333;
}

fn gate(e: f32, level: f32) -> f32 {
    return clamp((e - level) * 5.0, 0.0, 1.0);
}

fn scramble(p: vec2f) -> f32 {
    let a = fract(p * 1324.5179);
    let b = a + dot(a, a.yx + 22.541);
    return fract((b.x + b.y) * b.y);
}

// Gradient of one lattice cell, morphing over time.
fn lattice_grad(cell: vec2f, evolve: f32) -> vec2f {
    let h = scramble(cell);
    let s = evolve + h;
    let k0 = floor(s);
    let k1 = k0 + 1.0;
    let a0 = fract(cell * (0.3973 + (k0 * 4.412 + 34.532)));
    let b0 = a0 + dot(a0, a0.yx + 15.434);
    let a1 = fract(cell * (0.3973 + (k1 * 4.412 + 34.532)));
    let b1 = a1 + dot(a1, a1.yx + 15.434);
    let g0 = fract((b0 + b0.yx + 0.523) * b0.yx + h);
    let g1 = fract((b1 + b1.yx + 0.523) * b1.yx + h);
    return mix(g0, g1, fract(s)) * 2.0 - 1.0;
}

fn gradient_noise(p: vec2f, evolve: f32) -> f32 {
    let res = 720.0 * globals.size / min(globals.size.x, globals.size.y);
    let x = p * res * 0.01;
    let i = floor(x);
    let f = fract(x);
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let n00 = dot(lattice_grad(i, evolve), f);
    let n10 = dot(lattice_grad(i + vec2f(1.0, 0.0), evolve), f - vec2f(1.0, 0.0));
    let n01 = dot(lattice_grad(i + vec2f(0.0, 1.0), evolve), f - vec2f(0.0, 1.0));
    let n11 = dot(lattice_grad(i + vec2f(1.0, 1.0), evolve), f - vec2f(1.0, 1.0));
    return mix(mix(n00, n10, u.x), mix(n01, n11, u.x), u.y) * 0.5 + 0.5;
}

// Two octaves: the second is 1/0.56 times finer at 0.6 the weight.
fn cloud(p: vec2f, evolve: f32) -> f32 {
    let v = gradient_noise(p, evolve) + gradient_noise(p / 0.56, evolve) * 0.6;
    return clamp(v / 1.6, 0.0, 1.0);
}

fn hue(h: f32) -> vec3f {
    return clamp(abs(fract(h + vec3f(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, vec3f(0.0), vec3f(1.0));
}

// Iridescent colour field: hue bands bent by a slow domain warp.
fn rainbow(q: vec2f) -> vec3f {
    let m = abs((q + 1.0) - 2.0 * floor((q + 1.0) / 2.0) - 1.0);
    let w = vec2f(sin(m.y * 7.0 + sin(m.x * 5.0)), cos(m.x * 6.0 - sin(m.y * 4.0)));
    let h = m.x * 1.3 + m.y * 0.7 + 0.25 * w.x + 0.2 * w.y;
    return hue(h);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    let local = select(t, 0.0, t >= 1.0);
    let level = exposure_curve(local) / 0.5;
    let knee = select(0.2 + (level - 0.05) / 0.95 * 0.8, level * 4.0, level < 0.05);
    let threshold = 1.0 - 0.5 * knee;

    let aspect = globals.size / min(globals.size.x, globals.size.y);
    let unit = vec2f(4.0) / (aspect * 360.0);
    let c = textureSampleLevel(moved, smp, uv, 0.0).rgb;
    let centre = bright(c);
    var sum = centre * bell(0.0);
    var total = bell(0.0);
    for (var i = 1; i < 9; i++) {
        let k = f32(i);
        let w = bell(k);
        let o = unit * k;
        sum += (bright(textureSampleLevel(moved, smp, uv + vec2f(o.x, 0.0), 0.0).rgb)
              + bright(textureSampleLevel(moved, smp, uv - vec2f(o.x, 0.0), 0.0).rgb)
              + bright(textureSampleLevel(moved, smp, uv + vec2f(0.0, o.y), 0.0).rgb)
              + bright(textureSampleLevel(moved, smp, uv - vec2f(0.0, o.y), 0.0).rgb)) * w;
        total += 4.0 * w;
    }
    let surround = sum / total;

    var col = mix(c, rainbow(uv + vec2f(local / 6.0)) + 0.05, vec3f(1.5));
    col *= smoothstep(0.1, 0.3, clamp(centre - surround, 0.0, 1.0));

    var keep = gate(energy(uv), threshold);
    keep *= 1.0 - gate(energy(uv + vec2f(0.021, 0.0087)), 0.8);
    keep *= 1.0 - gate(energy(uv + vec2f(0.021, -0.0087)), 0.8);
    keep *= 1.0 - gate(energy(uv + vec2f(-0.021, -0.0087)), 0.8);
    keep *= 1.0 - gate(energy(uv + vec2f(-0.021, 0.0087)), 0.8);
    col *= keep;

    let q = uv * 4.0;
    var n = cloud((q - 10.5) * 8.0 + 0.5, local * 4.0);
    n *= step(scramble(floor((q - 10.0) * 20.0) * 0.05), 0.05) - 0.05;
    n = (n - 0.5) * 7.0 + 0.5;
    n = smoothstep(0.2, 1.0, clamp(n, 0.0, 1.0));
    gpufx_write(id, vec4f(col * n, 1.0));
}
