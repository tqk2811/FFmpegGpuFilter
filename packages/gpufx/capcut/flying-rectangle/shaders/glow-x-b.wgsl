// Flying Rectangle glow: horizontal blur of a round, reading the odd buffer.

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
    var acc = lin(textureSampleLevel(glow_b, smp, uv, 0.0)) * total;
    for (var k = 1; k < 32; k++) {
        if (k >= taps) { break; }
        let w = bell(f32(k) / span * 15.0);
        let o = step * f32(k);
        acc += (lin(textureSampleLevel(glow_b, smp, uv + o, 0.0)) + lin(textureSampleLevel(glow_b, smp, uv - o, 0.0))) * w;
        total += 2.0 * w;
    }
    return pow(acc / total, vec3f(1.0 / GAMMA));
}

@compute @workgroup_size(8, 8)
fn sweep_x_1(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    gpufx_write(id, vec4f(sweep(gpufx_uv(id), 1, vec2f(1.0, 0.0)), 1.0));
}

@compute @workgroup_size(8, 8)
fn sweep_x_2(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    gpufx_write(id, vec4f(sweep(gpufx_uv(id), 2, vec2f(1.0, 0.0)), 1.0));
}

@compute @workgroup_size(8, 8)
fn sweep_x_3(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    gpufx_write(id, vec4f(sweep(gpufx_uv(id), 3, vec2f(1.0, 0.0)), 1.0));
}

@compute @workgroup_size(8, 8)
fn sweep_x_4(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    gpufx_write(id, vec4f(sweep(gpufx_uv(id), 4, vec2f(1.0, 0.0)), 1.0));
}

@compute @workgroup_size(8, 8)
fn sweep_x_5(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    gpufx_write(id, vec4f(sweep(gpufx_uv(id), 5, vec2f(1.0, 0.0)), 1.0));
}

@compute @workgroup_size(8, 8)
fn sweep_x_6(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    gpufx_write(id, vec4f(sweep(gpufx_uv(id), 6, vec2f(1.0, 0.0)), 1.0));
}

@compute @workgroup_size(8, 8)
fn sweep_x_7(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    gpufx_write(id, vec4f(sweep(gpufx_uv(id), 7, vec2f(1.0, 0.0)), 1.0));
}
