@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let bg = textureSampleLevel(base, smp, uv, 0.0);
    let osize = vec2f(textureDimensions(top));
    // Scale is relative to the frame width. The overlay keeps its aspect ratio unless a height is given.
    let w = params.scale * globals.size.x;
    let h = select(w * osize.y / osize.x, params.height * globals.size.y, params.height > 0.0);
    let size = vec2f(w, h);
    let px = vec2f(id.xy) + 0.5 - vec2f(params.x, params.y) * globals.size;
    let b = params.border;
    if (any(px < vec2f(-b)) || any(px > size + b)) {
        gpufx_write(id, bg);
        return;
    }
    var o = params.border_color;
    if (all(px >= vec2f(0.0)) && all(px <= size)) {
        o = textureSampleLevel(top, smp, px / size, 0.0);
    }
    let a = o.a * params.opacity;
    gpufx_write(id, vec4f(mix(bg.rgb, o.rgb, a), max(bg.a, a)));
}
