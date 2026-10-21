// Pass 5 of 6: horizontal box blur; rounds after `power` copy the input.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(t4));
    let p = vec2i(id.xy);
    if (params.power <= 2) {
        gpufx_write(id, textureLoad(t4, p, 0));
        return;
    }
    let r = params.radius;
    var sum = vec4f(0.0);
    for (var i = -r; i <= r; i++) {
        sum += textureLoad(t4, clamp(p + vec2i(i, 0), vec2i(0), size - 1), 0);
    }
    gpufx_write(id, sum / f32(2 * r + 1));
}
