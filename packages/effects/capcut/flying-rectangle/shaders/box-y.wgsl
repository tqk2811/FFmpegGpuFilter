// Flying Rectangle: vertical half of the fading box blur on the settling second clip.

// Animation length (seconds of comp time) mapped onto progress 0..1.
const SPAN: f32 = 2.0;
// Comp time at which the second clip takes over.
const SWAP_AT: f32 = 1.2;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// The chain only matters while the second clip shows; the last pass handles the exact ends.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0 || clock() < SWAP_AT; }

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bez(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(u: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let mid = 0.5 * (lo + hi);
        if (bez(c.x, c.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bez(c.y, c.w, 0.5 * (lo + hi));
}

// Taps per side: 28 at the swap, eased down to none by 1.64 s.
fn reach(t: f32) -> f32 {
    return mix(28.0, 0.0, ease(clamp((t - 1.2) / 0.44, 0.0, 1.0), vec4f(0.16667, 0.16667, 0.37, 1.0)));
}

// Tap spacing in uv: a thousandth of the larger of (short side, half the long side).
fn spacing() -> vec2f {
    let s = globals.size;
    let base = max(min(s.x, s.y), max(s.x, s.y) * 0.5);
    return vec2f(base / s.x, base / s.y) / 1000.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let uv = gpufx_uv(id);
    let n = reach(clock());
    let dy = spacing().y;
    var acc = textureSampleLevel(soft_x, smp, uv, 0.0);
    var count = 1.0;
    // Taps that fall off the frame are skipped, not counted.
    for (var i = 1; i <= 28; i++) {
        let fi = f32(i);
        if (fi > n) { break; }
        let l = uv.y - fi * dy;
        let r = uv.y + fi * dy;
        if (l >= 0.0) { acc += textureSampleLevel(soft_x, smp, vec2f(uv.x, l), 0.0); count += 1.0; }
        if (r <= 1.0) { acc += textureSampleLevel(soft_x, smp, vec2f(uv.x, r), 0.0); count += 1.0; }
    }
    gpufx_write(id, acc / count);
}
