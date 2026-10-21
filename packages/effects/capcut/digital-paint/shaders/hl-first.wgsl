// Digital Paint, pass 1: soft-threshold highlights of the first clip; the threshold pulses 0.8 / 0.4 then settles at 1.

const SPAN: f32 = 2.0; // scene seconds covered by progress 0..1

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let s = 0.5 * (lo + hi);
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

fn threshold(t: f32) -> f32 {
    let keys = array<f32, 6>(0.0, 0.159993, 0.319987, 0.480013, 0.6, 0.733333);
    let vals = array<f32, 6>(0.8, 0.4, 0.8, 0.4, 0.8, 1.0);
    if (t <= keys[0]) { return vals[0]; }
    if (t >= keys[5]) { return vals[5]; }
    var k = 0;
    for (var i = 0; i < 5; i++) { if (t >= keys[i]) { k = i; } }
    var curve = vec4f(0.33333333, 0.0, 0.66666667, 1.0);
    if (k == 4) { curve = vec4f(0.166666667, 0.0, 0.833333333, 1.0); }
    let x = clamp((t - keys[k]) / (keys[k + 1] - keys[k]), 0.0, 1.0);
    return mix(vals[k], vals[k + 1], bezier_ease(x, curve));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    // The first clip's layer ends at 1.933 s of scene time.
    if (t >= 1.933333) { gpufx_write(id, vec4f(0.0)); return; }
    let src = textureSampleLevel(first, smp, gpufx_uv(id), 0.0);
    let th = threshold(t);
    let knee = clamp(th, 0.01, 1.0);
    let lit = smoothstep(vec3f(knee - 0.075 * th), vec3f(knee + 0.115), src.rgb);
    gpufx_write(id, vec4f(pow(lit, vec3f(0.45454544)), src.a));
}
