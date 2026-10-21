@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let spillmix = params.mix;
    let factor = (1.0 - spillmix) * (1.0 - params.expand);
    var spill = 0.0;
    if (params.screen != 0) {
        spill = max(c.b - (c.r * spillmix + c.g * factor), 0.0);
    } else {
        spill = max(c.g - (c.r * spillmix + c.b * factor), 0.0);
    }
    let scale = vec3f(params.red, params.green, params.blue);
    let rgb = max(c.rgb + spill * scale + params.brightness * spill, vec3f(0.0));
    var a = c.a;
    if (params.alpha != 0u) {
        a = 1.0 - spill;
    }
    gpufx_write(id, vec4f(rgb, a));
}
