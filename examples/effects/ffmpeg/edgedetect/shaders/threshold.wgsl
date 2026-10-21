// Pass 3: double threshold (keep strong pixels, and weak ones that touch a strong one), then the
// output mode: 0 = wires (gray edges), 1 = colormix ((edge + source) / 2), 2 = canny (edges per channel).
fn ld(p: vec2i) -> vec3i {
    return vec3i(round(textureLoad(tmp2, p, 0).rgb * 255.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(tmp2));
    let p = vec2i(id.xy);
    let hi = i32(floor(params.high * 255.0 + 0.5));
    let lo = i32(floor(params.low * 255.0 + 0.5));
    let v = ld(p);
    let inner = p.x > 0 && p.y > 0 && p.x < size.x - 1 && p.y < size.y - 1;
    var near = vec3i(0);
    if (inner) {
        for (var j = -1; j <= 1; j++) {
            for (var i = -1; i <= 1; i++) {
                if (i != 0 || j != 0) {
                    near = max(near, ld(p + vec2i(i, j)));
                }
            }
        }
    }
    var e = vec3i(0);
    for (var k = 0; k < 3; k++) {
        if (v[k] > hi || (inner && v[k] > lo && near[k] > hi)) {
            e[k] = v[k];
        }
    }
    let s = textureLoad(src, p, 0);
    var res = vec3f(e) / 255.0;
    if (params.mode == 1) {
        res = floor((vec3f(e) + round(s.rgb * 255.0)) * 0.5) / 255.0;
    }
    gpufx_write(id, vec4f(res, s.a));
}
