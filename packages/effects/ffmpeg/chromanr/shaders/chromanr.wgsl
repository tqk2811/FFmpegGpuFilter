fn gpufx_rgb_to_yuv(c: vec3f) -> vec3f {
    // BT.709 full range, U and V centered on 0.5
    let y = dot(c, vec3f(0.2126, 0.7152, 0.0722));
    return vec3f(y, (c.b - y) / 1.8556 + 0.5, (c.r - y) / 1.5748 + 0.5);
}
fn gpufx_yuv_to_rgb(c: vec3f) -> vec3f {
    let u = c.y - 0.5;
    let v = c.z - 0.5;
    return vec3f(c.x + 1.5748 * v, c.x - 0.18732 * u - 0.46812 * v, c.x + 1.8556 * u);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let c = textureLoad(src, p, 0);
    let cyuv = gpufx_rgb_to_yuv(c.rgb);
    var su = cyuv.y;
    var sv = cyuv.z;
    var cn = 1.0;
    let x0 = max(0, p.x - params.sizew);
    let x1 = min(size.x - 1, p.x + params.sizew);
    let y0 = max(0, p.y - params.sizeh);
    let y1 = min(size.y - 1, p.y + params.sizeh);
    for (var yy = y0; yy <= y1; yy += params.steph) {
        for (var xx = x0; xx <= x1; xx += params.stepw) {
            let n = gpufx_rgb_to_yuv(textureLoad(src, vec2i(xx, yy), 0).rgb);
            // differences on the 0..255 scale, like FFmpeg
            let d = abs(cyuv - n) * 255.0;
            var dist = d.x + d.y + d.z;
            if (params.distance == 1) { dist = length(d); }
            if (dist < params.thres && d.y < params.threu && d.z < params.threv && d.x < params.threy) {
                su += n.y;
                sv += n.z;
                cn += 1.0;
            }
        }
    }
    gpufx_write(id, vec4f(gpufx_yuv_to_rgb(vec3f(cyuv.x, su / cn, sv / cn)), c.a));
}
