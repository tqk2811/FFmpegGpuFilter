// Spotlight, pass 2: soften the beam clip vertically too.

const SPAN: f32 = 1.5999;
// Comp time at which the beam stops showing the second clip and starts showing the first.
const SWAP_AT: f32 = 0.8;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// At the ends the last pass shows the plain clips, so the passes before it have nothing to do.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0; }

const TAPS: i32 = 10;
const BLUR_GAMMA: f32 = 2.2;

fn linear_at(q: vec2f) -> vec4f {
    var c: vec4f;
    c = textureSampleLevel(soft_x, smp, q, 0.0);
    return vec4f(pow(c.rgb, vec3f(BLUR_GAMMA)), c.a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let uv = gpufx_uv(id);
    // One tap is a thousandth of the frame's reference size; taps falling outside the frame are dropped.
    let base = max(min(globals.size.x, globals.size.y), 0.5 * max(globals.size.x, globals.size.y));
    var dir = vec2f(0.0);
    dir[1] = base / 1000.0 / globals.size[1];
    var sum = linear_at(uv);
    var total = 1.0;
    for (var i = 1; i <= TAPS; i++) {
        let w = exp(-0.5 * f32(i * i) / 16.0);
        let lo = uv - dir * f32(i);
        let hi = uv + dir * f32(i);
        if (lo[1] >= 0.0) { sum += linear_at(lo) * w; total += w; }
        if (hi[1] <= 1.0) { sum += linear_at(hi) * w; total += w; }
    }
    let c = sum / total;
    gpufx_write(id, vec4f(pow(c.rgb, vec3f(1.0 / BLUR_GAMMA)), c.a));
}
