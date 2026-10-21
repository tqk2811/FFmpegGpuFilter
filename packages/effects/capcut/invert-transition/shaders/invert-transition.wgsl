// Handheld-shaking cut from the first clip to the second, hidden under a light-leak flash blended in difference mode so the colours invert, with a vignette and exposure push.

// The animation runs over this many seconds of its own clock.
const SPAN: f32 = 1.0;
// The shake paths are written in pixels of a 504x672 canvas around this anchor.
const CANVAS: vec2f = vec2f(504.0, 672.0);
const ANCHOR: vec2f = vec2f(252.0, 336.0);
// Hard cut from the first to the second clip.
const CUT: f32 = 0.541667;
// Warm tint added around the cut.
const TINT: vec3f = vec3f(0.690196, 0.686275, 0.607843);
// Luma weights of the desaturation.
const LUMA: vec3f = vec3f(0.20854, 0.702086, 0.089374);

// One leg of a shake path: time span, timing curve, and the four Bezier points.
struct PathSeg {
    span: vec2f,
    ease: vec4f,
    p0: vec2f,
    c1: vec2f,
    c2: vec2f,
    p1: vec2f,
}

const SHAKE_FIRST = array<PathSeg, 12>(
    PathSeg(vec2f(0.0, 0.041667), vec4f(0.166667, 0.166666, 0.833333, 0.82326), vec2f(248.3736, 335.6880), vec2f(248.6640, 336.1300), vec2f(249.2535, 337.7868), vec2f(250.1156, 338.3396)),
    PathSeg(vec2f(0.041667, 0.083333), vec4f(0.166667, 0.15768, 0.833333, 0.803539), vec2f(250.1156, 338.3396), vec2f(250.9776, 338.8924), vec2f(252.3022, 339.3432), vec2f(253.5458, 339.0047)),
    PathSeg(vec2f(0.083333, 0.125), vec4f(0.166667, 0.144719, 0.833333, 0.84868), vec2f(253.5458, 339.0047), vec2f(254.7895, 338.6662), vec2f(256.4259, 337.2086), vec2f(257.5776, 336.3087)),
    PathSeg(vec2f(0.125, 0.166667), vec4f(0.166667, 0.185478, 0.833333, 0.861053), vec2f(257.5776, 336.3087), vec2f(258.7293, 335.4089), vec2f(259.8296, 333.6790), vec2f(260.4559, 333.6054)),
    PathSeg(vec2f(0.166667, 0.208333), vec4f(0.166667, 0.208201, 0.833333, 0.771739), vec2f(260.4559, 333.6054), vec2f(261.0822, 333.5318), vec2f(261.4055, 334.7549), vec2f(261.3355, 335.8671)),
    PathSeg(vec2f(0.208333, 0.25), vec4f(0.166667, 0.13125, 0.833333, 0.842212), vec2f(261.3355, 335.8671), vec2f(261.2655, 336.9792), vec2f(260.6513, 338.9892), vec2f(260.0358, 340.2783)),
    PathSeg(vec2f(0.25, 0.291667), vec4f(0.166667, 0.176604, 0.833333, 0.877051), vec2f(260.0358, 340.2783), vec2f(259.4204, 341.5673), vec2f(258.2297, 343.2612), vec2f(257.6429, 343.6013)),
    PathSeg(vec2f(0.291667, 0.333333), vec4f(0.166667, 0.258626, 0.833333, 0.76675), vec2f(257.6429, 343.6013), vec2f(257.0562, 343.9415), vec2f(256.8217, 343.1054), vec2f(256.5153, 342.3190)),
    PathSeg(vec2f(0.333333, 0.375), vec4f(0.166667, 0.129655, 0.833333, 0.846361), vec2f(256.5153, 342.3190), vec2f(256.2089, 341.5326), vec2f(256.3253, 339.7292), vec2f(255.8045, 338.8827)),
    PathSeg(vec2f(0.375, 0.416667), vec4f(0.166667, 0.182108, 0.833333, 0.822462), vec2f(255.8045, 338.8827), vec2f(255.2836, 338.0362), vec2f(254.3472, 337.5879), vec2f(253.3902, 337.2400)),
    PathSeg(vec2f(0.416667, 0.458333), vec4f(0.166667, 0.15705, 0.833333, 0.840213), vec2f(253.3902, 337.2400), vec2f(252.4332, 336.8922), vec2f(251.1261, 336.9464), vec2f(250.0625, 336.7956)),
    PathSeg(vec2f(0.458333, 0.5), vec4f(0.166667, 0.174165, 0.833333, 0.833333), vec2f(250.0625, 336.7956), vec2f(248.9990, 336.6448), vec2f(247.5180, 336.4118), vec2f(247.0090, 336.3350)),
);
const SHAKE_SECOND = array<PathSeg, 10>(
    PathSeg(vec2f(0.541667, 0.583333), vec4f(0.166667, 0.166664, 0.833333, 0.638858), vec2f(256.7002, 334.4333), vec2f(256.7573, 334.5060), vec2f(257.3581, 334.6724), vec2f(257.0432, 334.8696)),
    PathSeg(vec2f(0.583333, 0.625), vec4f(0.166667, 0.10833, 0.833333, 0.725057), vec2f(257.0432, 334.8696), vec2f(256.7282, 335.0669), vec2f(256.0833, 335.3858), vec2f(254.8105, 335.6167)),
    PathSeg(vec2f(0.625, 0.666667), vec4f(0.166667, 0.119576, 0.833333, 0.822087), vec2f(254.8105, 335.6167), vec2f(253.5378, 335.8477), vec2f(251.3340, 336.0993), vec2f(249.4067, 336.2553)),
    PathSeg(vec2f(0.666667, 0.708333), vec4f(0.166667, 0.156757, 0.833333, 0.863962), vec2f(249.4067, 336.2553), vec2f(247.4793, 336.4113), vec2f(244.8496, 336.7660), vec2f(243.2465, 336.5526)),
    PathSeg(vec2f(0.708333, 0.75), vec4f(0.166667, 0.215096, 0.833333, 0.840284), vec2f(243.2465, 336.5526), vec2f(241.6435, 336.3392), vec2f(240.3385, 335.8170), vec2f(239.7885, 334.9749)),
    PathSeg(vec2f(0.75, 0.791667), vec4f(0.166667, 0.174249, 0.833333, 0.811292), vec2f(239.7885, 334.9749), vec2f(239.2385, 334.1329), vec2f(239.5548, 332.7240), vec2f(239.9466, 331.5004)),
    PathSeg(vec2f(0.791667, 0.833333), vec4f(0.166667, 0.149235, 0.833333, 0.79536), vec2f(239.9466, 331.5004), vec2f(240.3384, 330.2769), vec2f(240.7560, 328.6722), vec2f(242.1393, 327.6335)),
    PathSeg(vec2f(0.833333, 0.875), vec4f(0.166667, 0.14058, 0.833333, 0.825753), vec2f(242.1393, 327.6335), vec2f(243.5226, 326.5949), vec2f(246.1061, 325.7056), vec2f(248.2464, 325.2686)),
    PathSeg(vec2f(0.875, 0.916667), vec4f(0.166667, 0.159718, 0.833333, 0.783752), vec2f(248.2464, 325.2686), vec2f(250.3867, 324.8315), vec2f(254.3555, 323.2225), vec2f(254.9811, 325.0110)),
    PathSeg(vec2f(0.916667, 0.958333), vec4f(0.166667, 0.13558, 0.833333, 0.833334), vec2f(254.9811, 325.0110), vec2f(255.6067, 326.7996), vec2f(252.4968, 334.1685), vec2f(252.0000, 336.0000)),
);

