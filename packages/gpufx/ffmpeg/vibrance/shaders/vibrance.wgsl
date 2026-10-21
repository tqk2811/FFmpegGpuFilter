// Port of FFmpeg's vibrance: saturation that depends on how saturated the pixel already is.

fn sign_of(x: f32) -> f32 {
    return select(-1.0, 1.0, x > 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let c = p.rgb;
    let alternate = select(-1.0, 1.0, params.alternate != 0u);
    let inten = vec3f(params.intensity * params.rbal, params.intensity * params.gbal, params.intensity * params.bbal);
    let sgn = vec3f(alternate * sign_of(inten.x), alternate * sign_of(inten.y), alternate * sign_of(inten.z));
    let sat = max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z));
    let luma = c.x * params.rlum + c.y * params.glum + c.z * params.blum;
    let k = vec3f(1.0) + inten * (vec3f(1.0) - sgn * sat);
    let o = mix(vec3f(luma), c, k);
    gpufx_write(id, vec4f(o, p.a));
}
