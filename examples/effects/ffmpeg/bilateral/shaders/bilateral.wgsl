@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let c = textureLoad(src, p, 0);
    let lc = dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722));
    let ss = max(params.sigmaS, 0.01);
    let sr = max(params.sigmaR, 0.0001);
    let r = min(i32(ceil(2.0 * ss)), 16);
    var sum = vec4f(0.0);
    var wsum = 0.0;
    for (var y = -r; y <= r; y++) {
        for (var x = -r; x <= r; x++) {
            let q = textureLoad(src, clamp(p + vec2i(x, y), vec2i(0), size - 1), 0);
            let d = dot(q.rgb, vec3f(0.2126, 0.7152, 0.0722)) - lc;
            let k = exp(-f32(x * x + y * y) / (2.0 * ss * ss) - d * d / (2.0 * sr * sr));
            sum += k * q;
            wsum += k;
        }
    }
    gpufx_write(id, sum / wsum);
}
