// Signal Glitch 2, pass 3: horizontal motion smear that follows a sideways jolt of the picture.

const FRAMES: f32 = 19.0;
const COMP: f32 = 1280.0;
const TAPS: i32 = 64;
const REACH_FROM: f32 = 0.75;  // the smear covers 0.75..2.41 times the jolt offset
const REACH_SPAN: f32 = 1.66;

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

fn key(f: f32, f0: f32, f1: f32, v0: f32, v1: f32, c: vec4f) -> f32 {
    return mix(v0, v1, ease(c, clamp((f - f0) / (f1 - f0), 0.0, 1.0)));
}

// Horizontal jolt in comp pixels from the centre.
fn jolt(f: f32) -> f32 {
    if (f < 2.0) { return 0.0; }
    if (f < 5.0) { return key(f, 2.0, 5.0, 0.0, -51.0, vec4f(0.333333, 0.0, 0.666667, 1.0)); }
    if (f < 8.0) { return key(f, 5.0, 8.0, -51.0, 52.955123, vec4f(0.184986, 0.0, 0.575291, 0.959127)); }
    if (f < 9.0) { return key(f, 8.0, 9.0, 52.955123, 152.39119, vec4f(0.485699, 0.016289, 0.792565, 0.985208)); }
    if (f < 17.0) { return key(f, 9.0, 17.0, 152.39119, 0.0, vec4f(0.399546, 0.148726, 0.487978, 1.0)); }
    return 0.0;
}

fn fold1(x: f32) -> f32 {
    let m = (x - 1.0) - 2.0 * floor((x - 1.0) * 0.5);
    return abs(m - 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let f = clamp(params.progress, 0.0, 1.0) * FRAMES;
    let d = jolt(f) / COMP;
    if (d == 0.0) {
        gpufx_write(id, textureSampleLevel(wiped, smp, uv, 0.0));
        return;
    }
    var sum = vec4f(0.0);
    for (var i = 0; i < TAPS; i++) {
        let w = REACH_FROM + REACH_SPAN * f32(i) / f32(TAPS - 1);
        let q = vec2f(fold1(uv.x - d * w), fold1(uv.y));
        sum += textureSampleLevel(wiped, smp, q, 0.0);
    }
    gpufx_write(id, sum / f32(TAPS));
}
