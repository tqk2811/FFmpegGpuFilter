// Pass 1: horizontal box average over 2 * radius + 1 pixels.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let r = params.radius;
    var sum = vec3f(0.0);
    for (var i = -r; i <= r; i++) {
        sum += textureLoad(src, clamp(p + vec2i(i, 0), vec2i(0), size - 1), 0).rgb;
    }
    gpufx_write(id, vec4f(sum / f32(2 * r + 1), 1.0));
}
