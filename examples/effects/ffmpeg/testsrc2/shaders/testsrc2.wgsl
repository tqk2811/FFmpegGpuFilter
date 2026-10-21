// Bindings (globals, params, src, smp, out_tex) and gpufx_* helpers come from the prelude.
// Port of FFmpeg's testsrc2 without the text box: coloured background, oblique gradient strip,
// clock hands, beating rectangles, a noise checker and a bouncing square.

fn color_gradient(index: i32) -> vec3f {
    let si = f32(index & 255);
    let sd = 255.0 - si;
    let k = index >> 8;
    if (k == 0) { return vec3f(255.0, si, 0.0) / 255.0; }
    if (k == 1) { return vec3f(sd, 255.0, 0.0) / 255.0; }
    if (k == 2) { return vec3f(0.0, 255.0, si) / 255.0; }
    if (k == 3) { return vec3f(0.0, sd, 255.0) / 255.0; }
    if (k == 4) { return vec3f(si, 0.0, 255.0) / 255.0; }
    return vec3f(255.0, 0.0, sd) / 255.0;
}

fn hash(a: u32) -> u32 {
    var h = a * 747796405u + 2891336453u;
    h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
    return (h >> 22u) ^ h;
}

fn in_box(x: i32, y: i32, x0: i32, y0: i32, x1: i32, y1: i32) -> bool {
    return x >= x0 && x < x1 && y >= y0 && y < y1;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let base = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let W = i32(globals.size.x);
    let H = i32(globals.size.y);
    let x = i32(id.x);
    let y = i32(id.y);
    let t = f32(globals.time_int) + globals.time_frac;
    let t_floor = f32(globals.time_int);
    let sec = globals.time_int;
    let pts = u32(max(i32(floor(t * params.rate)), 0));

    // coloured background: six vertical bands
    let band = min((x * 6) / W, 5) + 1;
    var rgb = vec3f(f32(band & 1), f32((band >> 1) & 1), f32((band >> 2) & 1));

    // oblique gradient strip, 16 rows tall, bouncing
    if (H >= 64) {
        let g0 = i32(floor(t * 128.0));
        let g = ((x * 6 * 256) / W + g0) % (6 * 256);
        let hh = H - 16;
        var gy = i32(floor(t * f32(hh) * 0.5)) + (x * (H / 2)) / W;
        gy = gy % (2 * hh);
        if (gy > hh) { gy = 2 * hh - gy; }
        if (y >= gy && y < gy + 16) { rgb = color_gradient(g); }
    }

    if (W >= 64 && H >= 64) {
        // top right: clock hands
        let l = (min(W, H) - 32) >> 1;
        let steps = clamp(l >> 5, 4, 64);
        let xc = (W >> 2) + (W >> 1);
        let yc = H >> 2;
        let cycle = l << 2;
        for (var c = 0; c < 3; c++) {
            let rate = f32(64 >> u32(c * 2));
            let pos = i32(floor(t * f32(cycle) / rate)) % cycle;
            var xh = 0;
            var yh = 0;
            if (pos < l) { xh = pos; yh = 0; }
            else if (pos < 2 * l) { xh = l; yh = pos - l; }
            else if (pos < 3 * l) { xh = 3 * l - pos; yh = l; }
            else { xh = 0; yh = cycle - pos; }
            xh -= l >> 1;
            yh -= l >> 1;
            var col = vec3f(0.0);
            if (c == 0) { col = vec3f(0xBB, 0xBB, 0x44) / 255.0; }
            else if (c == 1) { col = vec3f(0xBB, 0x44, 0xBB) / 255.0; }
            else { col = vec3f(0x44, 0xBB, 0xBB) / 255.0; }
            for (var i = 1; i <= steps; i++) {
                let px = (xh * i) / steps + xc;
                let py = (yh * i) / steps + yc;
                if (in_box(x, y, px, py, px + 8, py + 8)) { rgb = col; }
            }
        }

        // bottom left: beating rectangles
        let l2 = (min(W, H) - 16) >> 2;
        let cycle2 = l2 << 3;
        let bx = W >> 2;
        let by = (H >> 2) + (H >> 1);
        var size = i32(floor(t * f32(cycle2) / 4.0));
        var stp = size / l2;
        size = size % l2;
        if ((stp & 1) != 0) { size = l2 - size; }
        stp = (stp >> 1) & 3;
        let x1 = bx - 4 - size;
        let x2 = bx + 4 + size;
        let y1 = by - 4 - size;
        let y2 = by + 4 + size;
        var hit = false;
        if (stp == 0 || stp == 2) { hit = hit || in_box(x, y, x1, by - 8, x2, by + 8); }
        if (stp == 1 || stp == 2) { hit = hit || in_box(x, y, bx - 8, y1, bx + 8, y2); }
        if (stp == 3) { hit = hit || in_box(x, y, x1, y1, x2, y2); }
        if (hit) { rgb = vec3f(0.5019608); }
    }

    // bottom right: checker of 16x16 noise blocks
    let xmin = (5 * W) / 8;
    let xmax = (7 * W) / 8;
    let ymin = (5 * H) / 8;
    let ymax = (7 * H) / 8;
    if (x >= xmin && y >= ymin) {
        let cx = (x - xmin) / 16;
        let cy = (y - ymin) / 16;
        let bx0 = xmin + cx * 16;
        let by0 = ymin + cy * 16;
        if (bx0 + 15 < xmax && by0 + 15 < ymax && ((bx0 ^ by0) & 16) == 0) {
            let n = hash(pts * 65599u + u32(y * W + x));
            let a = f32(n & 255u) / 255.0;
            rgb = mix(rgb, vec3f(0.0, 1.0, 0.5019608), a);
        }
    }

    // bouncing square
    if (W >= 16 && H >= 16) {
        let bw = W - 8;
        let bh = H - 8;
        var sx = i32(floor(t * 55.0 * f32(bw) / 233.0)) % (bw * 2);
        var sy = i32(floor(t * 89.0 * f32(bh) / 233.0)) % (bh * 2);
        if (sx > bw) { sx = bw * 2 - sx; }
        if (sy > bh) { sy = bh * 2 - sy; }
        if (in_box(x, y, sx, sy, sx + 8, sy + 8)) { rgb = vec3f(0.5019608, 0.0, 1.0); }
    }

    let a = params.opacity;
    gpufx_write(id, vec4f(mix(base.rgb, rgb, a), mix(base.a, 1.0, a)));
}
