// Signal Glitch 2, pass 7: blur the glow vertically on the same grid as pass 6.

const GRID: f32 = 360.0;
const WIDTH: f32 = 0.1;
const SPREAD = vec3f(1.0, 1.2, 1.4);
const MAX_TAPS: f32 = 30.0;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let gw = min(globals.size.x, GRID);
    let gh = floor(globals.size.y * gw / globals.size.x);
    let radius = WIDTH * gw * SPREAD;
    let spread = 2.0 * pow(radius / 2.4, vec3f(2.0));
    let reach = max(radius.r, max(radius.g, radius.b));
    let stride = max(1.0, reach / MAX_TAPS);
    var sum = textureSampleLevel(glow_h, smp, uv, 0.0).rgb;
    var total = vec3f(1.0);
    var i = 1.0;
    for (var j = 0; j < 64; j++) {
        if (i > reach || i > MAX_TAPS * stride) { break; }
        let w = step(vec3f(i), radius) * exp(-(i * i) / spread);
        let o = vec2f(0.0, i / gh);
        sum += (textureSampleLevel(glow_h, smp, uv + o, 0.0).rgb + textureSampleLevel(glow_h, smp, uv - o, 0.0).rgb) * w;
        total += 2.0 * w;
        i += stride;
    }
    gpufx_write(id, vec4f(sum / total, 1.0));
}
