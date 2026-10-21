fn frand(x: f32, y: f32) -> f32 {
    let r = sin(x * 12.9898 + y * 78.233) * 43758.545;
    return r - floor(r);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let r = frand(f32(p.x), f32(p.y));
    let dir = select(r * params.direction, -params.direction, params.direction < 0.0);
    let dist = select(r * f32(params.range), f32(-params.range), params.range < 0);
    let off = vec2i(vec2f(cos(dir), sin(dir)) * dist);
    let s = textureLoad(src, p, 0);
    let r0 = textureLoad(src, clamp(p + vec2i(off.x, off.y), vec2i(0), size - 1), 0).rgb;
    let r1 = textureLoad(src, clamp(p + vec2i(off.x, -off.y), vec2i(0), size - 1), 0).rgb;
    let r2 = textureLoad(src, clamp(p + vec2i(-off.x, -off.y), vec2i(0), size - 1), 0).rgb;
    let r3 = textureLoad(src, clamp(p + vec2i(-off.x, off.y), vec2i(0), size - 1), 0).rgb;
    let avg = (r0 + r1 + r2 + r3) * 0.25;
    let t = params.threshold;
    var ok: vec3<bool>;
    if (params.blur != 0u) {
        ok = abs(s.rgb - avg) < vec3f(t);
    } else {
        ok = (abs(s.rgb - r0) < vec3f(t)) & (abs(s.rgb - r1) < vec3f(t)) &
             (abs(s.rgb - r2) < vec3f(t)) & (abs(s.rgb - r3) < vec3f(t));
    }
    if (params.coupling != 0u) {
        ok = vec3<bool>(all(ok));
    }
    gpufx_write(id, vec4f(select(s.rgb, avg, ok), s.a));
}
