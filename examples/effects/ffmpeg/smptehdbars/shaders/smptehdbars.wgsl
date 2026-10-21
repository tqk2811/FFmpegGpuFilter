// Bindings (globals, params, src, smp, out_tex) and gpufx_* helpers come from the prelude.
// Port of FFmpeg's smptehdbars. The colours are limited-range Y'CbCr values, decoded as BT.709 (FFmpeg tags the output BT.709).

fn ycc(y: f32, u: f32, v: f32) -> vec3f {
    let yy = (y - 16.0) / 219.0;
    let cb = (u - 128.0) / 224.0;
    let cr = (v - 128.0) / 224.0;
    return clamp(vec3f(yy + 1.5748 * cr, yy - 0.187324 * cb - 0.468124 * cr, yy + 1.8556 * cb), vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let base = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let W = i32(globals.size.x);
    let H = i32(globals.size.y);
    let x = i32(id.x);
    let y = i32(id.y);

    var rainbowhd = array<vec3f, 7>(
        vec3f(180.0, 128.0, 128.0), vec3f(168.0, 44.0, 136.0), vec3f(145.0, 147.0, 44.0),
        vec3f(133.0, 63.0, 52.0), vec3f(63.0, 193.0, 204.0), vec3f(51.0, 109.0, 212.0), vec3f(28.0, 212.0, 120.0));
    let white = vec3f(235.0, 128.0, 128.0);
    let gray40 = vec3f(104.0, 128.0, 128.0);
    let gray15 = vec3f(49.0, 128.0, 128.0);
    let cyan = vec3f(188.0, 154.0, 16.0);
    let yellow = vec3f(219.0, 16.0, 138.0);
    let blue = vec3f(32.0, 240.0, 118.0);
    let red = vec3f(63.0, 102.0, 240.0);
    let black0 = vec3f(16.0, 128.0, 128.0);
    let black2 = vec3f(20.0, 128.0, 128.0);
    let black4 = vec3f(25.0, 128.0, 128.0);
    let neg2 = vec3f(12.0, 128.0, 128.0);
    let i_pixel = vec3f(57.0, 156.0, 97.0);
    let q_pixel = vec3f(44.0, 171.0, 147.0);

    let d_w = W / 8;
    let r_h = (H * 7) / 12;
    let r_w = (((W + 3) / 4) * 3) / 7;
    let row_h = H / 12;
    let l_w = d_w + 7 * r_w;
    var c = black0;
    if (y < r_h) {
        // 40% gray, seven 75% bars, 40% gray
        if (x < d_w) { c = gray40; }
        else if (x < l_w) { c = rainbowhd[(x - d_w) / r_w]; }
        else { c = gray40; }
    } else if (y < r_h + row_h) {
        // cyan, +I, 75% white, blue
        if (x < d_w) { c = cyan; }
        else if (x < d_w + r_w) { c = i_pixel; }
        else if (x < l_w) { c = rainbowhd[0]; }
        else { c = blue; }
    } else if (y < r_h + 2 * row_h) {
        // yellow, +Q, luma ramp, red
        if (x < d_w) { c = yellow; }
        else if (x < d_w + r_w) { c = q_pixel; }
        else if (x < l_w) { c = vec3f(f32(((x - d_w - r_w) * 255) / (6 * r_w)), 128.0, 128.0); }
        else { c = red; }
    } else {
        // 15% gray, black / white / PLUGE section, 15% gray
        var e = d_w;
        if (x < e) { c = gray15; }
        else {
            e += (r_w * 3) / 2;
            if (x < e) { c = black0; }
            else {
                e += r_w * 2;
                if (x < e) { c = white; }
                else {
                    e += (r_w * 5) / 6;
                    let third = r_w / 3;
                    if (x < e) { c = black0; }
                    else if (x < e + third) { c = neg2; }
                    else if (x < e + 2 * third) { c = black0; }
                    else if (x < e + 3 * third) { c = black2; }
                    else if (x < e + 4 * third) { c = black0; }
                    else if (x < e + 5 * third) { c = black4; }
                    else if (x < l_w) { c = black0; }
                    else { c = gray15; }
                }
            }
        }
    }
    let rgb = ycc(c.x, c.y, c.z);
    gpufx_write(id, vec4f(mix(base.rgb, rgb, params.opacity), mix(base.a, 1.0, params.opacity)));
}
