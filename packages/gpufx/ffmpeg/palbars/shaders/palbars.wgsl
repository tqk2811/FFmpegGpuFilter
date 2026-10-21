// Bindings (globals, params, src, smp, out_tex) and gpufx_* helpers come from the prelude.
// Port of FFmpeg's pal75bars / pal100bars. The colours are limited-range Y'CbCr values (BT.601).

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
    let x = i32(id.x);

    var rainbow = array<vec3f, 7>(
        vec3f(180.0, 128.0, 128.0), vec3f(162.0, 44.0, 142.0), vec3f(131.0, 156.0, 44.0),
        vec3f(112.0, 72.0, 58.0), vec3f(84.0, 184.0, 198.0), vec3f(65.0, 100.0, 212.0), vec3f(35.0, 212.0, 114.0));
    var rainbow100 = array<vec3f, 7>(
        vec3f(235.0, 128.0, 128.0), vec3f(210.0, 16.0, 146.0), vec3f(170.0, 166.0, 16.0),
        vec3f(145.0, 54.0, 34.0), vec3f(106.0, 202.0, 222.0), vec3f(81.0, 90.0, 240.0), vec3f(41.0, 240.0, 110.0));
    let white = vec3f(235.0, 128.0, 128.0);
    let black0 = vec3f(16.0, 128.0, 128.0);

    let r_w = (W + 7) / 8;
    let i = min(x / r_w, 7);
    var c = black0;
    if (params.full == 0u) {
        // 75%: 100% white, then six 75% bars, then black
        if (i == 0) { c = white; }
        else if (i < 7) { c = rainbow[i]; }
    } else if (i < 7) {
        c = rainbow100[i];
    }
    let rgb = ycc(c.x, c.y, c.z);
    gpufx_write(id, vec4f(mix(base.rgb, rgb, params.opacity), mix(base.a, 1.0, params.opacity)));
}
