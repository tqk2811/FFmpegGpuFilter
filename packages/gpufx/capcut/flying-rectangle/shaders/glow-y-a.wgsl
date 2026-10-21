// Flying Rectangle glow: vertical blur of a round merged over the even buffer.

// Animation length (seconds of comp time) mapped onto progress 0..1.
const SPAN: f32 = 2.0;
// Comp time at which the second clip takes over.
const SWAP_AT: f32 = 1.2;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// The chain only matters while the second clip shows; the last pass handles the exact ends.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0 || clock() < SWAP_AT; }

// Light is blurred and merged after raising to this power.
const GAMMA: f32 = 2.0;
// Glow reach: each round spreads further; spacing is in pixels per tap and round number.
const SPACING: f32 = 0.952381;
const SIGMA: f32 = 4.0;

// Taps per side used by round `i` (one fewer than the whole part of its span).
fn round_span(i: i32) -> f32 {
    let fib = array<f32, 8>(1.0, 1.0, 2.0, 3.0, 5.0, 8.0, 13.0, 21.0);
    return min(2.5 * fib[i - 1], 2.5 * f32(i));
}

fn bell(x: f32) -> f32 { return exp(-x * x / (2.0 * SIGMA * SIGMA)) / (2.5066283 * SIGMA); }

fn lin(c: vec4f) -> vec3f { return pow(max(c.rgb, vec3f(0.0)), vec3f(GAMMA)); }

// Gaussian-weighted line blur of round `i` along `axis` (unit pixel steps), in linear light.
fn sweep(uv: vec2f, i: i32, axis: vec2f) -> vec3f {
    let span = round_span(i);
    let taps = i32(span);
    let step = axis * SPACING * f32(i) / globals.size;
    var total = bell(0.0);
    var acc = lin(textureSampleLevel(glow_x, smp, uv, 0.0)) * total;
    for (var k = 1; k < 32; k++) {
        if (k >= taps) { break; }
        let w = bell(f32(k) / span * 15.0);
        let o = step * f32(k);
        acc += (lin(textureSampleLevel(glow_x, smp, uv + o, 0.0)) + lin(textureSampleLevel(glow_x, smp, uv - o, 0.0))) * w;
        total += 2.0 * w;
    }
    return pow(acc / total, vec3f(1.0 / GAMMA));
}

// Glow strength over time: a flickering curve that dies out by the end.
fn exposure(t: f32) -> f32 {
    let keys = array<f32, 21>(
        0.681112, 0.576448, 0.325674, 0.607109, 0.645433, 0.738607, 0.666018,
        0.719415, 0.648002, 0.429666, 0.637148, 0.641756, 0.57045, 0.499144,
        0.427837, 0.356531, 0.285225, 0.213919, 0.142612, 0.071306, 0.0);
    let f = clamp((t - 1.2) / 0.04, 0.0, 20.0);
    let i = min(u32(f), 19u);
    return mix(keys[i], keys[i + 1u], f - f32(i));
}

fn screen3(a: vec3f, b: vec3f) -> vec3f { return 1.0 - (1.0 - a) * (1.0 - b); }

// Round `i`: screen its blur over the previous result with a falling weight, scale by the
// exposure, and keep the result in display light.
fn merge(id: vec3u, i: i32) {
    let uv = gpufx_uv(id);
    let prev = textureSampleLevel(glow_a, smp, uv, 0.0);
    let blur = lin(vec4f(sweep(uv, i, vec2f(0.0, 1.0)), 1.0));
    let base = lin(prev);
    let a = max(prev.a, 0.001);
    let weight = GAMMA / f32(i) * pow(0.05, 1.0 / 8.0);
    let p0 = base / a;
    let p1 = blur / a;
    let mixed = screen3(p0, p1) * weight + p0 * (1.0 - weight);
    let rgb = blur * (1.0 - prev.a) + mixed * prev.a;
    let gain = exposure(clock());
    gpufx_write(id, vec4f(pow(max(rgb * gain, vec3f(0.0)), vec3f(1.0 / GAMMA)), gain));
}

@compute @workgroup_size(8, 8)
fn merge_1(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    merge(id, 1);
}

@compute @workgroup_size(8, 8)
fn merge_2(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    merge(id, 2);
}

@compute @workgroup_size(8, 8)
fn merge_3(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    merge(id, 3);
}

@compute @workgroup_size(8, 8)
fn merge_4(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    merge(id, 4);
}

@compute @workgroup_size(8, 8)
fn merge_5(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    merge(id, 5);
}

@compute @workgroup_size(8, 8)
fn merge_6(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    merge(id, 6);
}

@compute @workgroup_size(8, 8)
fn merge_7(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    merge(id, 7);
}
