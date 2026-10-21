// Bindings (globals, params, src, smp, out_tex) and gpufx_* helpers come from the prelude.
// Pass 2: draw the res x res density table of pass 1 (in `tmp`, entry e at texel (e % width, e / width)) as a square
// scope centred in the picture, Cb to the right, Cr up, with an optional graticule (crosshair and a circle).
fn density(res: i32, cell: vec2i) -> f32 {
    let w = i32(globals.size.x);
    let c = clamp(cell, vec2i(0), vec2i(res - 1));
    let e = c.y * res + c.x;
    let t = textureLoad(tmp, vec2i(e % w, e / w), 0);
    return (round(t.r * 255.0) * 256.0 + round(t.g * 255.0)) / 65535.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let base = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let size = globals.size;
    let res = clamp(i32(sqrt(size.x * size.y)), 2, 256);
    let side = min(size.x, size.y);
    let origin = (size - vec2f(side)) * 0.5;
    let q = (vec2f(id.xy) + 0.5 - origin) / side;     // 0..1 inside the square
    var rgb = vec3f(0.0);
    if (q.x >= 0.0 && q.x < 1.0 && q.y >= 0.0 && q.y < 1.0) {
        let pos = vec2f(q.x, 1.0 - q.y);               // Cb, Cr in 0..1
        let d = density(res, vec2i(floor(pos * f32(res))));
        var tint = vec3f(1.0);
        if (params.color_mode == 1u) {
            // colour of the chroma at this place, at a fixed luma
            let cb = pos.x - 0.5;
            let cr = pos.y - 0.5;
            let y = 0.7;
            tint = clamp(vec3f(y + 1.5748 * cr, y - 0.187324 * cb - 0.468124 * cr, y + 1.8556 * cb), vec3f(0.0), vec3f(1.0));
        }
        rgb = tint * d;
        if (params.graticule == 1u) {
            let px = 1.0 / side;
            let c = q - vec2f(0.5);
            let on_cross = abs(c.x) < px * 0.75 || abs(c.y) < px * 0.75;
            let on_ring = abs(length(c) - 0.5) < px * 1.0;
            if (on_cross || on_ring) { rgb = max(rgb, vec3f(0.25)); }
        }
    }
    gpufx_write(id, vec4f(mix(base.rgb, rgb, params.opacity), mix(base.a, 1.0, params.opacity)));
}
