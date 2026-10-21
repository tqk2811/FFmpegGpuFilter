// Layers, crisp step: soften the first clip, horizontal gaussian of 15 taps a side.

const SPAN: f32 = 2.0;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// At the ends the last pass shows the plain clips, so the passes before it have nothing to do.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0; }

fn rings_idle() -> bool { return idle() || clock() >= 51.0 / 30.0; }

fn bell(x: f32) -> f32 { return 0.39894 * exp(-0.5 * x * x / 16.0) / 4.0; }

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || rings_idle()) { return; }
    let uv = gpufx_uv(id);
    var dir = vec2f(0.0);
    dir[0] = min(globals.size.x, globals.size.y) / (720.0 * globals.size[0]);
    let w0 = bell(0.0);
    var sum = textureSampleLevel(first, smp, uv, 0.0) * w0;
    var total = w0;
    for (var i = 1; i <= 15; i++) {
        let w = bell(f32(i) / 15.0 * 15.0);
        sum += (textureSampleLevel(first, smp, uv + dir * f32(i), 0.0) + textureSampleLevel(first, smp, uv - dir * f32(i), 0.0)) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, clamp(sum / total, vec4f(0.0), vec4f(1.0)));
}
