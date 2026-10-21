// Port of FFmpeg's colortemperature: multiply by the color of a black body at the given Kelvin.

fn kelvin2rgb(k: f32) -> vec3f {
    let kelvin = k / 100.0;
    var r = 1.0;
    var g = 0.0;
    var b = 0.0;
    if (kelvin <= 66.0) {
        r = 1.0;
        g = clamp(0.39008157876901960784 * log(kelvin) - 0.63184144378862745098, 0.0, 1.0);
    } else {
        let t = max(kelvin - 60.0, 0.0);
        r = clamp(1.29293618606274509804 * pow(t, -0.1332047592), 0.0, 1.0);
        g = clamp(1.12989086089529411765 * pow(t, -0.0755148492), 0.0, 1.0);
    }
    if (kelvin >= 66.0) {
        b = 1.0;
    } else if (kelvin <= 19.0) {
        b = 0.0;
    } else {
        b = clamp(0.54320678911019607843 * log(kelvin - 10.0) - 1.19625408914, 0.0, 1.0);
    }
    return vec3f(r, g, b);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let eps = 1.1920929e-7;
    let c = p.rgb;
    var n = mix(c, c * kelvin2rgb(params.temperature), params.mix);
    let l0 = max(c.x, max(c.y, c.z)) + min(c.x, min(c.y, c.z)) + eps;
    let l1 = max(n.x, max(n.y, n.z)) + min(n.x, min(n.y, n.z)) + eps;
    let kept = n * (l0 / l1);
    n = mix(n, kept, params.pl);
    gpufx_write(id, vec4f(n, p.a));
}
