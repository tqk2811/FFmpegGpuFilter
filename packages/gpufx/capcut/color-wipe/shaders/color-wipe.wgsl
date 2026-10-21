// The picture drops to black and white while a slanted, shadowed band of vivid mirrored second clip sweeps left to right, wiping first to second behind it.

// Animation time covered by progress 0..1, in seconds.
const SPAN: f32 = 1.5;
// The straight wipe only exists from this time on.
const WIPE_START: f32 = 0.2;
// Angle of the wipe edge, in degrees.
const WIPE_ANGLE: f32 = 106.0;
// Luma weights used both for the black-and-white look and for the saturation boost.
const LUMA: vec3f = vec3f(0.20854, 0.70209, 0.08937);
// Colour gain of the clip shown inside the band (1 = unchanged).
const BAND_GAIN: f32 = 1.5;
// The band artwork lives on a 360-texel square scaled to 1.155 of the frame height.
const ART_TEXELS: f32 = 360.0;
const ART_SCALE: f32 = 1.155;

// Piecewise-linear track through four keys at t = 0, 1/3, 2/3 and 1 second.
fn track(t: f32, k: vec4f) -> f32 {
    let s = clamp(t, 0.0, 1.0) * 3.0;
    if (s < 1.0) { return mix(k.x, k.y, s); }
    if (s < 2.0) { return mix(k.y, k.z, s - 1.0); }
    return mix(k.z, k.w, s - 2.0);
}

// Smooth step function approximating the normal CDF.
fn soft_cdf(z: f32) -> f32 {
    let q = 0.7978846 * (z + 0.044715 * z * z * z);
    return 0.5 + 0.5 * tanh(clamp(q, -10.0, 10.0));
}

// Signed distances (texels, positive inside) to the four sides of the slanted band:
// x = across the band, y = along it.
fn band_dist(p: vec2f) -> vec2f {
    let across = (p.x + 0.3255 * (p.y - 40.0) - 183.0) / 1.0513;
    let width = 135.1 / 1.0513;
    return vec2f(min(across, width - across), min(p.y - 20.0, 340.0 - p.y));
}

// Antialiased band coverage at texel position p.
fn band_cover(p: vec2f) -> f32 {
    let d = band_dist(p);
    return clamp(min(d.x, d.y) + 0.5, 0.0, 1.0);
}

// Soft drop shadow cast down and to the left of the band, hidden under the band itself.
fn band_shadow(p: vec2f) -> f32 {
    let q = p + vec2f(0.5) - vec2f(-3.0, 5.0);
    let across = (q.x + 0.3255 * (q.y - 40.0) - 183.0) / 1.0513;
    let width = 135.1 / 1.0513;
    let sigma = 3.5;
    let blur = soft_cdf(across / sigma) * soft_cdf((width - across) / sigma)
        * soft_cdf((q.y - 20.0) / sigma) * soft_cdf((340.0 - q.y) / sigma);
    return 0.6 * blur * (1.0 - band_cover(p));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress * SPAN;
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;

    // Straight wipe: the second clip takes over where the rotated coordinate is below the edge.
    var mixed = a;
    if (t >= WIPE_START) {
        let ang = radians(WIPE_ANGLE);
        let c = uv - 0.5;
        let along = 0.5 + c.x * sin(ang) - c.y * cos(ang);
        let edge = track(t, vec4f(0.0, 0.42333, 0.55, 1.0)) * 2.0 - 0.5;
        if (along < edge) { mixed = b; }
    }
    var col = vec3f(clamp(dot(mixed, LUMA), 0.0, 1.0));

    // Band artwork placement: centre slides along x (in 720-wide layout units).
    let cx = track(t, vec4f(-419.0, 222.0, 344.37428, 1099.0)) / 720.0;
    let art = (vec2f((uv.x - cx) / ART_SCALE, (uv.y - 0.5) / ART_SCALE) + 0.5) * ART_TEXELS;
    col *= 1.0 - band_shadow(art);
    let cover = band_cover(art);
    if (cover > 0.0) {
        let m = textureSampleLevel(second, smp, vec2f(1.0 - uv.x, uv.y), 0.0).rgb;
        let vivid = clamp(m * BAND_GAIN + (1.0 - BAND_GAIN) * dot(m, LUMA), vec3f(0.0), vec3f(1.0));
        col = mix(col, vivid, cover);
    }
    gpufx_write(id, vec4f(col, 1.0));
}
