// Angle Swap: vertical glint streak, level 5 of 6. Each level blurs the previous one
// further (gamma 2.4 light mixing); the reach grows toward the cut.

// 0 -> 1 -> 0 triangle peaking at the cut, with a cubic ease-out.
fn peak(t: f32) -> f32 {
    let tri = select(2.0 - 2.0 * t, 2.0 * t, t < 0.5);
    let r = 1.0 - clamp(tri, 0.0, 1.0);
    return 1.0 - r * r * r;
}

const RADIUS: f32 = 32.0;
const REACH: f32 = 2.0;

fn bell(x: f32) -> f32 {
    return 0.39894 * exp(-0.5 * x * x / 16.0) / 4.0;
}

fn light(q: vec2f) -> vec4f {
    return pow(textureSampleLevel(streak_y3, smp, q, 0.0), vec4f(2.4));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    let spread = 0.18 * peak(t);
    let aspect = globals.size / min(globals.size.x, globals.size.y);
    var unit = vec2f(0.0);
    unit.y = REACH * spread / (aspect.y * 360.0);
    var sum = light(uv) * bell(0.0);
    var total = bell(0.0);
    for (var i = 1; i < 65; i++) {
        let k = f32(i);
        if (k + 0.5 > RADIUS) { break; }
        let w = bell(k / RADIUS * 16.0);
        sum += (light(uv + unit * k) + light(uv - unit * k)) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(pow(sum / total, vec4f(1.0 / 2.4)).rgb, 1.0));
}
