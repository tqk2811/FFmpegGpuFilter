// Port of FFmpeg's curves: natural cubic spline curves per channel and a master curve.
// Presets are FFmpeg's; a custom curve is the three points (0,0) (mid) (1,1).

struct Curve {
    n: u32,
    x: array<f32, 5>,
    y: array<f32, 5>,
};

fn c0() -> Curve {
    var c: Curve;
    c.n = 0u;
    return c;
}

fn c2(x0: f32, y0: f32, x1: f32, y1: f32) -> Curve {
    var c: Curve;
    c.n = 2u;
    c.x[0] = x0; c.y[0] = y0;
    c.x[1] = x1; c.y[1] = y1;
    return c;
}

fn c3(x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32) -> Curve {
    var c = c2(x0, y0, x1, y1);
    c.n = 3u;
    c.x[2] = x2; c.y[2] = y2;
    return c;
}

fn c4(x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) -> Curve {
    var c = c3(x0, y0, x1, y1, x2, y2);
    c.n = 4u;
    c.x[3] = x3; c.y[3] = y3;
    return c;
}

fn c5(x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, x4: f32, y4: f32) -> Curve {
    var c = c4(x0, y0, x1, y1, x2, y2, x3, y3);
    c.n = 5u;
    c.x[4] = x4; c.y[4] = y4;
    return c;
}

// channel: 0 red, 1 green, 2 blue, 3 master
fn preset_curve(preset: i32, channel: i32) -> Curve {
    switch (preset) {
        case 1: { // color_negative
            if (channel == 0) { return c3(0.129, 1.0, 0.466, 0.498, 0.725, 0.0); }
            if (channel == 1) { return c3(0.109, 1.0, 0.301, 0.498, 0.517, 0.0); }
            if (channel == 2) { return c3(0.098, 1.0, 0.235, 0.498, 0.423, 0.0); }
        }
        case 2: { // cross_process
            if (channel == 0) { return c5(0.0, 0.0, 0.25, 0.156, 0.501, 0.501, 0.686, 0.745, 1.0, 1.0); }
            if (channel == 1) { return c5(0.0, 0.0, 0.25, 0.188, 0.38, 0.501, 0.745, 0.815, 1.0, 0.815); }
            if (channel == 2) { return c4(0.0, 0.0, 0.231, 0.094, 0.709, 0.874, 1.0, 1.0); }
        }
        case 3: { // darker
            if (channel == 3) { return c3(0.0, 0.0, 0.5, 0.4, 1.0, 1.0); }
        }
        case 4: { // increase_contrast
            if (channel == 3) { return c5(0.0, 0.0, 0.149, 0.066, 0.831, 0.905, 0.905, 0.98, 1.0, 1.0); }
        }
        case 5: { // lighter
            if (channel == 3) { return c3(0.0, 0.0, 0.4, 0.5, 1.0, 1.0); }
        }
        case 6: { // linear_contrast
            if (channel == 3) { return c4(0.0, 0.0, 0.305, 0.286, 0.694, 0.713, 1.0, 1.0); }
        }
        case 7: { // medium_contrast
            if (channel == 3) { return c4(0.0, 0.0, 0.286, 0.219, 0.639, 0.643, 1.0, 1.0); }
        }
        case 8: { // negative
            if (channel == 3) { return c2(0.0, 1.0, 1.0, 0.0); }
        }
        case 9: { // strong_contrast
            if (channel == 3) { return c5(0.0, 0.0, 0.301, 0.196, 0.592, 0.6, 0.686, 0.737, 1.0, 1.0); }
        }
        case 10: { // vintage
            if (channel == 0) { return c3(0.0, 0.11, 0.42, 0.51, 1.0, 0.95); }
            if (channel == 1) { return c3(0.0, 0.0, 0.5, 0.48, 1.0, 1.0); }
            if (channel == 2) { return c3(0.0, 0.22, 0.49, 0.44, 1.0, 0.8); }
        }
        default: {}
    }
    return c0();
}

fn custom_or_preset(mid: vec2f, preset: i32, channel: i32) -> Curve {
    if (abs(mid.x - mid.y) > 1.0e-4) {
        return c3(0.0, 0.0, clamp(mid.x, 0.01, 0.99), clamp(mid.y, 0.0, 1.0), 1.0, 1.0);
    }
    return preset_curve(preset, channel);
}

// Natural cubic spline through the points, constant outside the first and last point.
fn eval_curve(c: Curve, v: f32) -> f32 {
    let n = c.n;
    if (n == 0u) { return v; }
    if (n == 1u) { return c.y[0]; }
    if (v <= c.x[0]) { return c.y[0]; }
    if (v >= c.x[n - 1u]) { return c.y[n - 1u]; }

    var h: array<f32, 5>;
    var r: array<f32, 5>;
    var bd: array<f32, 5>;
    var md: array<f32, 5>;
    var ad: array<f32, 5>;
    for (var i = 0u; i + 1u < n; i++) {
        h[i] = c.x[i + 1u] - c.x[i];
    }
    for (var i = 1u; i + 1u < n; i++) {
        r[i] = 6.0 * ((c.y[i + 1u] - c.y[i]) / h[i] - (c.y[i] - c.y[i - 1u]) / h[i - 1u]);
        bd[i] = h[i - 1u];
        md[i] = 2.0 * (h[i - 1u] + h[i]);
        ad[i] = h[i];
    }
    md[0] = 1.0;
    md[n - 1u] = 1.0;
    for (var i = 1u; i < n; i++) {
        let den = md[i] - bd[i] * ad[i - 1u];
        let k = select(1.0, 1.0 / den, den != 0.0);
        ad[i] = ad[i] * k;
        r[i] = (r[i] - bd[i] * r[i - 1u]) * k;
    }
    for (var j = 0u; j + 1u < n; j++) {
        let i = n - 2u - j;
        r[i] = r[i] - ad[i] * r[i + 1u];
    }

    var seg = 0u;
    for (var i = 0u; i + 2u < n; i++) {
        if (v >= c.x[i + 1u]) { seg = i + 1u; }
    }
    let hh = h[seg];
    let a = c.y[seg];
    let b = (c.y[seg + 1u] - a) / hh - hh * r[seg] / 2.0 - hh * (r[seg + 1u] - r[seg]) / 6.0;
    let cc = r[seg] / 2.0;
    let d = (r[seg + 1u] - r[seg]) / (6.0 * hh);
    let xx = v - c.x[seg];
    return clamp(a + b * xx + cc * xx * xx + d * xx * xx * xx, 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let cr = custom_or_preset(params.red, params.preset, 0);
    let cg = custom_or_preset(params.green, params.preset, 1);
    let cb = custom_or_preset(params.blue, params.preset, 2);
    let cm = custom_or_preset(params.master, params.preset, 3);
    let r = eval_curve(cm, eval_curve(cr, p.r));
    let g = eval_curve(cm, eval_curve(cg, p.g));
    let b = eval_curve(cm, eval_curve(cb, p.b));
    gpufx_write(id, vec4f(r, g, b, p.a));
}
