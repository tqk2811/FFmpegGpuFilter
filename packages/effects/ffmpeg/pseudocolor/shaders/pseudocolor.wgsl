// Port of FFmpeg's pseudocolor presets: the luma of the picture picks a color from a palette.
// The palettes are FFmpeg's degree-7 polynomials, rewritten in t = luma (0..1) instead of 0..256.

fn poly7(a: array<f32, 8>, t: f32) -> f32 {
    var r = a[0];
    for (var i = 1; i < 8; i++) {
        r = r * t + a[i];
    }
    return r;
}

fn limit(x: f32) -> f32 {
    return clamp(x, 0.0, 1.0);
}

// FFmpeg's YUV_BT709_TO_x: analog BT.709 (Umax 0.436, Vmax 0.615), as in vf_pseudocolor.c.
fn yuv709_to_rgb(y: f32, u: f32, v: f32) -> vec3f {
    let wr = 0.2126;
    let wb = 0.0722;
    let wg = 1.0 - wr - wb;
    let umax = 0.436;
    let vmax = 0.615;
    return clamp(vec3f(
        y + v * (1.0 - wr) / vmax,
        y - u * wb * (1.0 - wb) / (umax * wg) - v * wr * (1.0 - wr) / (vmax * wg),
        y + u * (1.0 - wb) / umax), vec3f(0.0), vec3f(1.0));
}

fn palette_magma(t: f32) -> vec3f {
    return vec3f(limit(poly7(array<f32, 8>(-54.497946, 209.105461, -313.641013, 233.844154, -93.2750094, 20.0339128, -0.592317978, 0.012152095), t)), limit(poly7(array<f32, 8>(95.2431049, -343.811776, 487.300387, -344.447757, 128.51074, -23.9361747, 2.17181875, -0.025536888), t)), limit(poly7(array<f32, 8>(-82.481215, 281.853448, -391.993213, 286.79651, -112.609254, 17.9218802, 1.22802322, 0.011971441), t)));
}

fn palette_inferno(t: f32) -> vec3f {
    return vec3f(limit(poly7(array<f32, 8>(-0.28714129, 26.6899214, -74.0762721, 79.3277754, -42.5458571, 11.769645, 0.101843364, 0.00028845935), t)), limit(poly7(array<f32, 8>(49.2935473, -184.366051, 270.067829, -197.522531, 76.7110083, -14.4912633, 1.331793, -0.011226064), t)), limit(poly7(array<f32, 8>(-215.606914, 728.011524, -961.014933, 631.935203, -213.095893, 29.596015, 0.795852518, 0.019122831), t)));
}

fn palette_plasma(t: f32) -> vec3f {
    return vec3f(limit(poly7(array<f32, 8>(26.0820309, -94.6404468, 135.503923, -97.7923681, 37.4094873, -8.23645241, 2.5546657, 0.057247918), t)), limit(poly7(array<f32, 8>(36.2182278, -149.727506, 246.859217, -204.138176, 86.1927341, -15.2437627, 0.80647232, 0.015362491), t)), limit(poly7(array<f32, 8>(-12.8134694, 63.2976396, -116.660779, 103.563017, -44.1771327, 5.86545568, 0.547489997, 0.53824268), t)));
}

fn palette_viridis(t: f32) -> vec3f {
    return vec3f(limit(poly7(array<f32, 8>(68.3466604, -243.840036, 333.272354, -220.505322, 77.2159203, -14.9056645, 1.16633582, 0.2566235), t)), limit(poly7(array<f32, 8>(6.95075053, -19.4807359, 19.3793289, -8.68862134, 2.49982364, -1.2658401, 1.50956388, 0.0039544827), t)), limit(poly7(array<f32, 8>(37.3153486, -103.197182, 112.699832, -66.2799267, 25.1791468, -7.86530435, 1.96995907, 0.32292815), t)));
}

fn palette_turbo(t: f32) -> vec3f {
    return vec3f(limit(poly7(array<f32, 8>(-314.775601, 1042.03013, -1287.81311, 704.451516, -145.698241, -0.121519899, 2.16282432, 0.16267077), t)), limit(poly7(array<f32, 8>(-28.8310137, 78.4229339, -69.6968557, 25.2854337, -9.13796604, 1.1820803, 2.71356646, 0.076914696), t)), limit(poly7(array<f32, 8>(-203.509445, 822.866987, -1289.34737, 968.605964, -336.540669, 33.158301, 4.53502259, 0.27271836), t)));
}

fn palette_cividis(t: f32) -> vec3f {
    return vec3f(limit(poly7(array<f32, 8>(-68.8035675, 272.997468, -440.45079, 368.267349, -167.176228, 38.795941, -2.65256422, 0.033164429), t)), limit(poly7(array<f32, 8>(0.917433036, -2.65257652, 2.50785859, -0.495995536, -0.400789453, 0.255503106, 0.662510848, 0.12769733), t)), limit(poly7(array<f32, 8>(33.1498137, -142.670796, 250.176817, -227.951519, 112.736342, -28.9144963, 3.43950106, 0.28293355), t)));
}

fn palette_spectral(t: f32) -> vec3f {
    return vec3f(limit(poly7(array<f32, 8>(-121.200873, 421.70581, -554.615655, 345.701918, -103.856, 10.3684506, 1.6475904, 0.62887), t)), limit(poly7(array<f32, 8>(90.2593423, -343.483914, 516.913402, -383.798278, 140.658501, -24.0137011, 3.784704, -0.0098075), t)), limit(poly7(array<f32, 8>(106.32098, -471.892798, 804.71057, -666.664824, 275.247006, -51.0414029, 3.712512, 0.21597), t)));
}

