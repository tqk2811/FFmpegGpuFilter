@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let y = dot(p.rgb, vec3f(0.2126, 0.7152, 0.0722));
    let u = (p.b - y) / 1.8556;
    let v = (p.r - y) / 1.5748;
    let bd = params.bh - params.bl;
    let rd = params.rh - params.rl;
    let nu = params.saturation * (u + y * bd + params.bl);
    let nv = params.saturation * (v + y * rd + params.rl);
    let b = y + nu * 1.8556;
    let r = y + nv * 1.5748;
    let g = (y - 0.2126 * r - 0.0722 * b) / 0.7152;
    gpufx_write(id, vec4f(clamp(vec3f(r, g, b), vec3f(0.0), vec3f(1.0)), p.a));
}
