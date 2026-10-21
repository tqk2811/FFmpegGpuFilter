// Bindings (globals, params, src, smp, out_tex) and gpufx_* helpers come from the prelude.
// Port of FFmpeg's testsrc: eight colour bars with a circle, a sliding colour gradient and a 7-segment clock.

fn grad_color(g: i32) -> vec3f {
    var r = 0;
    var gr = 0;
    var b = 0;
    if (g < 256 || g >= 5 * 256) { r = 255; }
    else if (g >= 2 * 256 && g < 4 * 256) { r = 0; }
    else if (g < 2 * 256) { r = 2 * 256 - 1 - g; }
    else { r = g - 4 * 256; }
    if (g >= 4 * 256) { gr = 0; }
    else if (g >= 256 && g < 3 * 256) { gr = 255; }
    else if (g < 256) { gr = g; }
    else { gr = 4 * 256 - 1 - g; }
    if (g < 2 * 256) { b = 0; }
    else if (g >= 3 * 256 && g < 5 * 256) { b = 255; }
    else if (g < 3 * 256) { b = g - 2 * 256; }
    else { b = 6 * 256 - 1 - g; }
    return vec3f(f32(r), f32(gr), f32(b)) / 255.0;
}

fn in_rect(lx: i32, ly: i32, r: vec4i) -> bool {
    return lx >= r.x && lx < r.x + r.z && ly >= r.y && ly < r.y + r.w;
}

// lx 0..7, ly 0..12 inside a digit cell, in segment units.
fn digit_on(d: u32, lx: i32, ly: i32) -> bool {
    // bits: 1 top, 2 middle, 4 bottom, 8 left-top, 16 left-bottom, 32 right-top, 64 right-bottom
    var masks = array<u32, 10>(125u, 96u, 55u, 103u, 106u, 79u, 95u, 97u, 127u, 111u);
    var segs = array<vec4i, 7>(
        vec4i(1, 0, 5, 1), vec4i(1, 6, 5, 1), vec4i(1, 12, 5, 1),
        vec4i(0, 1, 1, 5), vec4i(0, 7, 1, 5), vec4i(6, 1, 1, 5), vec4i(6, 7, 1, 5));
    let m = masks[d % 10u];
    for (var i = 0u; i < 7u; i++) {
        if ((m & (1u << i)) != 0u && in_rect(lx, ly, segs[i])) { return true; }
    }
    return false;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let base = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let W = i32(globals.size.x);
    let H = i32(globals.size.y);
    let x = i32(id.x);
    let y = i32(id.y);

    // colour bars and circle
    let dx = f32(x) - f32(W) * 0.5;
    let dy = f32(y) - f32(H) * 0.5;
    let radius = f32((W + H) / 4);
    var icol = (x * 8) / W;
    if (dx * dx + dy * dy - radius * radius < 0.0) { icol = icol ^ 7; }
    var rgb = vec3f(f32(icol & 1), f32((icol >> 1) & 1), f32((icol >> 2) & 1));

    // sliding colour line, repeated over H/8 rows
    let y0 = (H * 3) / 4;
    if (y >= y0 && y <= y0 + H / 8) {
        let t = f32(globals.time_int) + globals.time_frac;
        let start = i32(floor(256.0 * t)) % 1536;
        let g = (start + (x * 1536) / W + 1536) % 1536;
        rgb = grad_color(g);
    }

    // clock digits
    let seg = W / 80;
    if (seg >= 1 && H >= 13 * seg) {
        let dec = clamp(params.decimals, 0, 6);
        var p10 = 1u;
        for (var k = 0; k < dec; k++) { p10 = p10 * 10u; }
        let ti = u32(max(globals.time_int, 0));
        let value = ti * p10 + u32(globals.time_frac * f32(p10));
        let xr = W - (W - seg * 64) / 2;
        let yt = (H - seg * 13) / 2;
        if (x < xr && x >= xr - 64 * seg && y >= yt && y < yt + 13 * seg) {
            let cell = (xr - 1 - x) / (8 * seg);
            var div = 1u;
            for (var k = 0; k < cell; k++) { div = div * 10u; }
            if (cell == 0 || value / div > 0u) {
                let lx = (x - (xr - 8 * seg * (cell + 1))) / seg;
                let ly = (y - yt) / seg;
                rgb = vec3f(select(0.0, 1.0, digit_on((value / div) % 10u, lx, ly)));
            }
        }
    }
    gpufx_write(id, vec4f(mix(base.rgb, rgb, params.opacity), mix(base.a, 1.0, params.opacity)));
}
