// Port of FFmpeg's stereo3d for the layouts that keep the frame size.
// Input  `input`: 0 sbsl, 1 sbsr, 2 abl, 3 abr, 4 irl, 5 irr, 6 icl, 7 icr.
// Output `output`: 0..13 anaglyph in FFmpeg's order (arcg arch arcc arcd agmg agmh agmc agmd aybg aybh aybc aybd arbg argg),
//   14 ml, 15 mr, 16 irl, 17 irr, 18 sbsl, 19 sbsr, 20 abl, 21 abr, 22 chl, 23 chr, 24 icl, 25 icr.
// Each eye is read from its part of the input and stretched to the whole frame, then laid out again.

// Anaglyph matrices of FFmpeg's ana_coeff divided by 65536: three rows (r, g, b) of
// [left r, left g, left b, right r, right g, right b], 18 numbers per mode.
const ANA = array<f32, 252>(
    0.298995972, 0.587005615, 0.113998413, 0, 0, 0, 0, 0, 0, 0.298995972, 0.587005615, 0.113998413, 0, 0, 0, 0.298995972, 0.587005615, 0.113998413,
    0.298995972, 0.587005615, 0.113998413, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1,
    1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1,
    0.455993652, 0.5, 0.175994873, -0.042999268, -0.087997437, -0.001998901, -0.039993286, -0.037994385, -0.01600647, 0.378005981, 0.73399353, -0.018005371, -0.01499939, -0.020996094, -0.005004883, -0.072006226, -0.113006592, 1.225997925,
    0, 0, 0, 0.298995972, 0.587005615, 0.113998413, 0.298995972, 0.587005615, 0.113998413, 0, 0, 0, 0, 0, 0, 0.298995972, 0.587005615, 0.113998413,
    0, 0, 0, 1, 0, 0, 0.298995972, 0.587005615, 0.113998413, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    -0.06199646, -0.157989502, -0.039001465, 0.529006958, 0.705001831, 0.024002075, 0.283996582, 0.667999268, 0.143005371, -0.01600647, -0.01499939, -0.065002441, -0.01499939, -0.026992798, 0.020996094, 0.009002686, 0.074996948, 0.93699646,
    0, 0, 0, 0.298995972, 0.587005615, 0.113998413, 0, 0, 0, 0.298995972, 0.587005615, 0.113998413, 0.298995972, 0.587005615, 0.113998413, 0, 0, 0,
    0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0.298995972, 0.587005615, 0.113998413, 0, 0, 0,
    0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0,
    1.06199646, -0.205001831, 0.298995972, -0.015991211, -0.123001099, -0.016998291, -0.026000977, 0.908004761, 0.067993164, 0.005996704, 0.06199646, -0.016998291, -0.037994385, -0.17300415, 0.022003174, 0.093994141, 0.184997559, 0.910995483,
    0.298995972, 0.587005615, 0.113998413, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.298995972, 0.587005615, 0.113998413,
    0.298995972, 0.587005615, 0.113998413, 0, 0, 0, 0, 0, 0, 0.298995972, 0.587005615, 0.113998413, 0, 0, 0, 0, 0, 0
);

fn eye(e: i32, uv: vec2f) -> vec4f {
    let size = vec2f(textureDimensions(src));
    let mode = params.input;
    let uc = clamp(uv, vec2f(0.0), vec2f(1.0));
    // 1 when this eye is in the second half / on the second parity of the input
    var second = e;
    if (mode == 1 || mode == 3 || mode == 5 || mode == 7) { second = 1 - e; }
    if (mode <= 1) { // side by side: the eye is half of the width
        let lo = 0.5 * f32(second) + 0.5 / size.x;
        let hi = 0.5 * f32(second) + 0.5 - 0.5 / size.x;
        let x = clamp(0.5 * f32(second) + uc.x * 0.5, lo, hi);
        return textureSampleLevel(src, smp, vec2f(x, uc.y), 0.0);
    }
    if (mode <= 3) { // above below: half of the height
        let lo = 0.5 * f32(second) + 0.5 / size.y;
        let hi = 0.5 * f32(second) + 0.5 - 0.5 / size.y;
        let y = clamp(0.5 * f32(second) + uc.y * 0.5, lo, hi);
        return textureSampleLevel(src, smp, vec2f(uc.x, y), 0.0);
    }
    if (mode <= 5) { // interleaved rows: every second row
        let rows = max(floor(size.y * 0.5), 1.0);
        let r = min(floor(uc.y * rows), rows - 1.0);
        let row = min(2.0 * r + f32(second), size.y - 1.0);
        let x = min(floor(uc.x * size.x), size.x - 1.0);
        return textureLoad(src, vec2i(i32(x), i32(row)), 0);
    }
    // interleaved columns
    let cols = max(floor(size.x * 0.5), 1.0);
    let c = min(floor(uc.x * cols), cols - 1.0);
    let col = min(2.0 * c + f32(second), size.x - 1.0);
    let y = min(floor(uc.y * size.y), size.y - 1.0);
    return textureLoad(src, vec2i(i32(col), i32(y)), 0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let o = clamp(params.output, 0, 25);
    if (o <= 13) {
        let l = eye(0, uv);
        let r = eye(1, uv);
        var ana = ANA;
        let b = o * 18;
        var rgb = vec3f(0.0);
        for (var c = 0; c < 3; c++) {
            let k = b + c * 6;
            rgb[c] = ana[k] * l.r + ana[k + 1] * l.g + ana[k + 2] * l.b
                   + ana[k + 3] * r.r + ana[k + 4] * r.g + ana[k + 5] * r.b;
        }
        gpufx_write(id, vec4f(rgb, 1.0));
        return;
    }
    if (o == 14) { gpufx_write(id, eye(0, uv)); return; }
    if (o == 15) { gpufx_write(id, eye(1, uv)); return; }
    let x = i32(id.x);
    let y = i32(id.y);
    switch (o) {
        case 16, 17: { // interleaved rows
            let e = (y & 1) ^ select(0, 1, o == 17);
            gpufx_write(id, eye(e, uv));
        }
        case 18, 19: { // side by side
            let second = select(0, 1, uv.x >= 0.5);
            let e = second ^ select(0, 1, o == 19);
            gpufx_write(id, eye(e, vec2f(uv.x * 2.0 - f32(second), uv.y)));
        }
        case 20, 21: { // above below
            let second = select(0, 1, uv.y >= 0.5);
            let e = second ^ select(0, 1, o == 21);
            gpufx_write(id, eye(e, vec2f(uv.x, uv.y * 2.0 - f32(second))));
        }
        case 22, 23: { // checkerboard: the left eye on the pixels with an even x + y
            let e = ((x + y) & 1) ^ select(0, 1, o == 23);
            gpufx_write(id, eye(e, uv));
        }
        default: { // 24, 25 interleaved columns
            let e = (x & 1) ^ select(0, 1, o == 25);
            gpufx_write(id, eye(e, uv));
        }
    }
}
