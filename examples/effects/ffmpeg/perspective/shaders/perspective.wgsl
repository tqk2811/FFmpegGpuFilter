fn cubic_weight(d: f32) -> f32 {
    let a = -0.60;
    let x = abs(d);
    if (x < 1.0) {
        return 1.0 - (a + 3.0) * x * x + (a + 2.0) * x * x * x;
    } else if (x < 2.0) {
        return -4.0 * a + 8.0 * a * x - 5.0 * a * x * x + a * x * x * x;
    }
    return 0.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = globals.size;
    let w = size.x;
    let h = size.y;
    // FFmpeg's ref[0..3]: top left, top right, bottom left, bottom right (in pixels).
    let r0 = params.top_left * size;
    let r1 = params.top_right * size;
    let r2 = params.bottom_left * size;
    let r3 = params.bottom_right * size;

    var x0: f32; var x1: f32; var x2: f32;
    var x3: f32; var x4: f32; var x5: f32;
    var x6: f32; var x7: f32; var x8: f32;
    if (params.sense == 0) {
        // source: the given points of the source go to the corners of the output
        x6 = ((r0.x - r1.x - r2.x + r3.x) * (r2.y - r3.y) - (r0.y - r1.y - r2.y + r3.y) * (r2.x - r3.x)) * h;
        x7 = ((r0.y - r1.y - r2.y + r3.y) * (r1.x - r3.x) - (r0.x - r1.x - r2.x + r3.x) * (r1.y - r3.y)) * w;
        let q = (r1.x - r3.x) * (r2.y - r3.y) - (r2.x - r3.x) * (r1.y - r3.y);
        x0 = q * (r1.x - r0.x) * h + x6 * r1.x;
        x1 = q * (r2.x - r0.x) * w + x7 * r2.x;
        x2 = q * r0.x * w * h;
        x3 = q * (r1.y - r0.y) * h + x6 * r1.y;
        x4 = q * (r2.y - r0.y) * w + x7 * r2.y;
        x5 = q * r0.y * w * h;
        x8 = q * w * h;
    } else {
        // destination: the corners of the source go to the given points of the output
        let t0 = r0.x * (r3.y - r1.y) + r1.x * (r0.y - r3.y) + r3.x * (r1.y - r0.y);
        let t1 = r1.x * (r2.y - r3.y) + r2.x * (r3.y - r1.y) + r3.x * (r1.y - r2.y);
        let t2 = r0.x * (r3.y - r2.y) + r2.x * (r0.y - r3.y) + r3.x * (r2.y - r0.y);
        let t3 = r0.x * (r1.y - r2.y) + r1.x * (r2.y - r0.y) + r2.x * (r0.y - r1.y);
        x0 = t0 * t1 * w * (r2.y - r0.y);
        x1 = t0 * t1 * w * (r0.x - r2.x);
        x2 = t0 * t1 * w * (r0.y * r2.x - r0.x * r2.y);
        x3 = t1 * t2 * h * (r1.y - r0.y);
        x4 = t1 * t2 * h * (r0.x - r1.x);
        x5 = t1 * t2 * h * (r0.y * r1.x - r0.x * r1.y);
        x6 = t1 * t2 * (r1.y - r0.y) + t0 * t3 * (r2.y - r3.y);
        x7 = t1 * t2 * (r0.x - r1.x) + t0 * t3 * (r3.x - r2.x);
        x8 = t1 * t2 * (r0.y * r1.x - r0.x * r1.y) + t0 * t3 * (r2.x * r3.y - r2.y * r3.x);
    }

    let p = vec2f(id.xy);
    let den = x6 * p.x + x7 * p.y + x8;
    let s = vec2f(x0 * p.x + x1 * p.y + x2, x3 * p.x + x4 * p.y + x5) / den;

    if (params.interpolation == 0) {
        // linear; the sampler repeats the edge pixels like FFmpeg does
        gpufx_write(id, textureSampleLevel(src, smp, (s + 0.5) / size, 0.0));
        return;
    }
    // cubic: 4x4 taps around the source position, edge pixels repeated
    let base = floor(s);
    let f = s - base;
    let maxp = vec2i(size) - vec2i(1);
    var wx: array<f32, 4>;
    var wy: array<f32, 4>;
    var sx = 0.0;
    var sy = 0.0;
    for (var k = 0; k < 4; k++) {
        wx[k] = cubic_weight(f32(k) - f.x - 1.0);
        wy[k] = cubic_weight(f32(k) - f.y - 1.0);
        sx += wx[k];
        sy += wy[k];
    }
    var acc = vec4f(0.0);
    for (var dy = 0; dy < 4; dy++) {
        for (var dx = 0; dx < 4; dx++) {
            let q = clamp(vec2i(base) + vec2i(dx - 1, dy - 1), vec2i(0), maxp);
            acc += textureLoad(src, q, 0) * (wx[dx] / sx) * (wy[dy] / sy);
        }
    }
    gpufx_write(id, acc);
}
