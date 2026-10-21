// Bindings (globals, params, src, smp, out_tex) and gpufx_* helpers come from the prelude.
// Port of FFmpeg's smptebars. The colours are limited-range Y'CbCr values (BT.601, as FFmpeg tags the output).

fn ycc(y: f32, u: f32, v: f32) -> vec3f {
    let yy = (y - 16.0) / 219.0;
    let cb = (u - 128.0) / 224.0;
    let cr = (v - 128.0) / 224.0;
    return clamp(vec3f(yy + 1.402 * cr, yy - 0.344136 * cb - 0.714136 * cr, yy + 1.772 * cb), vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let base = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let W = i32(globals.size.x);
    let H = i32(globals.size.y);
    let x = i32(id.x);
    let y = i32(id.y);

    var rainbow = array<vec3f, 7>(
        vec3f(180.0, 128.0, 128.0), vec3f(162.0, 44.0, 142.0), vec3f(131.0, 156.0, 44.0),
        vec3f(112.0, 72.0, 58.0), vec3f(84.0, 184.0, 198.0), vec3f(65.0, 100.0, 212.0), vec3f(35.0, 212.0, 114.0));
    var wobnair = array<vec3f, 7>(
        vec3f(35.0, 212.0, 114.0), vec3f(19.0, 128.0, 128.0), vec3f(84.0, 184.0, 198.0),
        vec3f(19.0, 128.0, 128.0), vec3f(131.0, 156.0, 44.0), vec3f(19.0, 128.0, 128.0), vec3f(180.0, 128.0, 128.0));
    let white = vec3f(235.0, 128.0, 128.0);
    let black0 = vec3f(16.0, 128.0, 128.0);
    let neg4ire = vec3f(7.0, 128.0, 128.0);
    let pos4ire = vec3f(24.0, 128.0, 128.0);
    let i_pixel = vec3f(57.0, 156.0, 97.0);
    let q_pixel = vec3f(44.0, 171.0, 147.0);

    let r_w = (W + 6) / 7;
    let r_h = (H * 2) / 3;
    let w_h = (H * 3) / 4 - r_h;
    let p_w = (r_w * 5) / 4;
    var c = black0;
    if (y < r_h) {
        c = rainbow[min(x / r_w, 6)];
    } else if (y < r_h + w_h) {
        c = wobnair[min(x / r_w, 6)];
    } else {
        // bottom strip: -I, white, Q, black, PLUGE pulses
        let third = r_w / 3;
        let e0 = p_w;
        let e1 = 2 * p_w;
        let e2 = 3 * p_w;
        let e3 = 5 * r_w;
        let e4 = e3 + third;
        let e5 = e4 + third;
        let e6 = e5 + third;
        if (x < e0) { c = i_pixel; }
        else if (x < e1) { c = white; }
        else if (x < e2) { c = q_pixel; }
        else if (x < e3) { c = black0; }
        else if (x < e4) { c = neg4ire; }
        else if (x < e5) { c = black0; }
        else if (x < e6) { c = pos4ire; }
        else { c = black0; }
    }
    let rgb = ycc(c.x, c.y, c.z);
    gpufx_write(id, vec4f(mix(base.rgb, rgb, params.opacity), mix(base.a, 1.0, params.opacity)));
}
