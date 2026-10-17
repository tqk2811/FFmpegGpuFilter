// Pass 3 of CRT 2 Digital: vertical glow of the bright parts of the screen cut-out, screen-blended back over it.

const SPAN: f32 = 2.5;
const HANDOFF: f32 = 0.96667;
// Glow reach (fraction of the layer height), Gaussian sigma, and taps per side.
const REACH: f32 = 0.05;
const SIGMA: f32 = 0.016667;
const TAPS: i32 = 28;
const TAP_COUNT: f32 = 28.86;

// Keep only the part of each channel above `low`, rescaled, preserving the colour's hue.
fn bright_part(c: vec4f, low: f32) -> vec4f {
    var s = 0.0;
    for (var k = 0; k < 3; k++) {
        let v = c[k];
        if (v > low && v <= 1.0) { s += (v - low) / (1.0 - low); }
    }
    let total = max(c.r + c.g + c.b, 1e-5);
    return vec4f(c.rgb * (s / total), c.a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let q = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let base = textureSampleLevel(smeared, smp, q, 0.0);
    var low = 0.54;
    var exposure = 1.0;
    if (t < HANDOFF) {
        low = 0.5;
        exposure = clamp(t / 0.6, 0.0, 1.0);
    }
    if (exposure <= 1e-5) {
        gpufx_write(id, base);
        return;
    }
    let ds = REACH / TAP_COUNT;
    var acc = bright_part(base, low);
    var weight = 1.0;
    for (var i = 1; i <= TAPS; i++) {
        let d = f32(i) * ds;
        let w = exp(-0.5 * d * d / (SIGMA * SIGMA));
        let up = q.y - d;
        let down = q.y + d;
        if (up >= 0.0) { acc += bright_part(textureSampleLevel(smeared, smp, vec2f(q.x, up), 0.0), low) * w; }
        if (down <= 1.0) { acc += bright_part(textureSampleLevel(smeared, smp, vec2f(q.x, down), 0.0), low) * w; }
        weight += 2.0 * w;
    }
    var glow = acc / weight;
    glow = clamp(vec4f(glow.rgb * exposure, glow.a), vec4f(0.0), vec4f(1.0));
    // Screen blend of glow and layer, alpha included.
    gpufx_write(id, clamp(glow + base - glow * base, vec4f(0.0), vec4f(1.0)));
}
