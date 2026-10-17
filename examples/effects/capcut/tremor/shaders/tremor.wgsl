// Tremor, pass 3: the first clip shakes and zooms in under a closing vignette, then the second slams up from below and settles, all through a lens bulge.

const T0: f32 = 0.166667;    // the animation runs from 0.166667 s to 1.9 s
const T1: f32 = 1.9;
const CUT: f32 = 1.266667;   // the second clip takes over here
const COMP: f32 = 1280.0;

fn bezier_axis(a: f32, b: f32, t: f32) -> f32 {
    let s = 1.0 - t;
    return 3.0 * a * s * s * t + 3.0 * b * s * t * t + t * t * t;
}

// Keyframe easing: cubic Bezier (0,0)-(c.xy)-(c.zw)-(1,1), solved for x by bisection.
fn ease(c: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 10; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(c.x, c.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(c.y, c.w, 0.5 * (lo + hi));
}

fn key(t: f32, t0: f32, t1: f32, v0: f32, v1: f32, c: vec4f) -> f32 {
    return mix(v0, v1, ease(c, clamp((t - t0) / (t1 - t0), 0.0, 1.0)));
}

fn lin(t: f32, t0: f32, t1: f32, v0: f32, v1: f32) -> f32 {
    return mix(v0, v1, clamp((t - t0) / (t1 - t0), 0.0, 1.0));
}

// Vertical shake of the first clip, comp pixels around 60.
fn shake(t: f32) -> f32 {
    if (t < 0.166667) { return 60.0; }
    if (t < 0.266667) { return lin(t, 0.166667, 0.266667, 60.0, 59.0); }
    if (t < 0.366667) { return lin(t, 0.266667, 0.366667, 59.0, 61.0); }
    if (t < 0.466667) { return lin(t, 0.366667, 0.466667, 61.0, 57.0); }
    if (t < 0.566667) { return lin(t, 0.466667, 0.566667, 57.0, 63.0); }
    if (t < 0.666667) { return lin(t, 0.566667, 0.666667, 63.0, 53.0); }
    if (t < 0.766667) { return lin(t, 0.666667, 0.766667, 53.0, 67.0); }
    if (t < 0.866667) { return lin(t, 0.766667, 0.866667, 67.0, 50.0); }
    if (t < 0.955566) { return lin(t, 0.866667, 0.955566, 50.0, 70.0); }
    if (t < 1.033333) { return lin(t, 0.955566, 1.033333, 70.0, 39.0); }
    if (t < 1.133333) { return lin(t, 1.033333, 1.133333, 39.0, 89.0); }
    if (t < 1.2) { return lin(t, 1.133333, 1.2, 89.0, 35.0); }
    if (t < 1.266667) { return lin(t, 1.2, 1.266667, 35.0, 71.0); }
    return 71.0;
}

// Zoom of the first clip, percent.
fn zoom(t: f32) -> f32 {
    if (t < 0.166667) { return 100.0; }
    if (t < 1.0) { return key(t, 0.166667, 1.0, 100.0, 121.0, vec4f(1.0, 0.002800794, 0.766862381, 0.257464326)); }
    if (t < 1.266667) { return key(t, 1.0, 1.266667, 121.0, 88.0, vec4f(1.0, -0.00431007, 0.9999, 1.0)); }
    return 88.0;
}

// Height of the second clip centre, comp pixels (640 = in place).
fn rise(t: f32) -> f32 {
    if (t < 1.266667) { return 6995.0; }
    if (t < 1.433333) { return key(t, 1.266667, 1.433333, 6995.0, 624.0, vec4f(0.0001, 0.0, 0.0, 1.0)); }
    if (t < 1.5) { return key(t, 1.433333, 1.5, 624.0, 652.0, vec4f(0.166667, 0.0, 0.0, 0.999993)); }
    if (t < 1.566667) { return key(t, 1.5, 1.566667, 652.0, 636.0, vec4f(0.166667, 0.0, 0.0, 0.999988)); }
    if (t < 1.666667) { return key(t, 1.566667, 1.666667, 636.0, 642.0, vec4f(0.166667, 0.0, 0.0, 0.999951)); }
    if (t < 1.766667) { return key(t, 1.666667, 1.766667, 642.0, 638.711702, vec4f(0.261298, 0.0, 0.112936, 0.739474)); }
    if (t < 1.9) { return key(t, 1.766667, 1.9, 638.711702, 640.0, vec4f(0.244548, 0.250956, 0.567789, 0.999869)); }
    return 640.0;
}

// Lens strength in degrees of field of view.
fn lens_fov(t: f32) -> f32 {
    if (t < 0.166667) { return 0.0; }
    if (t < 1.0) { return key(t, 0.166667, 1.0, 0.0, 37.0, vec4f(1.0, 0.002800794, 0.766862381, 0.257464326)); }
    if (t < 1.266667) { return key(t, 1.0, 1.266667, 37.0, 16.0, vec4f(1.0, -0.00431007, 0.999, 1.0)); }
    if (t < 1.566667) { return key(t, 1.266667, 1.566667, 16.0, 0.0, vec4f(0.166666667, 0.0, 0.833333333, 0.833333333)); }
    return 0.0;
}

// Vignette opacity at radii 0, 0.2 ... 1.2, 1.414 (1 = edge midpoint), one row per 30 fps frame 7..33.
const VIGNETTE = array<f32, 216>(
    0.000, 0.000, 0.000, 0.000, 0.000, 0.004, 0.004, 0.004,
    0.000, 0.000, 0.000, 0.000, 0.000, 0.004, 0.008, 0.008,
    0.000, 0.000, 0.000, 0.000, 0.000, 0.008, 0.012, 0.012,
    0.000, 0.000, 0.000, 0.000, 0.002, 0.008, 0.016, 0.016,
    0.000, 0.000, 0.000, 0.000, 0.004, 0.012, 0.022, 0.024,
    0.000, 0.000, 0.000, 0.000, 0.004, 0.016, 0.027, 0.031,
    0.000, 0.000, 0.000, 0.000, 0.005, 0.024, 0.039, 0.043,
    0.000, 0.000, 0.000, 0.000, 0.008, 0.030, 0.051, 0.055,
    0.000, 0.000, 0.000, 0.000, 0.008, 0.036, 0.062, 0.067,
    0.000, 0.000, 0.000, 0.000, 0.012, 0.047, 0.079, 0.086,
    0.000, 0.000, 0.000, 0.000, 0.014, 0.058, 0.098, 0.106,
    0.000, 0.000, 0.000, 0.000, 0.017, 0.071, 0.119, 0.129,
    0.000, 0.000, 0.000, 0.000, 0.021, 0.087, 0.145, 0.157,
    0.000, 0.000, 0.000, 0.003, 0.026, 0.105, 0.174, 0.188,
    0.000, 0.000, 0.000, 0.004, 0.033, 0.128, 0.210, 0.227,
    0.000, 0.000, 0.000, 0.004, 0.041, 0.156, 0.254, 0.275,
    0.000, 0.000, 0.000, 0.004, 0.052, 0.189, 0.305, 0.329,
    0.000, 0.000, 0.000, 0.007, 0.064, 0.226, 0.360, 0.388,
    0.000, 0.000, 0.000, 0.008, 0.078, 0.265, 0.416, 0.447,
    0.000, 0.000, 0.004, 0.011, 0.095, 0.304, 0.467, 0.502,
    0.000, 0.000, 0.004, 0.014, 0.113, 0.339, 0.509, 0.545,
    0.000, 0.000, 0.004, 0.020, 0.136, 0.372, 0.541, 0.576,
    0.000, 0.003, 0.004, 0.030, 0.166, 0.405, 0.565, 0.600,
    0.000, 0.004, 0.006, 0.044, 0.198, 0.431, 0.578, 0.612,
    0.000, 0.004, 0.008, 0.059, 0.227, 0.454, 0.592, 0.624,
    0.001, 0.004, 0.012, 0.074, 0.250, 0.468, 0.596, 0.627,
    0.004, 0.004, 0.015, 0.088, 0.269, 0.480, 0.601, 0.631
);
const RADII = array<f32, 8>(0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.414);

fn vignette_row(row: i32, r: f32) -> f32 {
    var table = VIGNETTE;
    var radii = RADII;
    var i = 1;
    for (; i < 7; i++) {
        if (r <= radii[i]) { break; }
    }
    let k = clamp((r - radii[i - 1]) / (radii[i] - radii[i - 1]), 0.0, 1.0);
    return mix(table[row * 8 + i - 1], table[row * 8 + i], k);
}

// The vignette closes in frame by frame while the first clip shakes and is gone at the cut.
fn vignette(q: vec2f, t: f32) -> f32 {
    if (t < 0.166667 || t >= 1.3) { return 0.0; }
    let frame = i32(floor((t - 0.166667) * 30.0 + 1e-3));
    if (frame < 7) { return 0.0; }
    let r = length((q - vec2f(0.5)) * 2.0);
    return vignette_row(min(frame, 33) - 7, r);
}

fn fold1(x: f32) -> f32 {
    let m = (x - 1.0) - 2.0 * floor((x - 1.0) * 0.5);
    return abs(m - 1.0);
}

fn fold(q: vec2f) -> vec2f { return vec2f(fold1(q.x), fold1(q.y)); }

fn scene(q: vec2f, t: f32) -> vec3f {
    var c: vec3f;
    if (t < CUT) {
        let s = zoom(t) / 100.0;
        let off = vec2f(0.0, (shake(t) - 60.0) * s / COMP);
        c = textureSampleLevel(blur_a, smp, fold(vec2f(0.5) + (q - vec2f(0.5) - off) / s), 0.0).rgb;
    } else {
        let off = vec2f(0.0, (rise(t) - 640.0) / COMP);
        c = textureSampleLevel(blur_b, smp, fold(q - off), 0.0).rgb;
    }
    return c * (1.0 - vignette(q, t));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = mix(T0, T1, params.progress);
    // Lens: pull samples toward the centre, more toward the rim (radius measured against the diagonal).
    let fi = lens_fov(t) / 180.0;
    let k1 = 14.77 * pow(fi, 10.0) + 2.7 * pow(fi, 3.0);
    let k2 = 3.82 * pow(fi, 2.54) + 0.529 * fi;
    let d = uv - vec2f(0.5);
    let e = d * globals.size / length(globals.size);
    let r2 = dot(e, e);
    let q = d / (k2 * r2 + k1 * sqrt(r2) + 1.0) + vec2f(0.5);
    gpufx_write(id, vec4f(scene(q, t), 1.0));
}
