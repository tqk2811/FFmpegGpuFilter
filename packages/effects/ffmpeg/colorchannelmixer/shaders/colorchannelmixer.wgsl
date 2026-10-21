// Port of FFmpeg's colorchannelmixer: a 4x4 matrix on R, G, B, A with optional color preservation.

fn lightness_of(mode: i32, c: vec3f) -> f32 {
    switch (mode) {
        case 1: { return max(c.x, max(c.y, c.z)) + min(c.x, min(c.y, c.z)); }
        case 2: { return max(c.x, max(c.y, c.z)); }
        case 3: { return (c.x + c.y + c.z + 1.0 / 255.0) / 3.0; }
        case 4: { return c.x + c.y + c.z; }
        case 5: { return length(c); }
        case 6: { return pow(abs(c.x * c.x * c.x + c.y * c.y * c.y + c.z * c.z * c.z), 1.0 / 3.0); }
        default: { return 1.0; }
    }
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    var o = vec3f(
        params.rr * p.x + params.rg * p.y + params.rb * p.z + params.ra * p.w,
        params.gr * p.x + params.gg * p.y + params.gb * p.z + params.ga * p.w,
        params.br * p.x + params.bg * p.y + params.bb * p.z + params.ba * p.w);
    let a = params.ar * p.x + params.ag * p.y + params.ab * p.z + params.aa * p.w;
    if (params.pc != 0) {
        let lin = lightness_of(params.pc, p.rgb);
        var lout = lightness_of(params.pc, o);
        if (lout <= 0.0) {
            lout = 1.0 / 510.0;
        }
        let kept = clamp(o, vec3f(0.0), vec3f(1.0)) * (lin / lout);
        o = mix(o, kept, params.pa);
    }
    gpufx_write(id, vec4f(o, a));
}
