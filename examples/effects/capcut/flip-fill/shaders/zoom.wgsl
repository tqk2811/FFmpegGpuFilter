// Zoom pulse with a short radial motion trail, then the exact clips at the ends.

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

// Zoom factor: up to 1.1 at the burst and back. `lag` delays the curve (the trail end).
fn zoom(t_in: f32, lag: f32) -> f32 {
    let t = t_in - lag;
    if (t >= 0.633333 && t < 0.766667) { return key(t, 0.633333, 0.766667, 1.0, 1.1, vec4f(0.166667, 0.0, 0.833333, 1.0)); }
    if (t >= 0.766667 && t < 0.966667) { return key(t, 0.766667, 0.966667, 1.1, 1.0, vec4f(0.166667, 0.0, 0.642364, 1.006967)); }
    return 1.0;
}

// Zoom centre, a third of the way up the frame.
const PIVOT: vec2f = vec2f(0.5, 0.666667);
const TRAIL_SAMPLES: i32 = 24;

fn fold(p: vec2f) -> vec2f {
    return abs((p - 1.0) - 2.0 * floor((p - 1.0) / 2.0) - 1.0);
}

fn jitter(a: f32, b: f32) -> f32 {
    var q = fract(vec2f(a, b) * 13.517);
    q += dot(q, q.yx + 22.541);
    return fract((q.x + q.y) * q.y);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = timeline();
    let now = zoom(t, 0.0);
    let before = zoom(t, 0.033333);
    if (t < 0.6 || (abs(now - 1.0) < 1e-6 && abs(before - 1.0) < 1e-6)) {
        gpufx_write(id, vec4f(textureSampleLevel(streak, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    // Six zoom levels spread over the trail, sampled 24 times with per-pixel jitter.
    var levels: array<vec2f, 6>;
    for (var i = 0; i < 6; i++) {
        let w = 0.16 * f32(i) / 5.0 - 0.25 + 1.0;
        let s = before * (1.0 - w) + now * w;
        levels[i] = PIVOT + (uv - PIVOT) / s;
    }
    let gl_uv = vec2f(uv.x, 1.0 - uv.y);
    var sum = vec3f(0.0);
    for (var k = 0; k < TRAIL_SAMPLES; k++) {
        let fk = f32(k);
        var f = fk / f32(TRAIL_SAMPLES - 1) + (jitter(fk + gl_uv.x, fk * gl_uv.y) - 0.5) / f32(TRAIL_SAMPLES);
        f = clamp(f, 0.0, 1.0) * 5.0;
        let seg = min(i32(floor(f)), 4);
        let p = mix(levels[seg], levels[seg + 1], f - f32(seg));
        sum += textureSampleLevel(streak, smp, fold(p), 0.0).rgb;
    }
    gpufx_write(id, vec4f(sum / f32(TRAIL_SAMPLES), 1.0));
}
