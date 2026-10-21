fn ld(p: vec2i, size: vec2i) -> vec3f {
    let c = textureLoad(src, clamp(p, vec2i(0), size - 1), 0).rgb;
    if (params.luma != 0u) {
        return vec3f(dot(c, vec3f(0.2126, 0.7152, 0.0722)));
    }
    return c;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    // c[0..8]: the 3x3 neighbourhood, row by row
    var c: array<vec3f, 9>;
    for (var j = 0; j < 9; j++) {
        c[j] = ld(p + vec2i(j % 3 - 1, j / 3 - 1), size);
    }
    var a = vec3f(0.0);
    var b = vec3f(0.0);
    if (params.kind == 0) {
        a = -c[0] - 2.0 * c[1] - c[2] + c[6] + 2.0 * c[7] + c[8];
        b = -c[0] + c[2] - 2.0 * c[3] + 2.0 * c[5] - c[6] + c[8];
    } else if (params.kind == 1) {
        a = -c[0] - c[1] - c[2] + c[6] + c[7] + c[8];
        b = -c[0] + c[2] - c[3] + c[5] - c[6] + c[8];
    } else if (params.kind == 2) {
        a = c[0] - c[1];
        b = c[4] - c[3];
    } else {
        a = (-47.0 * c[0] - 162.0 * c[1] - 47.0 * c[2] + 47.0 * c[6] + 162.0 * c[7] + 47.0 * c[8]) / 256.0;
        b = (-47.0 * c[0] + 47.0 * c[2] - 162.0 * c[3] + 162.0 * c[5] - 47.0 * c[6] + 47.0 * c[8]) / 256.0;
    }
    let e = sqrt(a * a + b * b) * params.scale + params.delta / 255.0;
    gpufx_write(id, vec4f(e, textureLoad(src, p, 0).a));
}