// Light-leak plate per 24 fps frame (8..16): coverage at six heights, top to bottom...
const LEAK_ROWS = array<array<f32, 6>, 9>(
    array<f32, 6>(0.15, 0.09, 0.06, 0.07, 0.08, 0.06),
    array<f32, 6>(0.27, 0.25, 0.25, 0.25, 0.28, 0.46),
    array<f32, 6>(0.27, 0.25, 0.25, 0.25, 0.28, 0.46),
    array<f32, 6>(0.65, 0.59, 0.80, 0.96, 0.97, 0.97),
    array<f32, 6>(0.65, 0.59, 0.80, 0.96, 0.97, 0.97),
    array<f32, 6>(0.98, 0.98, 0.98, 0.98, 0.98, 0.98),
    array<f32, 6>(0.98, 0.98, 0.72, 0.37, 0.21, 0.21),
    array<f32, 6>(0.65, 0.65, 0.48, 0.25, 0.14, 0.14),
    array<f32, 6>(0.32, 0.32, 0.27, 0.19, 0.14, 0.13));
// ...and its colour.
const LEAK_TINT = array<vec3f, 9>(
    vec3f(0.12, 0.07, 0.09), vec3f(0.50, 0.40, 0.36), vec3f(0.50, 0.40, 0.36),
    vec3f(0.87, 0.81, 0.76), vec3f(0.87, 0.81, 0.76), vec3f(0.98, 0.96, 0.90),
    vec3f(0.73, 0.55, 0.38), vec3f(0.49, 0.36, 0.25), vec3f(0.27, 0.19, 0.12));

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let s = 0.5 * (lo + hi);
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

