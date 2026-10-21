// Port of FFmpeg's exposure: (value - black) * scale, scale = 1 / |2^-exposure - black|.

fn to_linear(c: vec3f) -> vec3f {
    let lo = c / 12.92;
    let hi = pow((c + vec3f(0.055)) / 1.055, vec3f(2.4));
    return select(hi, lo, c <= vec3f(0.04045));
}

fn to_srgb(c: vec3f) -> vec3f {
    let x = max(c, vec3f(0.0));
    let lo = x * 12.92;
    let hi = 1.055 * pow(x, vec3f(1.0 / 2.4)) - vec3f(0.055);
    return select(hi, lo, x <= vec3f(0.0031308));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    var diff = abs(exp2(-params.exposure) - params.black);
    if (!(diff > 0.0)) {
        diff = 1.0 / 1024.0;
    }
    let scale = 1.0 / diff;
    var c = p.rgb;
    if (params.linear != 0u) {
        c = to_linear(c);
    }
    c = (c - vec3f(params.black)) * scale;
    if (params.linear != 0u) {
        c = to_srgb(c);
    }
    gpufx_write(id, vec4f(c, p.a));
}
