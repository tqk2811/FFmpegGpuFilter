// Flying Rectangle, last pass: the zooming first clip seen through a band of black that tilts and flies off, then the glowing second clip.

// Animation length (seconds of comp time) mapped onto progress 0..1.
const SPAN: f32 = 2.0;
// Comp time at which the second clip takes over.
const SWAP_AT: f32 = 1.2;
// The band animation starts at this comp time and runs at 25 steps a second.
const BAND_START: f32 = 0.08;
const BAND_RATE: f32 = 25.0;
// Per step: the two edges of the window onto the first clip, each as (angle of its outward
// normal in degrees, offset), on a square canvas from (0,0) top-left to (1,1) bottom-right
// that is cover-fitted to the frame. A point is inside when dot(normal, p) <= offset.
const BAND_STEPS: i32 = 24;
const BAND: array<vec4f, 24> = array<vec4f, 24>(
    vec4f(-90.0, 0.01, 90.0, 1.01),
    vec4f(-90.0, 0.01, 90.0, 1.01),
    vec4f(-90.0, 0.01, 90.0, 1.01),
    vec4f(-90.0, 0.002, 90.0, 0.9933),
    vec4f(-90.0, -0.0067, 90.0, 0.985),
    vec4f(-90.0, -0.015, 90.0, 0.9767),
    vec4f(-90.0, -0.025, 90.0, 0.9683),
    vec4f(-90.0, -0.035, 90.0, 0.9567),
    vec4f(-90.0, -0.0483, 90.0, 0.945),
    vec4f(-91.09, -0.0695, 88.91, 0.9423),
    vec4f(-95.04, -0.1151, 84.96, 0.9615),
    vec4f(-103.14, -0.1879, 76.87, 1.0062),
    vec4f(-116.35, -0.2717, 63.65, 1.0612),
    vec4f(-132.78, -0.3231, 47.22, 1.083),
    vec4f(-147.99, -0.3209, 32.01, 1.0504),
    vec4f(-159.95, -0.2884, 20.05, 0.9872),
    vec4f(-168.89, -0.2496, 11.12, 0.918),
    vec4f(-175.5, -0.2152, 4.5, 0.8542),
    vec4f(-180.34, -0.1876, -0.36, 0.8005),
    vec4f(-183.86, -0.2646, -3.86, 0.6619),
    vec4f(-186.29, -0.3265, -6.29, 0.5553),
    vec4f(-187.87, -0.3643, -7.87, 0.4875),
    vec4f(-188.73, -0.3922, -8.73, 0.4425),
    vec4f(-189.5, -0.425, -9.5, 0.415));

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

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

// Zoom of the first clip; `lag` shifts the curve later (the previous-frame copy for the blur).
fn zoom(t: f32, lag: f32) -> f32 {
    let u = clamp((t - 0.64 - lag) / 0.36, 0.0, 1.0);
    return mix(1.0, 1.8, ease(u, vec4f(0.26, 0.0, 0.44, 1.0)));
}

fn grain(a: f32, b: f32) -> f32 {
    let r = fract(vec2f(a, b) * 13.517);
    let s = r + dot(r, r.yx + 22.541);
    return fract((s.x + s.y) * s.y);
}

fn inside01(p: vec2f) -> f32 {
    return step(0.0, p.x) * step(0.0, p.y) * step(p.x, 1.0) * step(p.y, 1.0);
}

// Motion-blurred zoom: six scales spread from a quarter-step before the previous frame's
// scale to a quarter-step past the current one, walked with dithered taps.
fn smeared_zoom(uv: vec2f, now: f32, before: f32) -> vec4f {
    var pts: array<vec2f, 6>;
    for (var k = 0; k < 6; k++) {
        let w = 0.5 * f32(k) / 5.0 + 0.75;
        let s = max(before * (1.0 - w) + now * w, 0.001);
        pts[k] = (uv - 0.5) / s + 0.5;
    }
    let n = floor(12.0 + 12.0 * smoothstep(0.0, 0.2, length(pts[5] - pts[0])));
    var acc = vec4f(0.0);
    for (var j = 0.0; j < 24.0; j += 1.0) {
        if (j >= n) { break; }
        let f = j / (n - 1.0) + (grain(j + uv.x, j * uv.y) - 0.5) / n;
        let seg = clamp(floor(f * 5.0), 0.0, 4.0);
        let i = u32(seg);
        let p = mix(pts[i], pts[i + 1u], f * 5.0 - seg);
        acc += textureSampleLevel(first, smp, p, 0.0) * inside01(p);
    }
    return acc / n;
}

// Edge pair of the window at comp time t, blended between the 25-per-second steps.
fn band_at(t: f32) -> vec4f {
    let f = clamp((t - BAND_START) * BAND_RATE, 0.0, f32(BAND_STEPS - 1));
    let i = min(i32(f), BAND_STEPS - 2);
    return mix(BAND[i], BAND[i + 1], f - f32(i));
}

// How much of pixel `px` lies inside the window (1 = first clip shows, 0 = black).
fn window(px: vec2f, t: f32) -> f32 {
    if (t < BAND_START) { return 1.0; }
    if ((t - BAND_START) * BAND_RATE >= f32(BAND_STEPS - 1)) { return 0.0; }
    let side = max(globals.size.x, globals.size.y);
    let p = (px - 0.5 * globals.size) / side + 0.5;
    let b = band_at(t);
    let n1 = vec2f(cos(radians(b.x)), sin(radians(b.x)));
    let n2 = vec2f(cos(radians(b.z)), sin(radians(b.z)));
    let a1 = clamp((b.y - dot(n1, p)) * side + 0.5, 0.0, 1.0);
    let a2 = clamp((b.w - dot(n2, p)) * side + 0.5, 0.0, 1.0);
    return a1 * a2;
}

fn screen3(a: vec3f, b: vec3f) -> vec3f { return 1.0 - (1.0 - a) * (1.0 - b); }

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clock();
    if (t < SWAP_AT) {
        let open = window(uv * globals.size, t);
        if (open <= 0.0) { gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0)); return; }
        let c = smeared_zoom(uv, zoom(t, 0.0), zoom(t, 0.04));
        gpufx_write(id, vec4f(c.rgb * open, 1.0));
        return;
    }
    // Second clip, softened, with its glow screened on top.
    let base = textureSampleLevel(soft, smp, uv, 0.0).rgb;
    let halo = textureSampleLevel(glow_b, smp, uv, 0.0).rgb;
    gpufx_write(id, vec4f(screen3(base, halo), 1.0));
}