// Value animated from `a` to `b` between times t0 and t1 with the given easing curve.
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, curve: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, bezier_ease(x, curve));
}

// Point on a cubic Bezier curve.
fn cubic(p0: vec2f, c1: vec2f, c2: vec2f, p1: vec2f, s: f32) -> vec2f {
    let inv = 1.0 - s;
    return inv * inv * inv * p0 + 3.0 * inv * inv * s * c1 + 3.0 * inv * s * s * c2 + s * s * s * p1;
}

// Position along one path leg at time t.
fn seg_at(g: PathSeg, t: f32) -> vec2f {
    let x = clamp((t - g.span.x) / (g.span.y - g.span.x), 0.0, 1.0);
    return cubic(g.p0, g.c1, g.c2, g.p1, bezier_ease(x, g.ease));
}

// Canvas position of the first clip's layer at time t (held before/after the path).
fn shake_first(t: f32) -> vec2f {
    var pos = SHAKE_FIRST[0].p0;
    for (var i = 0; i < 12; i++) {
        let g = SHAKE_FIRST[i];
        if (t >= g.span.x) { pos = seg_at(g, t); }
    }
    return pos;
}

// Canvas position of the second clip's layer at time t.
fn shake_second(t: f32) -> vec2f {
    var pos = SHAKE_SECOND[0].p0;
    for (var i = 0; i < 10; i++) {
        let g = SHAKE_SECOND[i];
        if (t >= g.span.x) { pos = seg_at(g, t); }
    }
    return pos;
}

// Mirror-repeat a coordinate into [0, 1].
fn mirror(p: vec2f) -> vec2f {
    let m = abs(p - 2.0 * floor((p + 1.0) * 0.5));
    return clamp(m, vec2f(0.0), vec2f(1.0));
}

// Saturation control: 1 + `k` keeps that share of the colour (k = 0 leaves it unchanged).
fn saturate_by(c: vec3f, k: f32) -> vec3f {
    let s = 1.0 + k;
    let w = LUMA * (1.0 - s);
    return clamp(vec3f(dot(c, w) + s * c.r, dot(c, w) + s * c.g, dot(c, w) + s * c.b), vec3f(0.0), vec3f(1.0));
}

// Cheap value noise for the streaks of the leak plate.
fn hash1(n: f32) -> f32 {
    return fract(sin(n * 127.1) * 43758.5453);
}
fn noise1(x: f32) -> f32 {
    let i = floor(x);
    let f = fract(x);
    return mix(hash1(i), hash1(i + 1.0), f * f * (3.0 - 2.0 * f));
}

// Light-leak plate (straight colour, coverage) at frame n.
fn leak(uv: vec2f, n: i32) -> vec4f {
    if (n < 8 || n > 16) { return vec4f(0.0); }
    let k = n - 8;
    let rows = LEAK_ROWS[k];
    let y = clamp(uv.y * 6.0 - 0.5, 0.0, 5.0);
    let i = min(i32(floor(y)), 4);
    var a = mix(rows[i], rows[i + 1], y - f32(i));
    if (n <= 12) {
        // Streaky frames: modulate across the width.
        a *= 0.6 + 0.8 * noise1(uv.x * 7.0 + f32(k) * 3.1);
    }
    return vec4f(LEAK_TINT[k], clamp(a, 0.0, 1.0));
}

// Vignette opacity curve for an `amount` in 0..1.
fn vignette_strength(x: f32) -> f32 {
    let x2 = x * x;
    let x3 = x2 * x;
    let x4 = x3 * x;
    let x5 = x4 * x;
    let x6 = x5 * x;
    let x7 = x6 * x;
    return clamp(0.791515 * x - 0.120212 * x2 + 19.1491 * x3 - 64.6869 * x4 + 88.4132 * x5 - 56.7089 * x6 + 14.1622 * x7, 0.0, 1.0);
}

