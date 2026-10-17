// Vertical gaussian streak blur that peaks at the burst.

// Length of the keyframed timeline in seconds; progress enters it 3% in and runs to its end.
const TIMELINE: f32 = 1.1;

fn timeline() -> f32 {
    return (0.03 + 0.97 * clamp(params.progress, 0.0, 1.0)) * TIMELINE;
}

// CSS-style cubic-bezier easing from (0,0) to (1,1) with handles (h.x,h.y) and (h.z,h.w).
fn ease(h: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
        let m = 0.5 * (lo + hi);
        let im = 1.0 - m;
        let bx = 3.0 * im * im * m * h.x + 3.0 * im * m * m * h.z + m * m * m;
        if (bx > x) { hi = m; } else { lo = m; }
    }
    let s = 0.5 * (lo + hi);
    let is = 1.0 - s;
    return 3.0 * is * is * s * h.y + 3.0 * is * s * s * h.w + s * s * s;
}

fn key(t: f32, t0: f32, t1: f32, a: f32, b: f32, h: vec4f) -> f32 {
    return mix(a, b, ease(h, clamp((t - t0) / (t1 - t0), 0.0, 1.0)));
}

// Blur strength on a 0..1000 scale.
fn strength(t: f32) -> f32 {
    let h = vec4f(0.333333, 0.0, 0.666667, 1.0);
    if (t >= 0.666667 && t < 0.766667) { return key(t, 0.666667, 0.766667, 0.0, 180.0, h); }
    if (t >= 0.766667 && t < 0.933333) { return key(t, 0.766667, 0.933333, 180.0, 0.0, h); }
    return 0.0;
}

// Taps per side for a strength; stronger blurs use relatively fewer taps.
fn tap_count(v: f32) -> f32 {
    var n = 0.0;
    if (v <= 10.0) { n = 0.8 * v; }
    else if (v <= 50.0) { n = (0.7 * v + 2.0) * 0.78; }
    else if (v <= 200.0) { n = (0.5 * v + 10.0) * 0.66; }
    else if (v <= 500.0) { n = (0.25 * v + 60.0) * 0.7; }
    else { n = (0.125 * v + 100.0) * 0.8; }
    if (n < 2.0) { n = floor(n + 0.5); }
    return n;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = timeline();
    let center = textureSampleLevel(lit, smp, uv, 0.0);
    let v = strength(t);
    let taps = tap_count(v);
    if (t < 0.6 || taps < 1e-5) { gpufx_write(id, center); return; }

    // Reach in uv along the short side (or half the long side, whichever is larger).
    let size = globals.size;
    let base = max(min(size.x, size.y), max(size.x, size.y) * 0.5);
    let reach = v / 1000.0;
    let sigma = reach / 3.0;
    let step_uv = vec2f(0.0, reach / max(taps, 1e-5) * base / size.y);
    var sum = center;
    var weight = 1.0;
    for (var i = 1; i <= 128; i++) {
        let fi = f32(i);
        if (fi > taps) { break; }
        let off = step_uv * fi;
        let w = exp(-0.5 * dot(off, off) / (sigma * sigma));
        let lo = uv - off;
        let hi = uv + off;
        if (lo.y >= 0.0) { sum += textureSampleLevel(lit, smp, lo, 0.0) * w; weight += w; }
        if (hi.y <= 1.0) { sum += textureSampleLevel(lit, smp, hi, 0.0) * w; weight += w; }
    }
    gpufx_write(id, clamp(sum / weight, vec4f(0.0), vec4f(1.0)));
}
