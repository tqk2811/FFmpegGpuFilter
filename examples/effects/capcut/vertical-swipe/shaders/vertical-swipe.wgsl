// Both clips slide down with a short motion blur while a grey sparkling strip with a drop shadow sweeps down over the seam.

// The animation runs on a 2-second timeline; progress 0..1 maps onto it.
const SPAN: f32 = 2.0;
// Slide keys: the move runs from MOVE_START for 1 s; the trailing pose lags one key frame behind.
const MOVE_START: f32 = 0.5;
const TRAIL_START: f32 = 0.5333333;
const MOVE_LEN: f32 = 1.0;
// Visibility windows of the two clips on the timeline.
const FIRST_END: f32 = 1.5333333;
const SECOND_START: f32 = 0.4666667;
// Strip travel (offset of the strip from the centre at the start; it ends mirrored).
const STRIP_TRAVEL: f32 = 0.578125;
// Blur: the samples spread between these fractions of the trail-to-current move.
const SPREAD_FROM: f32 = 0.75;
const SPREAD_TO: f32 = 0.83;
const FEW_TAPS: f32 = 12.0;
const MANY_TAPS: f32 = 24.0;
// Strip artwork size in its own pixels (rows/columns below are in this space).
const ART: vec2f = vec2f(722.0, 720.0);

fn bezier1(q: f32, b: f32, c: f32) -> f32 {
    let r = 1.0 - q;
    return 3.0 * b * r * r * q + 3.0 * c * r * q * q + q * q * q;
}

// Strong ease-in-out: cubic-bezier(0.85, 0, 0.15, 1), solved for x by bisection.
fn ease(x: f32) -> f32 {
    if (x <= 0.0) { return 0.0; }
    if (x >= 1.0) { return 1.0; }
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier1(mid, 0.85, 0.15) > x) { hi = mid; } else { lo = mid; }
    }
    return bezier1(0.5 * (lo + hi), 0.0, 1.0);
}

fn hash2(a: f32, b: f32) -> f32 {
    var q = fract(vec2f(a, b) * 13.517);
    q += dot(q, q.yx + 22.541);
    return fract((q.x + q.y) * q.y);
}

fn fetch(uv: vec2f, use_second: bool) -> vec3f {
    if (use_second) { return textureSampleLevel(second, smp, uv, 0.0).rgb; }
    return textureSampleLevel(first, smp, uv, 0.0).rgb;
}

// One clip shifted down by `shift` (between the trailing and current shift), blurred along the move.
// Returns premultiplied colour with coverage in alpha (nothing is drawn outside the frame).
fn sliding_clip(uv: vec2f, trail: f32, now: f32, use_second: bool) -> vec4f {
    let s0 = mix(trail, now, SPREAD_FROM);
    let s1 = mix(trail, now, SPREAD_TO);
    let taps = floor(FEW_TAPS + (MANY_TAPS - FEW_TAPS) * smoothstep(0.0, 0.2, abs(s1 - s0)));
    // The jitter uses bottom-up coordinates, like the original renderer.
    let gl = vec2f(uv.x, 1.0 - uv.y);
    var acc = vec4f(0.0);
    for (var i = 0.0; i < MANY_TAPS; i += 1.0) {
        if (i >= taps) { break; }
        let k = i / (taps - 1.0) + (hash2(i + gl.x, i * gl.y) - 0.5) / taps;
        let p = vec2f(uv.x, uv.y - mix(s0, s1, k));
        if (all(p >= vec2f(0.0)) && all(p <= vec2f(1.0))) {
            acc += vec4f(fetch(p, use_second), 1.0);
        }
    }
    return acc / taps;
}

// The strip artwork, drawn procedurally: straight colour in rgb, alpha in a.
fn strip_art(px: vec2f) -> vec4f {
    let y = px.y;
    let side = clamp(px.x - 1.0, 0.0, 1.0) * clamp(720.6 - px.x, 0.0, 1.0);
    if (y < 309.0 || y > 423.5) { return vec4f(0.0); }
    if (y < 410.0) {
        // Grey face, a touch brighter toward its lower edge, with sparkle per art pixel.
        let cell = floor(px);
        let grain = (hash2(cell.x * 0.0137, cell.y * 0.0219) + hash2(cell.y * 0.0311, cell.x * 0.0173) - 1.0) * 26.0;
        var g = mix(198.5, 206.0, clamp((y - 310.0) / 93.0, 0.0, 1.0)) + grain;
        // Darker bevel along the lower edge.
        g = mix(g, 142.0, smoothstep(404.5, 409.5, y));
        let rgb = vec3f(g, g - 2.4, g + 1.4) / 255.0;
        return vec4f(rgb, clamp((y - 309.35) / 1.2, 0.0, 1.0) * side);
    }
    // Soft black drop shadow under the strip.
    let s = clamp((y - 410.5) / 12.5, 0.0, 1.0);
    return vec4f(vec3f(0.0), 0.235 * pow(1.0 - s, 1.3) * side);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress * SPAN;
    let now = ease((t - MOVE_START) / MOVE_LEN);
    let trail = ease((t - TRAIL_START) / MOVE_LEN);

    var top = vec4f(0.0);
    if (t >= SECOND_START) { top = sliding_clip(uv, trail - 1.0, now - 1.0, true); }
    var under = vec4f(0.0);
    if (t < FIRST_END) { under = sliding_clip(uv, trail, now, false); }
    var c = top.rgb + under.rgb * (1.0 - top.a);

    // Strip: travels from above the frame to below it, the artwork scaled to cover the frame.
    // On wide frames the art is cropped vertically; its travel is kept in art space so it still clears the frame.
    let aspect = globals.size.x / globals.size.y;
    let art_aspect = ART.x / ART.y;
    var q = uv;
    if (art_aspect > aspect) {
        q.x = (q.x - 0.5) * (aspect / art_aspect) + 0.5;
    } else {
        q.y = (q.y - 0.5) * (art_aspect / aspect) + 0.5;
    }
    q.y += STRIP_TRAVEL * (1.0 - 2.0 * now);
    let art = strip_art(q * ART);
    c = mix(c, art.rgb, art.a);
    gpufx_write(id, vec4f(c, 1.0));
}
