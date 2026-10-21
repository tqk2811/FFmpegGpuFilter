// Contrast adaptive sharpen, per RGB channel on 8-bit levels (0..255) like FFmpeg's cas.
fn ld(p: vec2i, size: vec2i) -> vec3f {
    return round(textureLoad(src, clamp(p, vec2i(0), size - 1), 0).rgb * 255.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let a = ld(p + vec2i(-1, -1), size);
    let b = ld(p + vec2i(0, -1), size);
    let c = ld(p + vec2i(1, -1), size);
    let d = ld(p + vec2i(-1, 0), size);
    let e = ld(p, size);
    let f = ld(p + vec2i(1, 0), size);
    let g = ld(p + vec2i(-1, 1), size);
    let h = ld(p + vec2i(0, 1), size);
    let i = ld(p + vec2i(1, 1), size);
    var mn = min(min(min(d, e), min(f, b)), h);
    let mn2 = min(min(min(mn, a), min(c, g)), i);
    mn = mn + mn2;
    var mx = max(max(max(d, e), max(f, b)), h);
    let mx2 = max(max(max(mx, a), max(c, g)), i);
    mx = mx + mx2;
    let amp = sqrt(clamp(min(mn, vec3f(511.0) - mx) / max(mx, vec3f(0.000001)), vec3f(0.0), vec3f(1.0)));
    let strength = -mix(16.0, 4.01, params.strength);
    let weight = amp / strength;
    let r = ((b + d + f + h) * weight + e) / (vec3f(1.0) + 4.0 * weight);
    gpufx_write(id, vec4f(r / 255.0, textureLoad(src, p, 0).a));
}
