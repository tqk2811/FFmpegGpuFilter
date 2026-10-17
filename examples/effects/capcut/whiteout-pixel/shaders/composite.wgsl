// Zoom-blurred dot screen faded over the clips, with white and magenta light sweeps screened on top.

const TIMELINE: f32 = 1.99999;
const CUT_TIME: f32 = 1.0;
// Light sweep frames change at this rate on the animation clock, frame 0 at clock 0.
const LEAK_FPS: f32 = 30.0;
// Height of the soft sweep band, in frame heights.
const SWEEP_WIDTH: f32 = 0.87;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, k: vec4f) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * k.x + 3.0 * inv * s * s * k.z + s * s * s;
        let dx = 3.0 * inv * inv * k.x + 6.0 * inv * s * (k.z - k.x) + 3.0 * s * s * (1.0 - k.z);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * k.y + 3.0 * inv * s * s * k.w + s * s * s;
}

// Zoom of the dot screen: 1 -> 1.3 (ease out) between `start` and `start + 0.5`, then back to 1
// (ease in) by `start + 0.933333`. `start` is 0.5 for the current zoom, 0.533333 for the trailing one.
fn zoom_at(t: f32, start: f32) -> f32 {
    let peak = start + 0.5;
    if (t < peak) {
        let x = clamp((t - start) / 0.5, 0.0, 1.0);
        return mix(1.0, 1.3, bezier_ease(x, vec4f(0.166667, 0.166667, 0.666667, 1.0)));
    }
    let x = clamp((t - peak) / 0.433333, 0.0, 1.0);
    return mix(1.3, 1.0, bezier_ease(x, vec4f(0.333333, 0.0, 0.833333, 0.833333)));
}

// Opacity of the dot screen: in over 0.4..0.5 s, held, out over 1.433..1.533 s.
fn screen_opacity(t: f32) -> f32 {
    return clamp((t - 0.4) / 0.1, 0.0, 1.0) * (1.0 - clamp((t - 1.433333) / 0.1, 0.0, 1.0));
}

// Per-pixel jitter in [0, 1) for the blur sample positions.
fn jitter(a: f32, b: f32) -> f32 {
    var q = fract(vec2f(a, b) * 13.517);
    q += dot(q, q.yx + 22.541);
    return fract((q.x + q.y) * q.y);
}

// Dot screen read through a zoom about the centre; zero outside the frame.
fn dots_at(q: vec2f) -> vec3f {
    if (any(q < vec2f(0.0)) || any(q > vec2f(1.0))) { return vec3f(0.0); }
    return textureSampleLevel(dots, smp, q, 0.0).rgb;
}

// Light sweep for frame `f`: colour and coverage. A soft horizontal band whose centre
// travels down the frame (white), then a magenta one, slightly dimmer at the sides.
fn sweep(f: i32, uv: vec2f) -> vec4f {
    // Square sweep artwork fitted to cover the frame (cropped, not stretched).
    let ratio = globals.size.x / globals.size.y;
    var q = uv - 0.5;
    if (ratio > 1.0) { q.y /= ratio; } else { q.x *= ratio; }
    q += 0.5;
    var centre: f32;
    var tint: vec3f;
    if (f >= 24 && f <= 29) {
        centre = 1.85 - 0.65 * f32(f - 24);
        tint = vec3f(1.0, 0.98, 1.0);
    } else if (f >= 31 && f <= 36) {
        centre = -1.18 + 0.68 * f32(f - 31);
        tint = vec3f(1.0, 0.09, 0.97);
    } else {
        return vec4f(0.0);
    }
    let d = (q.y - centre) / SWEEP_WIDTH;
    let side = 1.0 - 0.16 * (q.x - 0.5) * (q.x - 0.5);
    return vec4f(tint, clamp(exp(-d * d) * side, 0.0, 1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * TIMELINE;

    var color: vec3f;
    if (t < CUT_TIME) {
        color = textureSampleLevel(first, smp, uv, 0.0).rgb;
    } else {
        color = textureSampleLevel(second, smp, uv, 0.0).rgb;
    }

    let fade = screen_opacity(t);
    if (fade > 0.0) {
        // Six zoom levels spread between the trailing and the current zoom (weights
        // 0.75..1.25, so the trail overshoots on both sides); two jittered samples
        // walk along that path.
        let now = zoom_at(t, 0.5);
        let before = zoom_at(t, 0.533333);
        var spots: array<vec2f, 6>;
        for (var i = 0; i < 6; i++) {
            let w = 0.75 + 0.1 * f32(i);
            let z = before * (1.0 - w) + now * w;
            spots[i] = (uv - 0.5) / z + 0.5;
        }
        let gl_y = 1.0 - uv.y;
        var acc = vec3f(0.0);
        for (var n = 0; n < 2; n++) {
            let k = f32(n);
            let s = k + (jitter(k + uv.x, k * gl_y) - 0.5) * 0.5;
            // Segment of the path: 0..4, each one a fifth of the walk (ends extrapolate).
            let seg = clamp(i32(ceil(s * 5.0)) - 1, 0, 4);
            let q = mix(spots[seg], spots[seg + 1], s * 5.0 - f32(seg));
            acc += dots_at(q);
        }
        color = mix(color, acc * 0.5, fade);
    }

    let frame = i32(floor(t * LEAK_FPS + 0.5));
    let leak = sweep(frame, uv);
    let lit = 1.0 - (1.0 - color) * (1.0 - leak.rgb);
    gpufx_write(id, vec4f(mix(color, lit, leak.a), 1.0));
}
