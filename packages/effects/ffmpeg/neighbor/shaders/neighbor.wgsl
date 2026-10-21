// Erosion, dilation, deflate and inflate over the 3x3 neighbourhood, per channel on 8-bit levels,
// like FFmpeg's vf_neighbor.c. Columns beyond the picture mirror (-1 -> 1, w -> w - 2) and rows repeat.
fn fetch(p: vec2i, size: vec2i) -> vec3i {
    var q = p;
    if (q.x < 0) { q.x = select(0, 1, size.x > 1); }
    if (q.x >= size.x) { q.x = max(size.x - 2, 0); }
    q.y = clamp(q.y, 0, size.y - 1);
    return vec3i(round(textureLoad(src, q, 0).rgb * 255.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let centre = textureLoad(src, p, 0);
    let v = vec3i(round(centre.rgb * 255.0));
    let threshold = params.threshold;
    if (threshold <= 0) {
        gpufx_write(id, centre);
        return;
    }
    var nb: array<vec3i, 8>;
    for (var j = 0; j < 8; j++) {
        // 0..3 -> top-left, top, top-right, left; 4..7 -> right, bottom-left, bottom, bottom-right
        let k = select(j, j + 1, j >= 4);
        nb[j] = fetch(p + vec2i(k % 3 - 1, k / 3 - 1), size);
    }
    var res = v;
    if (params.mode == 0) {
        // erosion
        let limit = max(v - threshold, vec3i(0));
        var m = v;
        for (var i = 0; i < 8; i++) {
            if ((params.coordinates & (1 << u32(i))) != 0) {
                m = min(m, nb[i]);
            }
            m = max(m, limit);
        }
        res = m;
    } else if (params.mode == 1) {
        // dilation
        let limit = min(v + threshold, vec3i(255));
        var m = v;
        for (var i = 0; i < 8; i++) {
            if ((params.coordinates & (1 << u32(i))) != 0) {
                m = max(m, nb[i]);
            }
            m = min(m, limit);
        }
        res = m;
    } else {
        var sum = vec3i(0);
        for (var i = 0; i < 8; i++) {
            sum += nb[i];
        }
        let avg = sum / 8;
        if (params.mode == 2) {
            // deflate
            res = max(min(avg, v), max(v - threshold, vec3i(0)));
        } else {
            // inflate
            res = min(max(avg, v), min(v + threshold, vec3i(255)));
        }
    }
    gpufx_write(id, vec4f(vec3f(res) / 255.0, centre.a));
}
