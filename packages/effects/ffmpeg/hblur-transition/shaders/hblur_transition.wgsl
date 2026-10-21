@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = params.progress;
    let width = i32(globals.size.x);
    let k = select((1.0 - p) * 2.0, p * 2.0, p <= 0.5);
    let size = 1 + i32(f32(width / 2) * k);
    let x0 = i32(id.x);
    let x1 = min(x0 + size, width);
    var sum_a = vec4f(0.0);
    var sum_b = vec4f(0.0);
    for (var x = x0; x < x1; x = x + 1) {
        sum_a += textureLoad(first, vec2i(x, i32(id.y)), 0);
        sum_b += textureLoad(second, vec2i(x, i32(id.y)), 0);
    }
    let cnt = f32(x1 - x0);
    gpufx_write(id, mix(sum_b / cnt, sum_a / cnt, 1.0 - p));
}
