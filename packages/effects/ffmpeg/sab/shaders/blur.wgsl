// Pass 2: shape adaptive blur. Each neighbour is weighted by a gaussian of its distance (luma_radius) and
// by a gaussian of the difference between the pre-filtered values (luma_strength, in 8-bit levels).
fn mirror(x0: i32, last: i32) -> i32 {
    var x = x0;
    for (var k = 0; k < 8; k++) {
        if (x >= 0 && x <= last) { break; }
        x = -x;
        if (x < 0) { x += 2 * last; }
    }
    return clamp(x, 0, max(last, 0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let r = params.luma_radius;
    let half_len = ((i32(r * 3.0 + 0.5)) | 1) / 2;
    // the colour-difference gaussian has (int)(strength * 5 + 0.5) | 1 taps: larger differences weigh 0
    let s = params.luma_strength;
    let max_diff = f32(((i32(s * 5.0 + 0.5)) | 1) / 2);
    let pre_val = round(textureLoad(tmp, p, 0).rgb * 255.0);
    var sum = vec3f(0.0);
    var div = vec3f(0.0);
    for (var j = -half_len; j <= half_len; j++) {
        let iy = mirror(p.y + j, size.y - 1);
        for (var i = -half_len; i <= half_len; i++) {
            let ix = mirror(p.x + i, size.x - 1);
            let q = vec2i(ix, iy);
            let d = pre_val - round(textureLoad(tmp, q, 0).rgb * 255.0);
            let cw = select(vec3f(0.0), exp(-d * d / (2.0 * s * s)), abs(d) <= vec3f(max_diff));
            let f = cw * exp(-f32(i * i + j * j) / (2.0 * r * r));
            sum += round(textureLoad(src, q, 0).rgb * 255.0) * f;
            div += f;
        }
    }
    let res = select(pre_val, round(sum / max(div, vec3f(1.0e-9))), div > vec3f(0.0));
    gpufx_write(id, vec4f(res / 255.0, textureLoad(src, p, 0).a));
}
