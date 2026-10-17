// Record Scratch: light edge anti-aliasing after the lens pass.

fn luma(c: vec4f) -> f32 {
    return dot(c.rgb, vec3f(0.299, 0.587, 0.114));
}

fn at(q: vec2f) -> vec4f {
    return textureSampleLevel(lensed, smp, q, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let px = 1.0 / globals.size;
    let nw = luma(at(uv - px));
    let ne = luma(at(uv + vec2f(1.0, -1.0) * px));
    let sw = luma(at(uv + vec2f(-1.0, 1.0) * px));
    let se = luma(at(uv + px));
    // The reference reads its centre at uv * texel size (a corner pixel); kept as is.
    let mid = luma(at(uv * px));
    let top = nw + ne;
    var dir = vec2f(-(top - (sw + se)), (nw + sw) - (ne + se));
    let damp = 1.0 / (min(abs(dir.x), abs(dir.y)) + max((top + sw + se) * 0.03125, 0.0078125));
    dir = clamp(dir * damp, vec2f(-8.0), vec2f(8.0)) * px;
    let near = (at(uv - dir / 6.0) + at(uv + dir / 6.0)) * 0.5;
    let far = near * 0.5 + (at(uv - dir * 0.5) + at(uv + dir * 0.5)) * 0.25;
    let l = luma(near);
    let lo = min(mid, min(min(nw, ne), min(sw, se)));
    let hi = max(mid, max(max(nw, ne), max(sw, se)));
    gpufx_write(id, select(far, near, l < lo || l > hi));
}
