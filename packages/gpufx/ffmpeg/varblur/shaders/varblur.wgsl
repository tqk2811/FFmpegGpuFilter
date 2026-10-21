// Box blur whose radius comes from a map (second input), per channel, like FFmpeg's varblur.
// The box of a pixel with radius R is [x - l, x + r) x [y - t, y + b) with l = min(R, x),
// r = min(R, w - x - 1)...; its average is blended with the one of radius R + 1 by the fraction of R.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let c = textureLoad(src, p, 0);
    let value = round(c.rgb * 255.0);
    let min_r = min(params.min_r, params.max_r - 1);
    let minr = 2.0 * f32(min_r) + 1.0;
    let maxr = 2.0 * f32(max(params.max_r, min_r + 1)) + 1.0;
    let scaler = (maxr - minr) / 255.0;
    let map = round(textureLoad(radius, p, 0).rgb * 255.0);
    let radiusf = minr + max(vec3f(0.0), 2.0 * map + 1.0 - minr) * scaler;
    let rad = vec3i(floor(radiusf));
    let factor = radiusf - floor(radiusf);
    var res = value;
    for (var k = 0; k < 3; k++) {
        let r0 = rad[k];
        let r1 = r0 + 1;
        let l0 = min(r0, p.x);
        let rr0 = min(r0, size.x - p.x - 1);
        let t0 = min(r0, p.y);
        let b0 = min(r0, size.y - p.y - 1);
        let l1 = min(r1, p.x);
        let rr1 = min(r1, size.x - p.x - 1);
        let t1 = min(r1, p.y);
        let b1 = min(r1, size.y - p.y - 1);
        var sum0 = 0.0;
        var sum1 = 0.0;
        for (var y = p.y - t1; y < p.y + b1; y++) {
            for (var x = p.x - l1; x < p.x + rr1; x++) {
                let v = round(textureLoad(src, vec2i(x, y), 0)[k] * 255.0);
                sum1 += v;
                if (x >= p.x - l0 && x < p.x + rr0 && y >= p.y - t0 && y < p.y + b0) {
                    sum0 += v;
                }
            }
        }
        let div0 = f32((l0 + rr0) * (t0 + b0));
        let div1 = f32((l1 + rr1) * (t1 + b1));
        var p0 = value[k];
        var n0 = value[k];
        if (div0 > 0.0) { p0 = floor(sum0 / div0); }
        if (div1 > 0.0) { n0 = floor(sum1 / div1); }
        res[k] = round(mix(p0, n0, factor[k]));
    }
    gpufx_write(id, vec4f(res / 255.0, c.a));
}
