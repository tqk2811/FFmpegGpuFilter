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
    let r = textureLoad(src, shifted(p, vec2i(params.rh, params.rv), n), 0).r;
    let g = textureLoad(src, shifted(p, vec2i(params.gh, params.gv), n), 0).g;
    let b = textureLoad(src, shifted(p, vec2i(params.bh, params.bv), n), 0).b;
    let a = textureLoad(src, shifted(p, vec2i(params.ah, params.av), n), 0).a;
    gpufx_write(id, vec4f(r, g, b, a));
}
