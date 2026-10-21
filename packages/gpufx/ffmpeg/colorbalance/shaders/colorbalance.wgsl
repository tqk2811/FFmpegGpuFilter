// Port of FFmpeg's colorbalance: shadows / midtones / highlights shifts per channel.

fn get_component(v: f32, l: f32, s_in: f32, m_in: f32, h_in: f32) -> f32 {
    let a = 4.0;
    let b = 0.333;
    let scale = 0.7;
    let s = s_in * clamp((b - l) * a + 0.5, 0.0, 1.0) * scale;
    let m = m_in * clamp((l - b) * a + 0.5, 0.0, 1.0) * clamp((1.0 - l - b) * a + 0.5, 0.0, 1.0) * scale;
    let h = h_in * clamp((l + b - 1.0) * a + 0.5, 0.0, 1.0) * scale;
    return clamp(v + s + m + h, 0.0, 1.0);
}

fn hfun(n: f32, h: f32, s: f32, l: f32) -> f32 {
    let a = s * min(l, 1.0 - l);
    let k = (n + h / 30.0) % 12.0;
    return clamp(l - a * max(min(min(k - 3.0, 9.0 - k), 1.0), -1.0), 0.0, 1.0);
}

fn preservel(c: vec3f, l_in: f32) -> vec3f {
    let mx = max(c.x, max(c.y, c.z));
    let mn = min(c.x, min(c.y, c.z));
    let l = l_in * 0.5;
    var h = 0.0;
    if (c.x == c.y && c.y == c.z) {
        h = 0.0;
    } else if (mx == c.x) {
        h = 60.0 * ((c.y - c.z) / (mx - mn));
    } else if (mx == c.y) {
        h = 60.0 * (2.0 + (c.z - c.x) / (mx - mn));
    } else {
        h = 60.0 * (4.0 + (c.x - c.y) / (mx - mn));
    }
    if (h < 0.0) {
        h += 360.0;
    }
    var s = 0.0;
    if (!(mx == 1.0 || mn == 0.0) && l > 0.0 && l < 1.0) {
        s = (mx - mn) / max(1.0 - abs(2.0 * l - 1.0), 1e-6);
    }
    return vec3f(hfun(0.0, h, s, l), hfun(8.0, h, s, l), hfun(4.0, h, s, l));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let l = max(p.r, max(p.g, p.b)) + min(p.r, min(p.g, p.b));
    var c = vec3f(
        get_component(p.r, l, params.rs, params.rm, params.rh),
        get_component(p.g, l, params.gs, params.gm, params.gh),
        get_component(p.b, l, params.bs, params.bm, params.bh));
    if (params.pl != 0u) {
        c = preservel(c, l);
    }
    gpufx_write(id, vec4f(c, p.a));
}
