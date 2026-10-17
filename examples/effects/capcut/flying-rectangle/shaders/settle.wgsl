// Flying Rectangle: the second clip settles from a 2x zoom with motion blur (start of its glow chain).

// Animation length (seconds of comp time) mapped onto progress 0..1.
const SPAN: f32 = 2.0;
// Comp time at which the second clip takes over.
const SWAP_AT: f32 = 1.2;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// The chain only matters while the second clip shows; the last pass handles the exact ends.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0 || clock() < SWAP_AT; }

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bez(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(u: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let mid = 0.5 * (lo + hi);
        if (bez(c.x, c.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bez(c.y, c.w, 0.5 * (lo + hi));
}

// Holds a before t0, eases to b by t1, holds b after.
fn key(t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    return mix(a, b, ease(clamp((t - t0) / (t1 - t0), 0.0, 1.0), c));
}

// Zoom of the second clip; `lag` shifts the curve later (the previous-frame copy for the blur).
fn zoom(t: f32, lag: f32) -> f32 {
    return key(t, 1.2 + lag, 2.0 + lag, 2.0, 1.0, vec4f(0.16667, 0.16667, 0.16, 1.0));
}

fn grain(a: f32, b: f32) -> f32 {
    let r = fract(vec2f(a, b) * 13.517);
    let s = r + dot(r, r.yx + 22.541);
    return fract((s.x + s.y) * s.y);
}

fn inside01(p: vec2f) -> f32 {
    return step(0.0, p.x) * step(0.0, p.y) * step(p.x, 1.0) * step(p.y, 1.0);
}

// Motion-blurred zoom: six scales spread from a quarter-step before the previous frame's
// scale to a quarter-step past the current one, walked with dithered taps.
fn smeared_zoom(uv: vec2f, now: f32, before: f32) -> vec4f {
    var pts: array<vec2f, 6>;
    for (var k = 0; k < 6; k++) {
        let w = 0.5 * f32(k) / 5.0 + 0.75;
        let s = max(before * (1.0 - w) + now * w, 0.001);
        pts[k] = (uv - 0.5) / s + 0.5;
    }
    let n = floor(12.0 + 12.0 * smoothstep(0.0, 0.2, length(pts[5] - pts[0])));
    var acc = vec4f(0.0);
    for (var j = 0.0; j < 24.0; j += 1.0) {
        if (j >= n) { break; }
        let f = j / (n - 1.0) + (grain(j + uv.x, j * uv.y) - 0.5) / n;
        let seg = clamp(floor(f * 5.0), 0.0, 4.0);
        let i = u32(seg);
        let p = mix(pts[i], pts[i + 1u], f * 5.0 - seg);
        acc += textureSampleLevel(second, smp, p, 0.0) * inside01(p);
    }
    return acc / n;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let t = clock();
    let c = smeared_zoom(gpufx_uv(id), zoom(t, 0.0), zoom(t, 0.04));
    gpufx_write(id, vec4f(c.rgb, 1.0));
}
