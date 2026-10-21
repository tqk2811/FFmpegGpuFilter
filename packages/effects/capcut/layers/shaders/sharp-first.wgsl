// Layers, crisp step: sharpen the first clip, more along its edges and in its bright parts.

const SPAN: f32 = 2.0;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// At the ends the last pass shows the plain clips, so the passes before it have nothing to do.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0; }

fn rings_idle() -> bool { return idle() || clock() >= 51.0 / 30.0; }

const AMOUNT: f32 = 0.9980987;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || rings_idle()) { return; }
    let uv = gpufx_uv(id);
    let src = textureSampleLevel(first, smp, uv, 0.0);
    let soft = textureSampleLevel(c_soft, smp, uv, 0.0);
    var edge = pow(textureSampleLevel(e_soft, smp, uv, 0.0).r, 0.4545);
    edge *= pow(dot(src.rgb, vec3f(0.299, 0.587, 0.114)), 0.4545);
    gpufx_write(id, vec4f(src.rgb + (src.rgb - soft.rgb) * edge * AMOUNT, src.a));
}
