// Pass 2 of 6: vertical box blur; rounds after `power` copy the input.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(t1));
    let p = vec2i(id.xy);
    if (params.power <= 0) {
        gpufx_write(id, textureLoad(t1, p, 0));
        return;
    }
    let r = select(params.radius_v, params.radius, params.radius_v < 0);
    var sum = vec4f(0.0);
    for (var i = -r; i <= r; i++) {
        sum += textureLoad(t1, clamp(p + vec2i(0, i), vec2i(0), size - 1), 0);
    }
    gpufx_write(id, sum / f32(2 * r + 1));
}
