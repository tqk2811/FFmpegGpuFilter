// Bindings (globals, params, src, smp, out_tex) and gpufx_* helpers come from the prelude.
fn palette(x: f32) -> vec3f {
    return 0.5 + 0.5 * cos(6.2831853 * (x + vec3f(0.0, 0.33, 0.67)));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let base = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let t = f32(globals.time_int) + globals.time_frac;
    // FFmpeg: scale = start_scale * (end_scale / start_scale) ^ (pts / end_pts), in units per picture height.
    let s0 = max(params.start_scale, 1e-7);
    let s1 = max(params.end_scale, 1e-7);
    let scale = s0 * pow(s1 / s0, t / max(params.end_time, 1e-3)) / globals.size.y;
    let cr = params.start_x + scale * (f32(id.x) + 0.5 - globals.size.x * 0.5);
    let ci = params.start_y + scale * (f32(id.y) + 0.5 - globals.size.y * 0.5);

    let maxi = clamp(params.maxiter, 1, 2000);
    let b2 = params.bailout * params.bailout;
    var zr = 0.0;
    var zi = 0.0;
    var n = 0;
    var escaped = false;
    for (var k = 0; k < maxi; k++) {
        let zr2 = zr * zr;
        let zi2 = zi * zi;
        if (zr2 + zi2 > b2) { escaped = true; break; }
        zi = 2.0 * zr * zi + ci;
        zr = zr2 - zi2 + cr;
        n = k + 1;
    }

    var rgb = vec3f(0.0);
    let ang = atan2(zi, zr) / 6.2831853;
    if (escaped) {
        if (params.outer_mode == 0) {
            rgb = palette(f32(n) * 0.02);
        } else if (params.outer_mode == 1) {
            let r = 0.5 * log(zr * zr + zi * zi) / log(params.bailout);
            let nu = f32(n) + 1.0 - log2(max(r, 1.0));
            rgb = palette(nu * 0.02);
        } else if (params.outer_mode == 2) {
            rgb = vec3f(1.0);
        } else {
            rgb = palette(ang);
        }
    } else {
        if (params.inner_mode == 1) {
            rgb = vec3f(1.0);
        } else if (params.inner_mode == 2) {
            rgb = palette(ang) * 0.6;
        }
    }
    gpufx_write(id, vec4f(mix(base.rgb, rgb, params.opacity), mix(base.a, 1.0, params.opacity)));
}
