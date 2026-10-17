// A glowing box of the second clip pops up in the centre, spins a quarter turn and stretches open to fill the frame.

// Animation clock length (seconds) that `progress` sweeps.
const SPAN: f32 = 2.0;
// The box is keyed on a 30 fps grid; each frame holds its shape.
const STEP_RATE: f32 = 30.0;
// Reference canvas the box sizes below are measured in (px, portrait 9:16).
const CANVAS: vec2f = vec2f(360.0, 640.0);
// Peak opacity of the white halo just outside the box edge.
const HALO_PEAK: f32 = 0.71;
// Halo reach as a fraction of the box's shorter half side.
const HALO_REACH: f32 = 0.35;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, x1: f32, y1: f32, x2: f32, y2: f32) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * x1 + 3.0 * inv * s * s * x2 + s * s * s;
        let dx = 3.0 * inv * inv * x1 + 6.0 * inv * s * (x2 - x1) + 3.0 * s * s * (1.0 - x2);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * y1 + 3.0 * inv * s * s * y2 + s * s * s;
}

// Box shape for one step: half width, half height (before the turn, px) and turn angle (degrees, clockwise).
fn box_shape(step: i32) -> vec3f {
    // Grow phase: the upright box scales up from nothing.
    var grow = array<vec2f, 13>(
        vec2f(1.34, 3.12), vec2f(4.75, 11.50), vec2f(10.03, 24.40), vec2f(16.72, 40.76),
        vec2f(24.42, 59.57), vec2f(32.75, 79.86), vec2f(41.27, 100.65), vec2f(49.58, 120.94),
        vec2f(57.30, 139.75), vec2f(64.00, 156.10), vec2f(69.29, 169.00), vec2f(72.76, 177.46),
        vec2f(74.0, 180.5));
    // Spin phase: fixed size, eased quarter turn.
    var turn = array<f32, 15>(0.0, 1.31, 4.99, 10.63, 17.84, 26.24, 35.42, 45.0, 54.27, 63.03,
        71.25, 78.58, 84.52, 88.51, 90.0);
    // Open phase: lying flat, the short side stretches until the box covers the canvas.
    var open = array<f32, 24>(74.0, 75.04, 78.04, 82.81, 89.25, 97.18, 106.37, 116.81, 128.27,
        140.58, 153.58, 167.12, 181.07, 195.27, 209.52, 223.70, 237.66, 251.21, 264.22, 276.52,
        287.96, 298.38, 307.63, 315.54);
    if (step < 6) { return vec3f(0.0); }
    if (step <= 18) { return vec3f(grow[step - 6], 0.0); }
    if (step <= 32) { return vec3f(74.0, 180.5, turn[step - 18]); }
    if (step <= 55) { return vec3f(open[step - 32], 180.5, 90.0); }
    return vec3f(340.0, 340.0, 90.0);
}

// Map an output uv onto the reference canvas so the canvas fills (covers) the frame.
fn to_canvas(uv: vec2f) -> vec2f {
    let canvas_aspect = CANVAS.x / CANVAS.y;
    let frame_aspect = globals.size.x / globals.size.y;
    var q = uv;
    if (canvas_aspect < frame_aspect) {
        q.y = (uv.y - 0.5) * (canvas_aspect / frame_aspect) + 0.5;
    } else {
        q.x = (uv.x - 0.5) * (frame_aspect / canvas_aspect) + 0.5;
    }
    return q * CANVAS;
}

// Darkened-then-restored look of the incoming clip (negative strength lifts the curve towards black).
fn shade(c: vec3f, strength: f32) -> vec3f {
    if (strength >= 0.0) { return c; }
    let power = 1.0 / (1.0 - strength * 2.5);
    let lowered = c - vec3f(-strength * 0.01);
    return clamp(vec3f(1.0) - pow(max(vec3f(1.0) - lowered, vec3f(0.0)), vec3f(power)), vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let step = clamp(i32(floor(t * STEP_RATE + 0.5)), 0, 59);
    let shape = box_shape(step);

    let back = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let front_raw = textureSampleLevel(second, smp, uv, 0.0).rgb;
    let x = clamp((t - 1.066667) / (1.533333 - 1.066667), 0.0, 1.0);
    let front = shade(front_raw, mix(-0.1, 0.0, bezier_ease(x, 0.33333, 0.0, 0.66667, 1.0)));

    if (shape.x <= 0.0) { gpufx_write(id, vec4f(back, 1.0)); return; }

    // Signed distance (canvas px) from the turned box outline.
    let p = to_canvas(uv) - CANVAS * 0.5;
    let a = radians(shape.z);
    let local = vec2f(cos(a) * p.x + sin(a) * p.y, -sin(a) * p.x + cos(a) * p.y);
    let q = abs(local) - shape.xy;
    let dist = length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0);

    let reach = HALO_REACH * min(shape.x, shape.y);
    let fall = clamp(1.0 - dist / reach, 0.0, 1.0);
    let halo = select(0.0, HALO_PEAK * fall * fall, dist > -0.5);
    let lit = mix(back, vec3f(1.0), halo);
    let inside = clamp(0.5 - dist, 0.0, 1.0);
    gpufx_write(id, vec4f(mix(lit, front, inside), 1.0));
}
