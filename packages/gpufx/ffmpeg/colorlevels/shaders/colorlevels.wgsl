// Port of FFmpeg's colorlevels: per-channel input/output black and white points.

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

fn coeff_of(imin: f32, imax: f32, omin: f32, omax: f32) -> f32 {
    let d = imax - imin;
    return (omax - omin) / select(1.0 / 255.0, d, abs(d) > 1.0e-6);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let imin = vec4f(params.rimin, params.gimin, params.bimin, params.aimin);
    let imax = vec4f(params.rimax, params.gimax, params.bimax, params.aimax);
    let omin = vec4f(params.romin, params.gomin, params.bomin, params.aomin);
    let omax = vec4f(params.romax, params.gomax, params.bomax, params.aomax);
    let k = vec4f(
        coeff_of(imin.x, imax.x, omin.x, omax.x),
        coeff_of(imin.y, imax.y, omin.y, omax.y),
        coeff_of(imin.z, imax.z, omin.z, omax.z),
        coeff_of(imin.w, imax.w, omin.w, omax.w));
    let o4 = (p - imin) * k + omin;
    var o = o4.rgb;
    if (params.preserve != 0) {
        let lin = lightness_of(params.preserve, p.rgb);
        let lout = lightness_of(params.preserve, o);
        if (lout > 0.0) {
            o = o * (lin / lout);
        }
    }
    gpufx_write(id, vec4f(o, o4.w));
}
