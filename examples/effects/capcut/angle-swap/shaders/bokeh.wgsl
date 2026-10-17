// Angle Swap: diamond-shaped bokeh. Each pixel gathers a filled diamond of samples plus
// its outline, weighting bright samples far more, then leans toward the brightest one.

// One cubic Bezier segment of a keyframed track: (x1, y1) and (x4, y4) are the
// keys, (x2, y2) and (x3, y3) the handles, all in (progress, value) space.
// The progress is solved by bisection, then the value is read off the curve.
fn bez(q: f32, a: f32, b: f32, c: f32, d: f32) -> f32 {
    let p = 1.0 - q;
    return a * p * p * p + 3.0 * b * p * p * q + 3.0 * c * p * q * q + d * q * q * q;
}

fn segment(x: f32, x1: f32, x2: f32, x3: f32, x4: f32, y1: f32, y2: f32, y3: f32, y4: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 17; i++) {
        let mid = (lo + hi) * 0.5;
        if (bez(mid, x1, x2, x3, x4) > x) { hi = mid; } else { lo = mid; }
    }
    return bez((lo + hi) * 0.5, y1, y2, y3, y4);
}

// Bokeh strength: 0 -> 31.8 at the cut -> 0 (out of a full scale of 79).
fn bokeh_amount(t: f32) -> f32 {
    if (t <= 0.0 || t >= 1.0) { return 0.0; }
    if (t < 0.5) { return segment(t, 0.0, 0.5, 0.49995, 0.5, 0.0, 0.0, 31.8, 31.8); }
    return segment(t, 0.5, 0.50005, 0.5, 1.0, 31.8, 31.8, 0.0, 0.0);
}

const CORNERS = array<vec2f, 5>(vec2f(0.0, 11.0), vec2f(-11.0, 0.0), vec2f(0.0, -11.0), vec2f(11.0, 0.0), vec2f(0.0, 11.0));
const QUALITY: f32 = 0.7;
const LIGHT: f32 = 2.0;

fn mirrored(uv: vec2f) -> vec4f {
    let m = abs((uv + 1.0) - 2.0 * floor((uv + 1.0) / 2.0) - 1.0);
    return textureSampleLevel(bokeh_h, smp, m, 0.0);
}

fn luma(c: vec3f) -> f32 {
    return dot(c, vec3f(0.299, 0.587, 0.114));
}

fn inside(p: vec2f) -> bool {
    for (var i = 0; i < 4; i++) {
        let a = CORNERS[i];
        let e = CORNERS[i + 1] - a;
        let r = p - a;
        if (r.x * e.y - r.y * e.x > 0.0) { return false; }
    }
    return true;
}

struct Gather {
    sum: vec4f,
    weight: vec4f,
    best: vec4f,
    best_luma: f32,
};

fn take(g: ptr<function, Gather>, c: vec4f, scale: f32) {
    let l = luma(c.rgb);
    if (l >= (*g).best_luma) {
        (*g).best_luma = l;
        (*g).best = c;
    }
    let w = (pow(c, vec4f(9.0)) * 539.45 + 0.4) * scale;
    (*g).sum += w * c;
    (*g).weight += w;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    let amount = bokeh_amount(t) / 79.0;
    let strength = pow(amount, 0.35);
    if (strength < 0.01) {
        gpufx_write(id, vec4f(mirrored(uv).rgb, 1.0));
        return;
    }
    let blur_size = 7.5 * amount * 0.7;
    let unit = 2.0 * blur_size / (globals.size / min(globals.size.x, globals.size.y) * 720.0);
    let stride = mix(2.0, 0.5, strength) * mix(2.0, 1.0, QUALITY);
    let reach = max(5.0, 12.0 / stride * mix(0.65, 1.0, QUALITY));
    var g: Gather;
    g.sum = vec4f(0.0);
    g.weight = vec4f(0.4);
    g.best = vec4f(0.0);
    g.best_luma = 0.0;
    if (strength >= 0.3) {
        for (var i = 0; i < 30; i++) {
            let fi = f32(i);
            if (fi > reach) { break; }
            for (var j = 0; j < 30; j++) {
                let fj = f32(j);
                if (fj > reach) { break; }
                let p = vec2f(mix(-11.0, 11.0, fi / reach), mix(-11.0, 11.0, fj / reach));
                if (!inside(p)) { continue; }
                take(&g, mirrored(uv - 0.5 * p * unit), 1.0);
            }
        }
    }
    let side = length(CORNERS[1] - CORNERS[0]) / 1.5 * mix(0.5, 1.0, clamp(QUALITY * 1.5, 0.0, 1.0));
    let edge_len = max(side, 3.0);
    for (var e = 0; e < 4; e++) {
        for (var i = 0; i < 40; i++) {
            let d = f32(i) * stride;
            if (d > edge_len) { break; }
            let p = mix(CORNERS[e], CORNERS[e + 1], d / edge_len);
            take(&g, mirrored(uv - 0.5 * p * unit), 1.0);
        }
    }
    let soft = clamp(g.sum / g.weight, vec4f(0.0), vec4f(1.0));
    let c = mix(soft, g.best, clamp(soft * LIGHT, vec4f(0.0), vec4f(1.0)));
    gpufx_write(id, vec4f(c.rgb, 1.0));
}
