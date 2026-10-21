// Angle Swap: soften the glints a little vertically.

fn bell(x: f32) -> f32 {
    return 0.39894 * exp(-0.5 * x * x / 16.0) / 4.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let aspect = globals.size / min(globals.size.x, globals.size.y);
    var unit = vec2f(0.0);
    unit.y = 0.35 / (aspect.y * 360.0);
    var sum = textureSampleLevel(glints_h, smp, uv, 0.0) * bell(0.0);
    var total = bell(0.0);
    for (var i = 1; i < 8; i++) {
        let k = f32(i);
        let w = bell(k);
        sum += (textureSampleLevel(glints_h, smp, uv + unit * k, 0.0) + textureSampleLevel(glints_h, smp, uv - unit * k, 0.0)) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, sum / total);
}
