// Dispersion Trail, passes 3-4: blur the two-byte glow vertically (red+green, then blue).

const GRID: f32 = 240.0;
const WIDTH: f32 = 0.1;
const SPREAD = vec3f(1.0, 1.2, 1.4);
const MAX_TAPS: f32 = 30.0;
const DITHER: f32 = 1.0;

fn jitter(a: f32, b: f32) -> f32 {
    let q = fract(vec2f(a, b) * 13.517);
    let r = q + dot(q, q.yx + 22.541);
    return fract((r.x + r.y) * r.y) - 0.5;
}

fn unpack2(c: vec4f) -> vec2f {
    return vec2f(c.x + c.y / 255.0, c.z + c.w / 255.0);
}

fn pack2(v: vec2f) -> vec4f {
    let s = clamp(v, vec2f(0.0), vec2f(1.0)) * 255.0;
    return vec4f(floor(s.x) / 255.0, fract(s.x), floor(s.y) / 255.0, fract(s.y));
}

fn fetch(q: vec2f) -> vec3f {
    let rg = unpack2(textureSampleLevel(glow_h_rg, smp, q, 0.0));
    let b = unpack2(textureSampleLevel(glow_h_b, smp, q, 0.0)).x;
    return vec3f(rg, b);
}

fn blurred(uv: vec2f) -> vec3f {
    let gw = min(globals.size.x, GRID);
    let gh = globals.size.y * gw / globals.size.x;
    let radius = WIDTH * gw * SPREAD;
    let spread = 2.0 * pow(radius / 2.4, vec3f(2.0));
    let reach = max(radius.r, max(radius.g, radius.b));
    let stride = max(1.0, reach / MAX_TAPS);
    var sum = fetch(uv);
    var total = vec3f(1.0);
    var i = 1.0;
    for (var j = 0; j < 128; j++) {
        if (i > reach || i > MAX_TAPS * stride) { break; }
        let w = step(vec3f(i), radius) * exp(-(i * i) / spread);
        let da = i + DITHER * stride * jitter(i + uv.x + 0.223, i * uv.y);
        let db = i + DITHER * stride * jitter(i + uv.x + 0.569, i * uv.y);
        sum += (fetch(uv + vec2f(0.0, da / gh)) + fetch(uv - vec2f(0.0, db / gh))) * w;
        total += 2.0 * w;
        i += stride;
    }
    return sum / total;
}

@compute @workgroup_size(8, 8)
fn blur_rg(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    gpufx_write(id, pack2(blurred(gpufx_uv(id)).rg));
}

@compute @workgroup_size(8, 8)
fn blur_b(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    gpufx_write(id, pack2(vec2f(blurred(gpufx_uv(id)).b, 0.0)));
}
