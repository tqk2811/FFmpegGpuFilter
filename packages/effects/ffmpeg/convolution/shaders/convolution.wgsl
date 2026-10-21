@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let m = array<f32, 9>(params.m0, params.m1, params.m2, params.m3, params.m4, params.m5, params.m6, params.m7, params.m8);
    var total = 0.0;
    var sum = vec3f(0.0);
    for (var j = 0; j < 9; j++) {
        let q = textureLoad(src, clamp(p + vec2i(j % 3 - 1, j / 3 - 1), vec2i(0), size - 1), 0);
        sum += m[j] * q.rgb;
        total += m[j];
    }
    if (total == 0.0) { total = 1.0; }
    let rdiv = select(params.rdiv, 1.0 / total, params.rdiv == 0.0);
    let a = textureLoad(src, p, 0).a;
    gpufx_write(id, vec4f(sum * rdiv + params.bias / 255.0, a));
}
