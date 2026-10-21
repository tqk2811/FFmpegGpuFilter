@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let rx = params.radius;
    let ry = select(params.radius_v, params.radius, params.radius_v < 0);
    var win: array<vec4f, 121>;
    var n = 0;
    for (var y = -ry; y <= ry; y++) {
        for (var x = -rx; x <= rx; x++) {
            win[n] = textureLoad(src, clamp(p + vec2i(x, y), vec2i(0), size - 1), 0);
            n++;
        }
    }
    // rank-th smallest value per channel: bisect the value, then snap to the largest sample below it
    let rank = clamp(i32(floor(params.percentile * f32(n))), 0, n - 1);
    var res = vec4f(0.0);
    for (var ch = 0; ch < 4; ch++) {
        var lo = 0.0;
        var hi = 1.0;
        for (var it = 0; it < 12; it++) {
            let mid = 0.5 * (lo + hi);
            var cnt = 0;
            for (var j = 0; j < n; j++) {
                if (win[j][ch] <= mid) { cnt++; }
            }
            if (cnt > rank) { hi = mid; } else { lo = mid; }
        }
        var best = 0.0;
        for (var j = 0; j < n; j++) {
            if (win[j][ch] <= hi) { best = max(best, win[j][ch]); }
        }
        res[ch] = best;
    }
    gpufx_write(id, res);
}
