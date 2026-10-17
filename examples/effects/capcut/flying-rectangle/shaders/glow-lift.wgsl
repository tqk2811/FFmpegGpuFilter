// Flying Rectangle glow: the softened second clip raised to the glow power, as the first round's input.

// Animation length (seconds of comp time) mapped onto progress 0..1.
const SPAN: f32 = 2.0;
// Comp time at which the second clip takes over.
const SWAP_AT: f32 = 1.2;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// The chain only matters while the second clip shows; the last pass handles the exact ends.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0 || clock() < SWAP_AT; }

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let c = textureSampleLevel(soft, smp, gpufx_uv(id), 0.0);
    gpufx_write(id, vec4f(c.rgb * c.rgb, 1.0));
}
