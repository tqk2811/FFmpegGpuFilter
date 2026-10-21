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
    // c[0..8]: the 3x3 neighbourhood, row by row (c[4], the centre, has weight 0)
    var c: array<vec3f, 9>;
    for (var j = 0; j < 9; j++) {
        c[j] = ld(p + vec2i(j % 3 - 1, j / 3 - 1), size);
    }
    // FFmpeg's eight kernels: 5 on three consecutive cells and -3 on the other five, where the
    // cells are taken in row-major order without the centre (c0 c1 c2 c3 c5 c6 c7 c8), cyclic.
    // This is not the textbook clockwise Kirsch ring (FFmpeg's kernels are what is ported).
    var ring: array<vec3f, 8>;
    ring[0] = c[0]; ring[1] = c[1]; ring[2] = c[2]; ring[3] = c[3];
    ring[4] = c[5]; ring[5] = c[6]; ring[6] = c[7]; ring[7] = c[8];
    let total = ring[0] + ring[1] + ring[2] + ring[3] + ring[4] + ring[5] + ring[6] + ring[7];
    var best = vec3f(-1.0e9);
    for (var k = 0; k < 8; k++) {
        let three = ring[k] + ring[(k + 1) % 8] + ring[(k + 2) % 8];
        // 5 * three - 3 * (total - three)
        best = max(best, 8.0 * three - 3.0 * total);
    }
    let e = abs(best) * params.scale + params.delta / 255.0;
    gpufx_write(id, vec4f(e, textureLoad(src, p, 0).a));
}
