// Spotlight glow: vertical blur of each round, adding the round into the screen sum.

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

// Glow exposure: 2 for most of the way, faded out at the very end.
fn exposure(t: f32) -> f32 {
    return key(2.0, t, 1.4, 1.566667, 2.0, 0.0, vec4f(0.215805221, 0.0, 0.715950651, 0.978896148));
}

const GLOW_GAMMA: f32 = 2.2222;

fn glow_gain(t: f32) -> f32 { return pow(0.5 * exposure(t), 1.0 / GLOW_GAMMA); }

// The glow is worked out at a quarter of the frame size. That small picture lives in the top-left
// corner of the texture; the running screen sum of every round sits just to its right.
fn cells() -> vec2f { return max(floor(globals.size * 0.25), vec2f(1.0)); }

// Bilinear read of the small picture (clamped to its edges) at uv `q` of the small picture.
fn small_uv(q: vec2f, n: vec2f) -> vec2f {
    return clamp(q * n, vec2f(0.5), n - 0.5) / globals.size;
}

fn bell(x: f32) -> f32 { return 0.39894 * exp(-0.5 * x * x / 16.0) / 4.0; }

fn screen(a: vec4f, b: vec4f) -> vec4f { return 1.0 - (1.0 - a) * (1.0 - b); }

// One blur round along the axis: `reach` small texels per tap (scaled so it matches across the
// frame's aspect), `taps` taps each side, averaged after raising to the glow gamma.
fn blur_round(q: vec2f, n: vec2f, reach: f32, taps: i32) -> vec4f {
    var dir = vec2f(0.0);
    dir[1] = reach * min(globals.size.x, globals.size.y) / (720.0 * globals.size[1]);
    let w0 = bell(0.0);
    var sum = pow(textureSampleLevel(g_x, smp, small_uv(q, n), 0.0), vec4f(GLOW_GAMMA)) * w0;
    var total = w0;
    for (var i = 1; i <= taps; i++) {
        let w = bell(f32(i) / f32(taps) * 16.0);
        let o = dir * f32(i);
        let l = pow(textureSampleLevel(g_x, smp, small_uv(q - o, n), 0.0), vec4f(GLOW_GAMMA));
        let r = pow(textureSampleLevel(g_x, smp, small_uv(q + o, n), 0.0), vec4f(GLOW_GAMMA));
        sum += (l + r) * w;
        total += 2.0 * w;
    }
    return pow(sum / total, vec4f(1.0 / GLOW_GAMMA));
}

fn run_round(id: vec3u, reach: f32, taps: i32) {
    let n = cells();
    let cell = vec2f(id.xy);
    if (cell.y >= n.y || cell.x >= 2.0 * n.x) { return; }
    let inside = cell.x < n.x;
    var own = cell;
    if (!inside) { own.x -= n.x; }
    let blurred = blur_round((own + 0.5) / n, n, reach, taps);
    if (inside) { gpufx_write(id, blurred); return; }
    let sum = textureLoad(g_x, vec2i(id.xy), 0);
    gpufx_write(id, screen(sum, clamp(blurred * glow_gain(clock()), vec4f(0.0), vec4f(1.0))));
}

@compute @workgroup_size(8, 8)
fn round_y_1(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    run_round(id, 1.0, 1);
}

@compute @workgroup_size(8, 8)
fn round_y_2(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    run_round(id, 1.0, 2);
}

@compute @workgroup_size(8, 8)
fn round_y_3(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    run_round(id, 1.171875, 4);
}

@compute @workgroup_size(8, 8)
fn round_y_4(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    run_round(id, 2.34375, 4);
}

@compute @workgroup_size(8, 8)
fn round_y_5(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    run_round(id, 4.6875, 4);
}

@compute @workgroup_size(8, 8)
fn round_y_6(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    run_round(id, 9.375, 4);
}

@compute @workgroup_size(8, 8)
fn round_y_7(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    run_round(id, 18.75, 4);
}

@compute @workgroup_size(8, 8)
fn round_y_8(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    run_round(id, 37.5, 4);
}
