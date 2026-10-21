// Port of FFmpeg's monochrome: black and white through a color filter picked in the chroma plane.

fn envelope(x: f32) -> f32 {
    let beta = 0.6;
    if (x < beta) {
        let tmp = abs(x / beta - 1.0);
        return 1.0 - tmp * tmp;
    }
    let tmp = (1.0 - x) / (1.0 - beta);
    return tmp * tmp * (3.0 - 2.0 * tmp);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let y = dot(p.rgb, vec3f(0.2126, 0.7152, 0.0722));
    let u = (p.b - y) / 1.8556;
    let v = (p.r - y) / 1.5748;
    let b = params.cb * 0.5;
    let r = params.cr * 0.5;
    let size = 1.0 / params.size;
    let ihigh = 1.0 - params.high;
    let f = exp(-clamp(((b - u) * (b - u) + (r - v) * (r - v)) * size, 0.0, 1.0));
    let tt = envelope(y);
    let t = tt + (1.0 - tt) * ihigh;
    let ny = (1.0 - t) * y + t * f * y;
    gpufx_write(id, vec4f(vec3f(ny), p.a));
}
