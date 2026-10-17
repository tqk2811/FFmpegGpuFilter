// A tilted window onto the second clip opens from a thin line, stretches into a band and then fills the frame, framed by a selection-box overlay.

// The animation runs over 60 frames of a 30 fps, 1280x720 layout canvas.
const FRAMES: f32 = 60.0;
const CANVAS: vec2f = vec2f(1280.0, 720.0);
// Tilt of the window, in degrees (canvas y points down).
const TILT: f32 = 153.0;
// Window centre in the tilted (across, along) frame, in canvas pixels.
const CENTRE: vec2f = vec2f(-406.6, -610.65);

// Half extent across the tilt for frames 0..23 (it holds the last value afterwards).
const ACROSS = array<f32, 24>(
    0.8, 2.75, 9.4, 22.7, 45.8, 85.75, 152.0, 250.5, 351.4, 429.8, 487.95, 533.2,
    569.8, 599.9, 624.9, 645.9, 663.8, 679.05, 692.2, 703.45, 713.2, 721.3, 728.1, 733.5);
// Half extent along the tilt for frames 35..56; before that it is 200.55, after it covers all.
const ALONG = array<f32, 22>(
    200.55, 311.35, 364.05, 402.5, 433.45, 459.25, 481.5, 500.25, 516.75, 531.15, 543.85,
    555.05, 564.95, 573.65, 581.45, 587.95, 593.75, 598.65, 602.65, 606.25, 609.35, 2000.0);

fn across_at(f: f32) -> f32 {
    let g = clamp(f, 0.0, 23.0);
    let i = min(u32(g), 22u);
    return mix(ACROSS[i], ACROSS[i + 1u], g - f32(i));
}

fn along_at(f: f32) -> f32 {
    let g = clamp(f - 35.0, 0.0, 21.0);
    let i = min(u32(g), 20u);
    return mix(ALONG[i], ALONG[i + 1u], g - f32(i));
}

// Distance (canvas px) from p to a segment a-b.
fn seg_dist(p: vec2f, a: vec2f, b: vec2f) -> f32 {
    let ab = b - a;
    let h = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
    return length(p - a - ab * h);
}

// Selection-box overlay (white, screened): two long edges, corner dots, mid-edge grips and
// two small ring icons. It trails the window by one frame and disappears when the band widens.
fn overlay(q: vec2f, f: f32, rot: mat2x2f) -> f32 {
    if (f >= 35.5) { return 0.0; }
    let ha = across_at(f - 1.0);
    let hl = along_at(f);
    var g = 0.0;
    for (var s = -1.0; s <= 1.0; s += 2.0) {
        let a = rot * (CENTRE + vec2f(-ha, s * hl));
        let b = rot * (CENTRE + vec2f(ha, s * hl));
        g = max(g, clamp(1.0 - seg_dist(q, a, b), 0.0, 1.0) * 0.8);
        g = max(g, clamp(4.5 - length(q - a), 0.0, 1.0));
        g = max(g, clamp(4.5 - length(q - b), 0.0, 1.0));
        let grip_a = rot * (CENTRE + vec2f(-9.0, s * hl));
        let grip_b = rot * (CENTRE + vec2f(9.0, s * hl));
        g = max(g, clamp(3.5 - seg_dist(q, grip_a, grip_b), 0.0, 1.0));
        let icon = rot * (CENTRE + vec2f(s * 12.0, s * (hl + 22.0)));
        let r = length(q - icon);
        g = max(g, clamp(1.5 - abs(r - 9.0), 0.0, 1.0));
        g = max(g, clamp(1.2 - abs(r - 4.5), 0.0, 1.0) * 0.8);
    }
    return g;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let f = clamp(params.progress, 0.0, 1.0) * FRAMES;
    let outgoing = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let incoming = textureSampleLevel(second, smp, uv, 0.0).rgb;

    // The 16:9 canvas is cropped to fill the output, keeping its centre.
    let size = globals.size;
    let out_aspect = size.x / size.y;
    let canvas_aspect = CANVAS.x / CANVAS.y;
    var c = uv;
    if (canvas_aspect > out_aspect) {
        c.x = (uv.x - 0.5) * (out_aspect / canvas_aspect) + 0.5;
    } else {
        c.y = (uv.y - 0.5) * (canvas_aspect / out_aspect) + 0.5;
    }
    let q = c * CANVAS;
    // Canvas pixels per output pixel, for a one-output-pixel soft edge.
    let soft = max(CANVAS.y / size.y * select(canvas_aspect / out_aspect, 1.0, canvas_aspect > out_aspect), 0.5);

    let a = radians(TILT);
    let cs = cos(a);
    let sn = sin(a);
    // Tilted frame -> canvas, and its inverse.
    let rot = mat2x2f(vec2f(cs, sn), vec2f(-sn, cs));
    let t = vec2f(q.x * cs + q.y * sn, -q.x * sn + q.y * cs) - CENTRE;
    let half = vec2f(across_at(f), along_at(f));
    let d = max(abs(t.x) - half.x, abs(t.y) - half.y);
    let window = clamp(0.5 - d / soft, 0.0, 1.0);
    var col = mix(outgoing, incoming, window);

    // The overlay layer is drawn 1% larger about the canvas centre.
    let qo = (q - CANVAS * 0.5) / 1.01 + CANVAS * 0.5;
    let g = overlay(qo, f, rot);
    col = 1.0 - (1.0 - col) * (1.0 - vec3f(g));
    gpufx_write(id, vec4f(col, 1.0));
}
