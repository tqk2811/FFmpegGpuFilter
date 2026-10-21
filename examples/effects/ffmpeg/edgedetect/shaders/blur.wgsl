// Pass 1: 5x5 gaussian (sigma 1.4, integer kernel / 159) on 8-bit levels, like FFmpeg's edgedetect.
// Mode 0 (wires) works on the luma only; the other modes blur each of R, G, B.
fn ld(p: vec2i, size: vec2i) -> vec3f {
    let c = round(textureLoad(src, clamp(p, vec2i(0), size - 1), 0).rgb * 255.0);
    if (params.mode == 0) {
        return vec3f(round(dot(c, vec3f(0.2126, 0.7152, 0.0722))));
    }
    return c;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    if (p.x < 2 || p.y < 2 || p.x >= size.x - 2 || p.y >= size.y - 2) {
        gpufx_write(id, vec4f(ld(p, size) / 255.0, 1.0));
        return;
    }
    var w = array<array<f32, 5>, 5>(
        array<f32, 5>(2.0, 4.0, 5.0, 4.0, 2.0),
        array<f32, 5>(4.0, 9.0, 12.0, 9.0, 4.0),
        array<f32, 5>(5.0, 12.0, 15.0, 12.0, 5.0),
        array<f32, 5>(4.0, 9.0, 12.0, 9.0, 4.0),
        array<f32, 5>(2.0, 4.0, 5.0, 4.0, 2.0));
    var sum = vec3f(0.0);
    for (var j = 0; j < 5; j++) {
        for (var i = 0; i < 5; i++) {
            sum += w[j][i] * ld(p + vec2i(i - 2, j - 2), size);
        }
    }
    gpufx_write(id, vec4f(floor(sum / 159.0) / 255.0, 1.0));
}
