const dither = array<u32, 64>(
    0x00u, 0x60u, 0x18u, 0x78u, 0x06u, 0x66u, 0x1Eu, 0x7Eu,
    0x40u, 0x20u, 0x58u, 0x38u, 0x46u, 0x26u, 0x5Eu, 0x3Eu,
    0x10u, 0x70u, 0x08u, 0x68u, 0x16u, 0x76u, 0x0Eu, 0x6Eu,
    0x50u, 0x30u, 0x48u, 0x28u, 0x56u, 0x36u, 0x4Eu, 0x2Eu,
    0x04u, 0x64u, 0x1Cu, 0x7Cu, 0x02u, 0x62u, 0x1Au, 0x7Au,
    0x44u, 0x24u, 0x5Cu, 0x3Cu, 0x42u, 0x22u, 0x5Au, 0x3Au,
    0x14u, 0x74u, 0x0Cu, 0x6Cu, 0x12u, 0x72u, 0x0Au, 0x6Au,
    0x54u, 0x34u, 0x4Cu, 0x2Cu, 0x52u, 0x32u, 0x4Au, 0x2Au);

// Pass 2: vertical box average gives the local gradient; pixels near it move towards it, then ordered dither.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let r = params.radius;
    var sum = vec3f(0.0);
    for (var j = -r; j <= r; j++) {
        sum += textureLoad(tmp, clamp(p + vec2i(0, j), vec2i(0), size - 1), 0).rgb;
    }
    let dc = sum / f32(2 * r + 1);
    let s = textureLoad(src, p, 0);
    let delta = dc - s.rgb;
    // FFmpeg works in 1/128 of a level: m = max(0, 127 - |delta| / (2 * strength)), weight = m * m / 16384
    let m = max(vec3f(0.0), vec3f(127.0) - abs(delta) * 255.0 * 128.0 / (2.0 * params.strength));
    let wt = m * m / 16384.0;
    let d = f32(dither[(id.y & 7u) * 8u + (id.x & 7u)]);
    let dn = (d / 128.0 - 0.5) / 255.0;
    gpufx_write(id, vec4f(s.rgb + wt * delta + dn, s.a));
}
