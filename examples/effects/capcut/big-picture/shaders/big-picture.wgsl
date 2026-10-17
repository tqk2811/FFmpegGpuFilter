// A white crop-frame icon slides in from the right, then opens into a box that reveals the second clip and grows to fill the frame.

// The animation is laid out on a 960x540 reference canvas at 24 frames per transition second.
const REF: vec2f = vec2f(960.0, 540.0);
const FRAMES: f32 = 24.0;
// Handle dot radius, frame line half-thickness, and handle offsets past the box edges (reference px).
const DOT_R: f32 = 9.75;
const LINE_HALF: f32 = 1.5;
const SIDE_GAP: f32 = 23.0;
const END_GAP: f32 = 15.75;

// Horizontal centre of the collapsed icon for frames 3..16 (it settles at the middle).
fn icon_x(f: f32) -> f32 {
    var xs = array<f32, 14>(945.0, 916.5, 857.5, 794.5, 729.5, 666.5, 607.5, 556.5, 516.0, 489.5, 480.0, 480.0, 480.0, 480.0);
    let k = clamp(f - 3.0, 0.0, 13.0);
    let i = min(u32(floor(k)), 12u);
    return mix(xs[i], xs[i + 1u], k - f32(i));
}

// Half size of the opening box for frames 15..23 (frame 15 is the collapsed line, 23 covers the canvas).
fn box_half(f: f32) -> vec2f {
    var hw = array<f32, 9>(0.0, 17.5, 65.5, 133.5, 215.5, 301.5, 382.5, 451.5, 480.5);
    var hh = array<f32, 9>(155.0, 166.5, 198.5, 243.5, 298.0, 355.0, 408.0, 454.0, 500.0);
    let k = clamp(f - 15.0, 0.0, 8.0);
    let i = min(u32(floor(k)), 7u);
    let w = k - f32(i);
    return vec2f(mix(hw[i], hw[i + 1u], w), mix(hh[i], hh[i + 1u], w));
}

// Antialiased coverage of a signed distance (negative inside), `px` = one output pixel.
fn cover(d: f32, px: f32) -> f32 {
    return clamp(0.5 - d / px, 0.0, 1.0);
}

fn rect_dist(p: vec2f, half: vec2f) -> f32 {
    let q = abs(p) - half;
    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(a, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(b, 1.0)); return; }

    // Map the output onto the reference canvas, scaled to cover and centred.
    let size = globals.size;
    let s = max(size.x / REF.x, size.y / REF.y);
    let v = (uv * size - 0.5 * size) / s + 0.5 * REF;
    let px = 1.0 / s;
    let f = clamp(params.progress, 0.0, 1.0) * FRAMES;

    // Reveal mask: the box interior once it starts to open, the full frame at the end.
    var reveal = 0.0;
    if (f >= 22.5) {
        reveal = 1.0;
    } else if (f >= 15.5) {
        reveal = cover(rect_dist(v - 0.5 * REF, box_half(f) + 0.5), px);
    }
    var col = mix(a, b, reveal);

    // White icon: the frame outline plus four handle dots.
    var icon = 0.0;
    if (f >= 2.5 && f < 22.5) {
        if (f < 3.5) {
            icon = cover(length(v - vec2f(icon_x(f), 270.0)) - DOT_R, px);
        } else {
            var c = vec2f(icon_x(f), 270.0);
            var half = vec2f(0.0, 155.0);
            if (f >= 15.5) { c = 0.5 * REF; half = box_half(f); }
            let p = v - c;
            var line = 0.0;
            if (half.x < LINE_HALF) {
                line = cover(rect_dist(p, vec2f(LINE_HALF, half.y)), px);
            } else {
                line = cover(abs(rect_dist(p, half)) - LINE_HALF, px);
            }
            let d_side = length(vec2f(abs(p.x) - half.x - SIDE_GAP, p.y)) - DOT_R;
            let d_end = length(vec2f(p.x, abs(p.y) - half.y - END_GAP)) - DOT_R;
            icon = max(line, cover(min(d_side, d_end), px));
        }
    }
    col = mix(col, vec3f(1.0), icon);
    gpufx_write(id, vec4f(col, 1.0));
}
