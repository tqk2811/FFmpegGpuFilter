@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2f(textureDimensions(src));
    let a = radians(params.angle);
    let dir = vec2f(cos(a), sin(a));
    let sigma = params.radius;
    if (sigma < 0.05) {
        gpufx_write(id, textureLoad(src, vec2i(id.xy), 0));
        return;
    }
    let n = i32(ceil(3.0 * sigma));
    let origin = vec2f(id.xy) + 0.5;
    var sum = vec4f(0.0);
    var wsum = 0.0;
    for (var i = -n; i <= n; i++) {
        let k = exp(-f32(i * i) / (2.0 * sigma * sigma));
        let uv = (origin + dir * f32(i)) / size;
        sum += k * textureSampleLevel(src, smp, uv, 0.0);
        wsum += k;
    }
    gpufx_write(id, sum / wsum);
}
