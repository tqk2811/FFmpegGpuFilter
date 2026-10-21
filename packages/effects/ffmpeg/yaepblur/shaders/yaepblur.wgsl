// Edge preserving blur (J. S. Lee, 1980): per channel, mean and variance over the (2r+1)^2 window,
// out = (sigma * mean + var * value) / (sigma + var), on 8-bit levels and integer mean / variance.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let c = textureLoad(src, p, 0);
    // FFmpeg limits the radius to half of the smaller side
    let radius = min(params.radius, (min(size.x, size.y) + 1) / 2);
    if (radius <= 0) {
        gpufx_write(id, c);
        return;
    }
    let lo = max(p - radius, vec2i(0));
    let hi = min(p + radius + 1, size);
    let count = (hi.x - lo.x) * (hi.y - lo.y);
    var sum = vec3i(0);
    var square_sum = vec3i(0);
    for (var y = lo.y; y < hi.y; y++) {
        for (var x = lo.x; x < hi.x; x++) {
            let v = vec3i(round(textureLoad(src, vec2i(x, y), 0).rgb * 255.0));
            sum += v;
            square_sum += v * v;
        }
    }
    let n = count;
    // sum * sum / n without overflowing i32: with sum = q * n + r this is sum * q + sum * r / n (exact floor).
    let q = sum / vec3i(n);
    let r = sum % vec3i(n);
    let mean = q;
    let sum_sq_over_n = sum * q + (sum * r) / vec3i(n);
    let variance = (square_sum - sum_sq_over_n) / vec3i(n);
    let sigma = params.sigma;
    let v0 = vec3i(round(c.rgb * 255.0));
    let res = (sigma * mean + variance * v0) / (sigma + variance);
    gpufx_write(id, vec4f(vec3f(res) / 255.0, c.a));
}
