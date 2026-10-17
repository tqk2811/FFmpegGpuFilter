// Spotlight, last pass: slide both clips down, desaturate and darken them, then lay the glowing beam on top.

const SPAN: f32 = 1.5999;
// Comp time at which the beam stops showing the second clip and starts showing the first.
const SWAP_AT: f32 = 0.8;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// At the ends the last pass shows the plain clips, so the passes before it have nothing to do.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0; }

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bez(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(u: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let mid = 0.5 * (lo + hi);
        if (bez(c.x, c.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bez(c.y, c.w, 0.5 * (lo + hi));
}

// Keeps `v` before t0, eases from a to b between t0 and t1, holds b after.
fn key(v: f32, t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    if (t < t0) { return v; }
    if (t >= t1) { return b; }
    return mix(a, b, ease((t - t0) / (t1 - t0), c));
}

const LINEAR = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

// How far both clips (and the beam with them) have slid down, as a fraction of the frame height.
fn slide(t: f32) -> f32 {
    var v = key(0.0, t, 0.0, 0.8, 0.0, 0.5, vec4f(1.0, 0.0, 0.999, 0.478261));
    v = key(v, t, 0.8, 1.566667, 0.5, 1.0, vec4f(0.001, 0.5, 0.0, 1.0));
    return v;
}

// Glow exposure: 2 for most of the way, faded out at the very end.
fn exposure(t: f32) -> f32 {
    return key(2.0, t, 1.4, 1.566667, 2.0, 0.0, vec4f(0.215805221, 0.0, 0.715950651, 0.978896148));
}

const GLOW_GAMMA: f32 = 2.2222;

fn glow_gain(t: f32) -> f32 { return pow(0.5 * exposure(t), 1.0 / GLOW_GAMMA); }

fn saturation(t: f32) -> f32 {
    var v = key(0.0, t, 0.0, 0.8, 0.0, -1.0, vec4f(0.42, 0.0, 0.999, 1.0));
    v = key(v, t, 0.8, 1.566667, -1.0, 0.0, vec4f(0.001, 0.0, 0.58, 1.0));
    return v;
}

// Opacity of the black layer over the clips, 0..1.
fn darkness(t: f32) -> f32 {
    var v = key(0.0, t, 0.0, 0.8, 0.0, 100.0, vec4f(1.0, 0.0, 0.999, 1.0));
    v = key(v, t, 0.8, 1.566667, 100.0, 0.0, vec4f(0.001, 0.0, 0.0, 1.0));
    return v * 0.01;
}

fn saturate_by(c: vec3f, amount: f32) -> vec3f {
    let k = amount + 1.0;
    let grey = vec3f(0.20854, 0.702086, 0.089374) * (1.0 - k);
    return clamp(vec3f(dot(c, grey + vec3f(k, 0.0, 0.0)), dot(c, grey + vec3f(0.0, k, 0.0)), dot(c, grey + vec3f(0.0, 0.0, k))), vec3f(0.0), vec3f(1.0));
}

fn cells() -> vec2f { return max(floor(globals.size * 0.25), vec2f(1.0)); }

// The glow sum, read bilinearly from its place right of the small picture.
fn glow_sum(uv: vec2f) -> vec4f {
    let n = cells();
    let p = clamp(uv * n, vec2f(0.5), n - 0.5) + vec2f(n.x, 0.0);
    return textureSampleLevel(g_y, smp, p / globals.size, 0.0);
}

fn screen3(a: vec3f, b: vec3f) -> vec3f { return 1.0 - (1.0 - a) * (1.0 - b); }

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clock();
    let drop = slide(t);
    var back: vec3f;
    if (uv.y < drop) {
        back = textureSampleLevel(second, smp, vec2f(uv.x, uv.y - drop + 1.0), 0.0).rgb;
    } else {
        back = textureSampleLevel(first, smp, vec2f(uv.x, uv.y - drop), 0.0).rgb;
    }
    back = saturate_by(back, saturation(t)) * (1.0 - darkness(t));

    // Glow: the rounds' screen sum, its brightest channel as coverage, screened onto the beam.
    let beam_c = textureSampleLevel(beam, smp, uv, 0.0);
    let gain = glow_gain(t);
    let halo = clamp(glow_sum(uv) * max(gain, 1.0), vec4f(0.0), vec4f(1.0));
    let peak = max(max(halo.r, halo.g), halo.b);
    var lit = beam_c;
    if (peak > 0.0) {
        let a = beam_c;
        let mixed = screen3(a.rgb / max(a.a, 1e-5), halo.rgb / peak);
        lit = vec4f(a.rgb * (1.0 - peak) + halo.rgb * (1.0 - a.a) + a.a * peak * mixed, a.a + peak - a.a * peak);
    }
    lit = clamp(lit, vec4f(0.0), vec4f(1.0));
    gpufx_write(id, vec4f(lit.rgb + back * (1.0 - lit.a), 1.0));
}
