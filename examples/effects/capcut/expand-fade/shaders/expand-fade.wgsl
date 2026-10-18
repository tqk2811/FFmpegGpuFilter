// The second clip opens out from a soft centre band and widens to both side edges.

// Width of the soft edge between the two clips, in units of half the frame width.
const EDGE: f32 = 0.5;
// The band only moves between these progress values; outside them it eases in/out.
const RAMP_IN: f32 = 0.1;
const RAMP_OUT: f32 = 0.9;

fn band_mix(a: vec3f, b: vec3f, x: f32, t: f32) -> vec3f {
    // 0 at the centre column, 1 at either side edge.
    let dist = abs(x - 0.5) * 2.0;
    let front = t * (1.0 + EDGE) - EDGE * 0.5;
    let keep_first = smoothstep(front - EDGE * 0.5, front + EDGE * 0.5, dist);
    return mix(b, a, keep_first);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = params.progress;
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (p <= 0.0) { gpufx_write(id, vec4f(a, 1.0)); return; }
    if (p >= 1.0) { gpufx_write(id, vec4f(b, 1.0)); return; }
    let t = clamp((p - RAMP_IN) / (RAMP_OUT - RAMP_IN), 0.0, 1.0);
    var col = mix(a, band_mix(a, b, uv.x, t), smoothstep(0.0, RAMP_IN, p));
    col = mix(col, b, smoothstep(RAMP_OUT, 1.0, p));
    gpufx_write(id, vec4f(col, 1.0));
}
