// Tremor, pass 2: the incoming clip arrives with a heavy vertical motion blur that clears as it lands.

const T0: f32 = 0.166667;
const T1: f32 = 1.9;
const SIGMA: f32 = 4.0;

fn bezier_axis(a: f32, b: f32, end: f32, t: f32) -> f32 {
    let s = 1.0 - t;
    return 3.0 * a * s * s * t + 3.0 * b * s * t * t + end * t * t * t;
}

// Keyframe easing: cubic Bezier (0,0)-(c.xy)-(c.zw)-(1,end), solved for x by bisection.
fn ease(c: vec4f, end: f32, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 10; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(c.x, c.z, 1.0, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(c.y, c.w, end, 0.5 * (lo + hi));
}

fn span(t: f32, t0: f32, t1: f32) -> f32 { return clamp((t - t0) / (t1 - t0), 0.0, 1.0); }

// Blur length in taps: held at 100 with a bump on top while the clip lands, then cleared.
fn taps(t: f32) -> f32 {
    if (t < 1.266667) { return 100.0; }
    if (t < 1.366667) { return 100.0 + ease(vec4f(0.000292387, 4.2e-8, 0.000242813, 85.194639058), 0.0, span(t, 1.266667, 1.366667)); }
    if (t < 1.433333) { return mix(100.0, 0.0, ease(vec4f(0.177472436, 0.100822482, 0.480967582, 1.000000547), 1.0, span(t, 1.366667, 1.433333))); }
    return 0.0;
}

fn bell(x: f32) -> f32 {
    return 0.39894 * exp(-0.5 * x * x / (SIGMA * SIGMA)) / SIGMA;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = mix(T0, T1, clamp(params.progress, 0.0, 1.0));
    let n = floor(taps(t));
    let centre = textureSampleLevel(second, smp, uv, 0.0);
    // Before the cut the second clip is not shown, so skip the work.
    if (n < 1.0 || t < 1.266667) {
        gpufx_write(id, centre);
        return;
    }
    let step_y = min(globals.size.x, globals.size.y) / (720.0 * globals.size.y);
    var w = bell(0.0);
    var sum = centre * w;
    var total = w;
    for (var i = 1; i <= 140; i++) {
        let k = f32(i);
        if (k > n) { break; }
        w = bell(k / n * 15.0);
        sum += (textureSampleLevel(second, smp, uv + vec2f(0.0, k * step_y), 0.0)
              + textureSampleLevel(second, smp, uv - vec2f(0.0, k * step_y), 0.0)) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, clamp(sum / total, vec4f(0.0), vec4f(1.0)));
}
