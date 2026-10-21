// BT.709 full-range Cb/Cr, centered on 0.
fn cb_of(c: vec3f) -> f32 { return (c.b - dot(c, vec3f(0.2126, 0.7152, 0.0722))) / 1.8556; }
fn cr_of(c: vec3f) -> f32 { return (c.r - dot(c, vec3f(0.2126, 0.7152, 0.0722))) / 1.5748; }

fn shifted(p: vec2i, d: vec2i, n: vec2i) -> vec2i {
    let q = p - d;
    if (params.edge == 1) {
        return vec2i(((q.x % n.x) + n.x) % n.x, ((q.y % n.y) + n.y) % n.y);
    }
    return clamp(q, vec2i(0), n - vec2i(1));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let n = vec2i(globals.size);
    let p = vec2i(id.xy);
    let c = textureLoad(src, p, 0);
    let y = dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722));
    let cb = cb_of(textureLoad(src, shifted(p, vec2i(params.cbh, params.cbv), n), 0).rgb);
    let cr = cr_of(textureLoad(src, shifted(p, vec2i(params.crh, params.crv), n), 0).rgb);
    let r = y + 1.5748 * cr;
    let b = y + 1.8556 * cb;
    let g = (y - 0.2126 * r - 0.0722 * b) / 0.7152;
    gpufx_write(id, vec4f(r, g, b, c.a));
}
