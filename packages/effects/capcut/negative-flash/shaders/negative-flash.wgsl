// A punchy colour-graded flicker on the first clip with two quick negative flashes, then a dip-dissolve into the second clip under a fading crushed-shadow grade.

// Animation time runs over this many seconds as progress goes from 0 to 1.
const SPAN: f32 = 2.0;
// Luma weights used by the saturation grade.
const SAT_LUMA: vec3f = vec3f(0.20854, 0.702086, 0.089374);

// Linear ramp from `a` to `b` between t0 and t1, held outside.
fn ramp(t: f32, t0: f32, t1: f32, a: f32, b: f32) -> f32 {
    return mix(a, b, clamp((t - t0) / (t1 - t0), 0.0, 1.0));
}

// Saturation: k = 1 keeps the colour, 0 is grey, values between blend toward the luma.
fn saturate_by(c: vec3f, k: f32) -> vec3f {
    let grey = dot(c, SAT_LUMA * (1.0 - k));
    return clamp(vec3f(grey) + c * k, vec3f(0.0), vec3f(1.0));
}

// Shadow / highlight curves; `hi` and `lo` are the curve exponents.
fn shadows_highlights(c: vec3f, hi: f32, lo: f32) -> vec3f {
    let inv = 1.0 - clamp(c, vec3f(0.0), vec3f(1.0));
    let inv2 = inv * inv;
    let lifted = (1.0 - pow(inv, vec3f(hi))) - (inv2 - inv2 * inv) * (hi - 1.0);
    let x = max(lifted, vec3f(0.0));
    let x2 = x * x;
    let shaped = pow(x, vec3f(lo)) + (x2 - x2 * x) * (lo - 1.0);
    return clamp(shaped, vec3f(0.0), vec3f(1.0));
}

// Fixed colour matrix giving the slight magenta tint of the warm grade.
fn tint(c: vec3f) -> vec3f {
    let r = dot(c, vec3f(1.0224349, 0.0495633, 0.0000431));
    let g = dot(c, vec3f(-0.0025076, 0.9765940, -0.0017537));
    let b = dot(c, vec3f(0.0008681, 0.0055816, 1.0516482));
    return clamp(vec3f(r, g, b), vec3f(0.0), vec3f(1.0));
}

// S-curve contrast around `pivot`, its ends bent back so 0 and 1 stay pinned.
// `shape` = (steepness, slope at pivot, left end gap, right end gap), `bend` = (left, right) slope gaps.
fn s_curve(x: f32, pivot: f32, shape: vec4f, bend: vec2f) -> f32 {
    let s = 1.0 / (1.0 + exp(-shape.x * (x - pivot)));
    let slope = shape.x * s * (1.0 - s);
    var y = s + pivot - 0.5;
    if (x <= pivot) {
        let q = (shape.y - slope) / bend.x;
        y += q * q * shape.z;
    } else {
        let q = (shape.y - slope) / bend.y;
        y += q * q * shape.w;
    }
    return y;
}

fn contrast(c: vec3f, pivot: f32, shape: vec4f, bend: vec2f) -> vec3f {
    let o = vec3f(s_curve(c.r, pivot, shape, bend), s_curve(c.g, pivot, shape, bend), s_curve(c.b, pivot, shape, bend));
    return clamp(o, vec3f(0.0), vec3f(1.0));
}

// Red / blue fringe offset for a sample position: zero at the borders, largest mid-frame.
fn fringe(uv: vec2f, amount: f32) -> vec2f {
    return vec2f(amount * 0.2, 0.0) * (1.0 - uv) * uv;
}

// Both clips as layered by the transition: the second fading in over the fading first (alpha-normalised).
fn clips(uv: vec2f, t: f32) -> vec3f {
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    let wa = ramp(t, 0.96, 1.24, 1.0, 0.0);
    let wb = ramp(t, 0.96, 1.24, 0.0, 1.0);
    return (b * wb + a * wa * (1.0 - wb)) / max(wb + wa * (1.0 - wb), 1e-4);
}

// Washed, crushed-shadow grade that fades in as the second clip arrives (fringe first).
fn crushed_grade(c: vec3f) -> vec3f {
    return saturate_by(shadows_highlights(c, 0.6704601, 1.9), 0.61);
}

// Clips after the crushed grade layer (active from t = 0.96).
fn crushed(uv: vec2f, t: f32) -> vec3f {
    let base = clips(uv, t);
    if (t < 0.96) { return base; }
    let d = fringe(uv, 0.197);
    let shifted = vec3f(clips(uv + d, t).r, base.g, clips(uv - d, t).b);
    let graded = crushed_grade(shifted);
    let w = select(ramp(t, 1.24, 1.96, 1.0, 0.0), ramp(t, 0.96, 1.24, 0.1, 1.0), t < 1.24);
    return mix(base, graded, w);
}

// Warm punchy grade: slight desaturation, lifted highlights, magenta tint.
fn warm_pixel(c: vec3f) -> vec3f {
    return tint(shadows_highlights(saturate_by(c, 0.91), 1.9, 1.0915769));
}

const WARM_SHAPE: vec4f = vec4f(5.8771898, 1.4692975, -0.0039738, 0.1038952);
const WARM_BEND: vec2f = vec2f(1.0667001, 1.2768410);

// Negative flash: inverted, nearly grey, with a hard high-key contrast.
fn negative_pixel(c: vec3f) -> vec3f {
    return saturate_by(1.0 - c, 0.11);
}

const NEG_SHAPE: vec4f = vec4f(9.4211779, 2.3552945, -0.3503327, -0.1542665);
const NEG_BEND: vec2f = vec2f(2.3521613, 0.8721948);

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;

    let base = crushed(uv, t);
    var col = base;
    let flash = (t >= 0.32 && t < 0.4) || (t >= 0.48 && t < 0.56);
    if (flash) {
        let d = fringe(uv, -0.153);
        let shifted = vec3f(negative_pixel(crushed(uv + d, t)).r, negative_pixel(base).g, negative_pixel(crushed(uv - d, t)).b);
        col = contrast(shifted, 0.85, NEG_SHAPE, NEG_BEND);
    } else if (t < 1.24) {
        // Warm grade: fades in over the first 0.16 s, out with the first clip.
        let d = fringe(uv, -0.143);
        let shifted = vec3f(warm_pixel(crushed(uv + d, t)).r, warm_pixel(base).g, warm_pixel(crushed(uv - d, t)).b);
        let graded = contrast(shifted, 0.43, WARM_SHAPE, WARM_BEND);
        let w = min(ramp(t, 0.0, 0.16, 0.0, 1.0), ramp(t, 0.96, 1.24, 1.0, 0.0));
        col = mix(base, graded, w);
    }
    gpufx_write(id, vec4f(col, 1.0));
}
