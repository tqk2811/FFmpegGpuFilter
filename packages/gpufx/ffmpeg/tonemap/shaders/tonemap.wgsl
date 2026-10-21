fn safe_nz(x: f32) -> f32 {
    return select(select(-1e-6, 1e-6, x >= 0.0), x, abs(x) > 1e-6);
}

fn hable(x: f32) -> f32 {
    let a = 0.15;
    let b = 0.50;
    let c = 0.10;
    let d = 0.20;
    let e = 0.02;
    let f = 0.30;
    return (x * (x * a + b * c) + d * e) / safe_nz(x * (x * a + b) + d * f) - e / f;
}

fn mobius(x: f32, j: f32, peak: f32) -> f32 {
    if (x <= j) { return x; }
    let a = -j * j * (peak - 1.0) / safe_nz(j * j - 2.0 * j + peak);
    let b = (j * j - 2.0 * j * peak + peak) / max(peak - 1.0, 1e-6);
    return (b * b + 2.0 * b * j + j * j) / safe_nz(b - a) * (x + a) / safe_nz(x + b);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let mode = params.tonemap;
    let peak = select(params.peak, 1.0, params.peak <= 0.0);
    var prm = params.param;
    let has = prm > 0.0;
    if (mode == 2) {
        prm = select(1.8, prm, has);
    } else if (mode == 4) {
        // valid range is (0,1]; a larger value would make prm negative (division by zero), so clamp it
        let rp = min(prm, 1.0);
        prm = select(1.0, (1.0 - rp) / rp, has);
    } else if (mode == 6) {
        prm = select(0.3, prm, has);
    } else {
        prm = select(1.0, prm, has);
    }

    var c = p.rgb;
    if (params.desat > 0.0) {
        let luma = dot(c, vec3f(0.2126, 0.7152, 0.0722));
        let overbright = max(luma - params.desat, 1e-6) / max(luma, 1e-6);
        c = mix(c, vec3f(luma), overbright);
    }
    let sig_orig = max(max(c.r, max(c.g, c.b)), 1e-6);
    var sig = sig_orig;
    if (mode == 1) {
        sig = sig * prm / peak;
    } else if (mode == 2) {
        sig = select(sig * pow(0.05 / peak, 1.0 / prm) / 0.05, pow(sig / peak, 1.0 / prm), sig > 0.05);
    } else if (mode == 3) {
        sig = clamp(sig * prm, 0.0, 1.0);
    } else if (mode == 4) {
        sig = sig / (sig + prm) * (peak + prm) / peak;
    } else if (mode == 5) {
        sig = hable(sig) / safe_nz(hable(peak));
    } else if (mode == 6) {
        sig = mobius(sig, prm, peak);
    }
    gpufx_write(id, vec4f(c * (sig / sig_orig), p.a));
}
