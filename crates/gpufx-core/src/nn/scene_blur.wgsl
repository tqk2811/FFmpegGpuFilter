
// The five moments at (x, y), blurred along the channels (replicate padding).
fn moments(x: u32, y: u32, c: i32) -> array<f32, 5> {
    var m = array<f32, 5>(0.0, 0.0, 0.0, 0.0, 0.0);
    for (var k = 0; k < 11; k++) {
        let cc = u32(clamp(c + k - 5, 0, 2));
        let a = state.data[cc * PLANE + y * SMALL + x];
        let b = state.data[(3u + cc) * PLANE + y * SMALL + x];
        let g = gauss(k);
        m[0] += g * a;
        m[1] += g * b;
        m[2] += g * a * a;
        m[3] += g * b * b;
        m[4] += g * a * b;
    }
    return m;
}

@compute @workgroup_size(256)
fn main(@builtin(global_invocation_id) id: vec3u) {
    let i = id.x;
    if (i >= 3u * PLANE) {
        return;
    }
    let c = i / PLANE;
    let y = (i % PLANE) / SMALL;
    let x = i % SMALL;
    var s = array<f32, 5>(0.0, 0.0, 0.0, 0.0, 0.0);
    for (var k = 0; k < 11; k++) {
        let xx = u32(clamp(i32(x) + k - 5, 0, i32(SMALL) - 1));
        let m = moments(xx, y, i32(c));
        let g = gauss(k);
        for (var q = 0; q < 5; q++) {
            s[q] += g * m[q];
        }
    }
    for (var q = 0u; q < 5u; q++) {
        state.data[MOMENTS + (q * 3u + c) * PLANE + y * SMALL + x] = s[q];
    }
}
