// A pixel-art curtain of pink hearts climbs up over the first clip in stop-motion steps, then leaves upward over the second.

// The curtain is drawn in a 720x1280 portrait board that is scaled to cover the frame.
const BOARD = vec2f(720.0, 1280.0);
// Length of the whole animation (s), its frame rate and the time the second clip takes over.
const SPAN = 2.0;
const FPS = 30.0;
const SWAP_TIME = 1.0333333;
// Size of one art pixel, in board pixels.
const DOT = 4.0;
// Heart grid: column pitch, row pitch, first column centre, top margin above the first row.
const PITCH_X = 185.5;
const PITCH_Y = 160.0;
const COL0 = 173.0;
const TOP_GAP = 12.0;
// Heart size in board pixels (half width, full height).
const HALF_W = 79.0;
const HEIGHT = 150.0;
// Sheet length from its top to the tips of its lower zigzag, and the zigzag depth.
const SHEET_LEN = 1970.0;
const TOOTH = 101.0;

// Top of the sheet (board px) for each held pose; one pose lasts four animation frames.
const POSES = array<f32, 15>(
    1110.0, 910.0, 710.0, 510.0, 310.0, 110.0, -90.0, -290.0,
    -490.0, -690.0, -890.0, -1090.0, -1323.0, -1590.0, -1857.0
);

const INK = vec3f(147.0, 67.0, 85.0) / 255.0;
const RIM = vec3f(237.0, 128.0, 151.0) / 255.0;
const BODY = vec3f(255.0, 163.0, 181.0) / 255.0;
const SHINE = vec3f(255.0, 203.0, 213.0) / 255.0;
const CHECK_A = vec3f(213.0, 98.0, 138.0) / 255.0;
const CHECK_B = vec3f(239.0, 174.0, 194.0) / 255.0;

// Signed distance (board px, negative inside) to the heart outline, from the implicit curve
// (x^2 + y^2 - 1)^3 - x^2 y^3 = 0 stretched to the heart size.
fn heart_distance(p: vec2f) -> f32 {
    let sy = HEIGHT / 2.236;
    let x = p.x / HALF_W;
    let y = 1.236 - p.y / sy;
    let a = x * x + y * y - 1.0;
    let f = a * a * a - x * x * y * y * y;
    let gx = (6.0 * x * a * a - 2.0 * x * y * y * y) / HALF_W;
    let gy = (6.0 * y * a * a - 3.0 * x * x * y * y) / sy;
    return f / max(length(vec2f(gx, gy)), 1e-4);
}

// Colour of the curtain at a sheet-local point (origin at the sheet's top-left corner).
fn sheet_color(local: vec2f) -> vec3f {
    let cell = floor(local / DOT);
    let c = (cell + 0.5) * DOT;
    let col = round((c.x - COL0) / PITCH_X);
    let row = floor((c.y - TOP_GAP) / PITCH_Y);
    let h = vec2f(c.x - (COL0 + col * PITCH_X), c.y - TOP_GAP - row * PITCH_Y);
    var color = select(CHECK_B, CHECK_A, (i32(cell.x) + i32(cell.y)) % 2 == 0);
    if (row < 0.0 || h.y > HEIGHT + DOT) { return color; }
    let d = heart_distance(h);
    if (d <= 0.0) {
        color = INK;
        if (d < -6.0) { color = RIM; }
        if (d < -12.0) {
            color = BODY;
            // Crescent highlight on the left lobe.
            let n = vec2f(h.x / HALF_W, h.y / HEIGHT);
            let inner = length((n - vec2f(-0.52, 0.27)) / vec2f(1.0, 0.85)) < 0.24;
            let cut = length((n - vec2f(-0.34, 0.20)) / vec2f(1.0, 0.85)) < 0.22;
            if (inner && !cut) { color = SHINE; }
        }
    }
    return color;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;

    // The clips cut over while the curtain covers the whole frame.
    var color = textureSampleLevel(first, smp, uv, 0.0).rgb;
    if (t >= SWAP_TIME) { color = textureSampleLevel(second, smp, uv, 0.0).rgb; }

    // Animation frame, sampled half a frame late like a held image sequence.
    let frame = i32(floor(t * FPS + 0.5));
    if (frame >= 1 && frame <= 59) {
        let top = POSES[min((frame - 1) / 4, 14)];
        let size = globals.size;
        let fit = max(size.x / BOARD.x, size.y / BOARD.y);
        let board = (uv * size - 0.5 * size) / fit + 0.5 * BOARD;
        let local = board - vec2f(0.0, top);
        let q = (floor(local / DOT) + 0.5) * DOT;
        // Scalloped upper edge: small notches at heart clefts and between hearts.
        let notch = abs(fract((q.x - COL0 + 0.5 * PITCH_X) / (0.5 * PITCH_X) + 0.5) - 0.5) * 0.5 * PITCH_X;
        let upper = max(0.0, 19.0 - notch * 19.0 / 15.0);
        // Zigzag lower edge with its tips under the heart columns.
        let off = abs(fract((q.x - COL0) / PITCH_X + 0.5) - 0.5) * 2.0;
        let lower = SHEET_LEN - TOOTH * off;
        if (q.y >= upper && q.y <= lower) {
            color = sheet_color(local);
        }
    }
    gpufx_write(id, vec4f(color, 1.0));
}
