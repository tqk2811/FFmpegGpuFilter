// Bindings (globals, params, src, smp, out_tex) and gpufx_* helpers come from the prelude.
// Pass 1: the histogram table. The table has 4 components (0 red, 1 green, 2 blue, 3 luma) of `bins` bins each
// (256, fewer only for a picture under 1024 pixels) and is stored one texel per entry in reading order of the
// texture: entry e sits at texel (e % width, e / width). A 16-bit height is kept in the red (high byte) and green
// (low byte) channels. Each entry walks a grid of samples x samples input pixels, so the cost does not depend on
// the picture size.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(globals.size);
    let bins = clamp((size.x * size.y) / 4, 1, 256);
    let e = i32(id.y) * size.x + i32(id.x);
    if (e >= bins * 4) {
        gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0));
        return;
    }
    let bin = e % bins;
    let ch = e / bins;
    let s = clamp(params.samples, 8, 256);
    var count = 0.0;
    for (var j = 0; j < s; j++) {
        let py = min(((2 * j + 1) * size.y) / (2 * s), size.y - 1);
        for (var i = 0; i < s; i++) {
            let px = min(((2 * i + 1) * size.x) / (2 * s), size.x - 1);
            let c = textureLoad(src, vec2i(px, py), 0);
            var v = c.r;
            if (ch == 1) { v = c.g; }
            else if (ch == 2) { v = c.b; }
            else if (ch == 3) { v = dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722)); }
            if (min(i32(clamp(v, 0.0, 1.0) * f32(bins)), bins - 1) == bin) { count += 1.0; }
        }
    }
    // 1 = a bin as full as all bins would be if the picture were spread evenly
    let rel = count / f32(s * s) * f32(bins);
    var h = 0.0;
    if (params.log_scale == 1u) {
        h = log2(1.0 + rel * params.gain) / 8.0;
    } else {
        h = rel * params.gain * 0.1;
    }
    let q = u32(clamp(h, 0.0, 1.0) * 65535.0 + 0.5);
    gpufx_write(id, vec4f(f32(q >> 8u) / 255.0, f32(q & 255u) / 255.0, 0.0, 1.0));
}
