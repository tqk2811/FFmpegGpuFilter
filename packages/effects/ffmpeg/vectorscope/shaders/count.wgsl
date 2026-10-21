// Bindings (globals, params, src, smp, out_tex) and gpufx_* helpers come from the prelude.
// Pass 1: the density of chroma on a grid of res x res cells (res = 256, fewer only for a picture under 65536 pixels).
// Entry e = cy * res + cx sits at texel (e % width, e / width) and holds how many sampled input pixels have
// Cb in cell cx and Cr in cell cy (BT.709), as a 16-bit brightness in the red (high byte) and green (low byte) channels.
// A scatter ("add 1 at the place of each pixel") is a gather here: each cell walks a grid of
// samples x samples input pixels, so the cost does not depend on the picture size.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(globals.size);
    let res = clamp(i32(sqrt(f32(size.x * size.y))), 2, 256);
    let e = i32(id.y) * size.x + i32(id.x);
    if (e >= res * res) {
        gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0));
        return;
    }
    let cell = vec2i(e % res, e / res);
    let s = clamp(params.samples, 8, 256);
    var count = 0.0;
    for (var j = 0; j < s; j++) {
        let py = min(((2 * j + 1) * size.y) / (2 * s), size.y - 1);
        for (var i = 0; i < s; i++) {
            let px = min(((2 * i + 1) * size.x) / (2 * s), size.x - 1);
            let c = textureLoad(src, vec2i(px, py), 0).rgb;
            let y = dot(c, vec3f(0.2126, 0.7152, 0.0722));
            let cb = clamp((c.b - y) / 1.8556 + 0.5, 0.0, 1.0);
            let cr = clamp((c.r - y) / 1.5748 + 0.5, 0.0, 1.0);
            if (min(i32(cb * f32(res)), res - 1) == cell.x && min(i32(cr * f32(res)), res - 1) == cell.y) { count += 1.0; }
        }
    }
    // Estimated number of input pixels in this cell; FFmpeg adds `intensity` (of 255) per pixel.
    // With res < 256 a cell is (256 / res)^2 times the area of a 256-grid cell: scale back to one 256-grid cell.
    let wide = 256.0 / f32(res);
    let hits = count * f32(size.x * size.y) / f32(s * s) / (wide * wide);
    let h = clamp(hits * params.intensity, 0.0, 1.0);
    let q = u32(h * 65535.0 + 0.5);
    gpufx_write(id, vec4f(f32(q >> 8u) / 255.0, f32(q & 255u) / 255.0, 0.0, 1.0));
}