fn solar(t: f32) -> vec3f {
    let lf = t * 256.0;
    let x = vec3f(lf, lf - 9.0, lf + 9.0);
    let p = 1.983938313e-6 * x * x * x - 7.618323e-4 * x * x + 0.2 * x - vec3f(1.5707963267948966);
    return 0.5 * sin(p) + vec3f(0.5);
}

fn cool_fn_u(x: f32) -> f32 { return 0.25 * sin(2.0 * x * 3.141592653589793 - 3.141592653589793) + 0.5; }
fn cool_fn_v(x: f32) -> f32 { return 0.25 * sin(2.0 * x * 3.141592653589793) + 0.5; }
fn heat_fn_u(x: f32) -> f32 { return 0.25 * cos(2.0 * x * 3.141592653589793 + 3.141592653589793) + 0.75; }
fn heat_fn_v(x: f32) -> f32 { return 0.25 * sin(2.0 * x * 3.141592653589793) + 0.5; }
fn fiery_fn_u(x: f32) -> f32 { return 0.75 - 0.25 * cos(2.0 * x * 3.141592653589793); }
fn fiery_fn_v(x: f32) -> f32 { return 0.25 + 0.25 * cos(2.0 * x * 3.141592653589793); }
fn helix_fn_u(x: f32) -> f32 { return 0.5 + 0.15 * sin(5.0 * x * 3.141592653589793 + 3.141592653589793); }
fn helix_fn_v(x: f32) -> f32 { return 0.5 + 0.15 * cos(6.0 * x * 3.141592653589793 + 1.5707963267948966); }

// FFmpeg stores v = fun[0](t) - 0.5 and u = fun[2](t) - 0.5, y = t.
fn yuv_palette(t: f32, fv: f32, fu: f32) -> vec3f {
    return yuv709_to_rgb(t, fu - 0.5, fv - 0.5);
}

// The three fills of range1 / nominal / preferred / total (a zero w keeps the picture).
fn fill_of(k: i32) -> vec4f {
    switch (k) {
        case 0: { return vec4f(0.5, 0.0, 0.5, 1.0); }
        case 2: { return vec4f(1.0, 0.0, 0.0, 1.0); }
        default: { return vec4f(0.0); }
    }
}

// Segments of the range presets, by the 8-bit luma index. Returns vec4f(r, g, b, use);
// use = 0 keeps the source color.
fn range_color(preset: i32, idx: i32) -> vec4f {
    switch (preset) {
        case 6: { // range1
            if (idx < 16) { return fill_of(0); }
            if (idx < 236) { return fill_of(1); }
            return fill_of(2);
        }
        case 7: { // range2
            if (idx < 16) { return vec4f(0.5, 0.0, 0.5, 1.0); }
            if (idx < 22) { return vec4f(0.0, 1.0, 1.0, 1.0); }
            if (idx < 226) { return vec4f(0.0); }
            if (idx < 236) { return vec4f(1.0, 1.0, 0.0, 1.0); }
            return vec4f(1.0, 0.0, 0.0, 1.0);
        }
        case 8: { // shadows
            if (idx < 32) { return vec4f(0.8, 0.4, 0.8, 1.0); }
            return vec4f(0.0);
        }
        case 9: { // highlights
            if (idx < 214) { return vec4f(0.0); }
            if (idx < 224) { return vec4f(1.0, 0.3, 0.6, 1.0); }
            return vec4f(1.0, 0.2, 0.5, 1.0);
        }
        case 11: { // nominal
            if (idx < 16) { return fill_of(0); }
            if (idx < 236) { return fill_of(1); }
            return fill_of(2);
        }
        case 12: { // preferred
            if (idx < 5) { return fill_of(0); }
            if (idx < 247) { return fill_of(1); }
            return fill_of(2);
        }
        case 13: { // total
            if (idx < 1) { return fill_of(0); }
            if (idx < 255) { return fill_of(1); }
            return fill_of(2);
        }
        default: { return vec4f(0.0); }
    }
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let preset = params.preset;
    if (preset < 0) {
        gpufx_write(id, p);
        return;
    }
    let luma = clamp(dot(p.rgb, vec3f(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
    let idx = i32(round(luma * 255.0));
    let t = f32(idx) / 255.0;
    var color = p.rgb;
    switch (preset) {
        case 0: { color = palette_magma(t); }
        case 1: { color = palette_inferno(t); }
        case 2: { color = palette_plasma(t); }
        case 3: { color = palette_viridis(t); }
        case 4: { color = palette_turbo(t); }
        case 5: { color = palette_cividis(t); }
        case 10: { color = solar(t); }
        case 14: { color = palette_spectral(t); }
        case 15: { color = yuv_palette(t, cool_fn_u(t), cool_fn_v(t)); }
        case 16: { color = yuv_palette(t, heat_fn_u(t), heat_fn_v(t)); }
        case 17: { color = yuv_palette(t, fiery_fn_u(t), fiery_fn_v(t)); }
        case 18: { color = yuv_palette(t, fiery_fn_v(t), fiery_fn_u(t)); }
        case 19: { color = yuv_palette(t, fiery_fn_v(t), fiery_fn_v(t)); }
        case 20: { color = yuv_palette(t, helix_fn_u(t), helix_fn_v(t)); }
        default: {
            let f = range_color(preset, idx);
            if (f.w > 0.0) { color = f.rgb; }
        }
    }
    gpufx_write(id, vec4f(mix(p.rgb, color, params.opacity), p.a));
}