// Round black vignette (midpoint 0.69, feather 0.7, roundness 1) darkening factor.
fn vignette(uv: vec2f, dims: vec2f, amount: f32) -> f32 {
    let strength = vignette_strength(amount);
    if (strength <= 0.0) { return 0.0; }
    let ratio = min(dims.x, dims.y) / max(dims.x, dims.y);
    let mid = (0.5 * 0.69 + 0.15 * 0.69 * 0.69) * (1.49 - 1.87 * ratio + 1.39 * ratio * ratio);
    let fs = 0.7 * (1.0 - 0.46508 * pow(0.69, 5.21286) - 0.33492 * 0.69);
    let pivot = 0.5 - 0.17 * fs * fs;
    let power = 1.0 / select(0.38 * fs + 0.01, 0.4 * fs, fs >= 0.5);
    let mean = sqrt(dims.x * dims.y) * pow(1.0 / ratio, 0.25);
    let d = length((uv - 0.5) * dims / mean);
    let v = clamp(d / (0.70710678 + mid), 0.0, 1.0);
    var curve = 0.0;
    if (v < pivot) {
        curve = pivot * pow(v / pivot, power);
    } else {
        curve = 1.0 - (1.0 - pivot) * pow((1.0 - v) / (1.0 - pivot), power);
    }
    return curve * strength;
}

// Exposure in linear light (gamma 2.2): scale by 2^stops, then add `offset`.
fn expose(c: vec3f, stops: f32, offset: f32) -> vec3f {
    let lin = pow(max(c, vec3f(0.0)), vec3f(2.2)) * exp2(stops) + vec3f(offset);
    return clamp(sign(lin) * pow(abs(lin), vec3f(1.0 / 2.2)), vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let dims = vec2f(textureDimensions(first));
    let linear = vec4f(0.166667, 0.166667, 0.833333, 0.833333);

    // Shaking clip, cut at CUT, each slightly desaturated.
    var color: vec3f;
    if (t < CUT) {
        let shift = (shake_first(t) - ANCHOR) / CANVAS;
        let c = textureSampleLevel(first, smp, mirror(uv - shift), 0.0).rgb;
        color = saturate_by(c, keyed(t, 0.0, 0.291667, 0.0, -0.35, linear));
    } else {
        let shift = (shake_second(t) - ANCHOR) / CANVAS;
        let c = textureSampleLevel(second, smp, mirror(uv - shift), 0.0).rgb;
        color = saturate_by(c, keyed(t, 0.541667, 0.916667, -0.3, 0.0, linear));
    }

    // Warm additive tint around the cut.
    if (t >= 0.458333 && t < 0.625) {
        var tint = keyed(t, 0.458333, 0.541667, 0.24, 0.35, linear);
        if (t >= 0.541667) { tint = keyed(t, 0.541667, 0.625, 0.35, 0.10, linear); }
        color = min(color + TINT * tint, vec3f(1.0));
    }

    // Light-leak plate in difference mode: bright parts invert the picture.
    let plate = leak(uv, i32(floor(t * 24.0 + 0.0)));
    color = mix(color, abs(color - plate.rgb), plate.a);

    // Vignette, then exposure push.
    let rise = vec4f(0.33333, 0.0, 0.833333, 0.833333);
    let fall = vec4f(0.166667, 0.166667, 0.666667, 1.0);
    var amount = keyed(t, 0.0, 0.291667, 0.0, 0.78, rise);
    if (t >= 0.708333) { amount = keyed(t, 0.708333, 0.958333, 0.78, 0.0, fall); }
    color *= 1.0 - vignette(uv, dims, amount);
    var stops = keyed(t, 0.0, 0.291667, 0.0, 1.1, rise);
    var offset = keyed(t, 0.0, 0.291667, 0.0, -0.08, rise);
    if (t >= 0.625) {
        stops = keyed(t, 0.625, 0.958333, 1.1, 0.0, fall);
        offset = keyed(t, 0.625, 0.958333, -0.08, 0.0, fall);
    }
    color = expose(color, stops, offset);
    gpufx_write(id, vec4f(color, 1.0));
}
