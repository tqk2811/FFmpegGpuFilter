// Signal Glitch 2, pass 2: briefly stretch the left half of the picture out from the vertical centre line.

const FRAMES: f32 = 19.0;
const SMOOTH = vec4f(0.33333333, 0.0, 0.66666667, 1.0);
const DIR: f32 = -1.5707963;          // stretch axis, -90 degrees
const AXIS_GAIN: f32 = 1.08 * 0.88866; // angle-dependent gain of the stretch at -90 degrees

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

fn stretch_at(f: f32) -> f32 {
    if (f < 2.0) { return 0.0; }
    if (f < 4.0) { return key(f, 2.0, 4.0, 0.0, 0.1); }
    if (f < 11.0) { return key(f, 4.0, 11.0, 0.1, 0.0); }
    return 0.0;
}

fn turn(v: vec2f, a: f32) -> vec2f {
    let c = cos(a);
    let s = sin(a);
    return vec2f(c * v.x + s * v.y, -s * v.x + c * v.y);
}

fn inside(q: vec2f) -> f32 {
    return select(0.0, 1.0, all(q >= vec2f(0.0)) && all(q <= vec2f(1.0)));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let f = clamp(params.progress, 0.0, 1.0) * FRAMES;
    let k = stretch_at(f);
    if (k <= 0.0) {
        gpufx_write(id, textureSampleLevel(split, smp, uv, 0.0));
        return;
    }
    let size = globals.size;
    let fit = size / min(size.x, size.y);
    let centre = vec2f(0.5);
    let r = turn((uv - centre) * fit, -DIR) / fit + centre;
    var q = r;
    if (r.y >= centre.y) {
        let d = r.y - centre.y;
        q.y = d / (1.0 + k * abs(d) * AXIS_GAIN * size.y / size.x) + centre.y;
    }
    q = turn((q - centre) * fit, DIR) / fit + centre;
    gpufx_write(id, textureSampleLevel(split, smp, q, 0.0) * inside(q));
}
