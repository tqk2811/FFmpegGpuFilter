
var<workgroup> part: array<f32, 256>;

@compute @workgroup_size(256)
fn main(@builtin(local_invocation_index) li: u32) {
    let c1 = 0.01 * 0.01;
    let c2 = 0.03 * 0.03;
    var acc = 0.0;
    for (var i = li; i < 3u * PLANE; i += 256u) {
        let c = i / PLANE;
        let y = (i % PLANE) / SMALL;
        let x = i % SMALL;
        var s = array<f32, 5>(0.0, 0.0, 0.0, 0.0, 0.0);
        for (var k = 0; k < 11; k++) {
            let yy = u32(clamp(i32(y) + k - 5, 0, i32(SMALL) - 1));
            let g = gauss(k);
            for (var q = 0u; q < 5u; q++) {
                s[q] += g * state.data[MOMENTS + (q * 3u + c) * PLANE + yy * SMALL + x];
            }
        }
        let mu1 = s[0];
        let mu2 = s[1];
        let v1 = 2.0 * (s[4] - mu1 * mu2) + c2;
        let v2 = (s[2] - mu1 * mu1) + (s[3] - mu2 * mu2) + c2;
        acc += ((2.0 * mu1 * mu2 + c1) * v1) / ((mu1 * mu1 + mu2 * mu2 + c1) * v2);
    }
    part[li] = acc;
    workgroupBarrier();
    for (var n = 128u; n > 0u; n >>= 1u) {
        if (li < n) {
            part[li] += part[li + n];
        }
        workgroupBarrier();
    }
    if (li == 0u) {
        let ssim = part[0] / f32(3u * PLANE);
        state.ssim = ssim;
        state.cut = select(0u, 1u, ssim < p.threshold);
    }
}
