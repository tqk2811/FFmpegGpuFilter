// Layers, crisp step 1: edge strength of the second clip (Sobel), lifted to 0.3 where flat.

const SPAN: f32 = 2.0;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// At the ends the last pass shows the plain clips, so the passes before it have nothing to do.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0; }

fn rings_idle() -> bool { return idle() || clock() >= 51.0 / 30.0; }

fn at(uv: vec2f, dx: f32, dy: f32, unit: vec2f) -> vec4f {
    return textureSampleLevel(second, smp, uv + vec2f(dx, dy) * unit, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || rings_idle()) { return; }
    let uv = gpufx_uv(id);
    let unit = 0.5 * min(globals.size.x, globals.size.y) / (720.0 * globals.size);
    let gx = -at(uv, -1.0, -1.0, unit) - 2.0 * at(uv, -1.0, 0.0, unit) - at(uv, -1.0, 1.0, unit)
        + at(uv, 1.0, -1.0, unit) + 2.0 * at(uv, 1.0, 0.0, unit) + at(uv, 1.0, 1.0, unit);
    let gy = -at(uv, -1.0, -1.0, unit) - 2.0 * at(uv, 0.0, -1.0, unit) - at(uv, 1.0, -1.0, unit)
        + at(uv, -1.0, 1.0, unit) + 2.0 * at(uv, 0.0, 1.0, unit) + at(uv, 1.0, 1.0, unit);
    let g = gx * gx + gy * gy;
    let e = mix(vec4f(0.3), g, g.r);
    gpufx_write(id, vec4f(e.rgb, 1.0));
}
