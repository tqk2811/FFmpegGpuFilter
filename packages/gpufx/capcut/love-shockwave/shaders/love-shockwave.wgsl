// A glowing pixel-art heart grows from the centre of the first clip, carrying the second clip inside, until it fills the frame.

// The heart animation runs this many frames, evenly over `progress` (30 frames per second over 1.4667 s).
const FRAMES: i32 = 44;
// Columns and rows of the pixel-art heart.
const COLS: i32 = 15;
const ROWS: i32 = 14;
// The animation is laid out on a 512 x 512 square stretched over the frame; distances below are in its pixels.
const LAYOUT: f32 = 512.0;
// Number of drifting square sparks around the heart.
const SPARKS: i32 = 40;

// Heart width per animation frame, as a fraction of the frame width (the last frame covers everything).
var<private> WIDTHS: array<f32, 43> = array<f32, 43>(
    0.00000, 0.00200, 0.00420, 0.00879, 0.01259, 0.01761, 0.02310, 0.02939,
    0.03811, 0.04739, 0.05671, 0.06838, 0.08058, 0.09532, 0.11062, 0.12740,
    0.14673, 0.16641, 0.18729, 0.21080, 0.23817, 0.26398, 0.29148, 0.32806,
    0.36362, 0.40303, 0.44501, 0.49136, 0.54253, 0.59675, 0.65639, 0.72198,
    0.79110, 0.87015, 0.95711, 1.05276, 1.16241, 1.28348, 1.41716, 1.57077,
    1.73437, 1.91501, 2.11447
);

// Filled cells of each heart row, bit i = column i, top row first.
var<private> HEART_ROWS: array<u32, 14> = array<u32, 14>(
    0x0E38u, 0x1F7Cu, 0x3FFEu, 0x7FFFu, 0x7FFFu, 0x7FFFu, 0x3FFEu,
    0x3FFEu, 0x1FFCu, 0x0FF8u, 0x07F0u, 0x03E0u, 0x01C0u, 0x0080u
);

fn cell_filled(i: i32, j: i32) -> bool {
    if (i < 0 || i >= COLS || j < 0 || j >= ROWS) { return false; }
    return ((HEART_ROWS[j] >> u32(i)) & 1u) != 0u;
}

// Distance from `g` (grid units) to the axis-aligned cell (i, j).
fn cell_distance(g: vec2f, i: i32, j: i32) -> f32 {
    let lo = vec2f(f32(i), f32(j));
    let d = max(max(lo - g, g - (lo + 1.0)), vec2f(0.0));
    return length(d);
}

// Signed distance (layout pixels, negative inside) from `p` to the heart edge, the heart `cell` pixels per block.
// Cells are visited in square rings around the pixel's cell; a cell in ring r is at least r - 1 blocks away,
// so the search stops as soon as that bound cannot beat the best distance found (same result as a full scan).
fn heart_distance(p: vec2f, cell: f32) -> f32 {
    let g = p / cell + vec2f(f32(COLS) * 0.5, f32(ROWS) * 0.5);
    let gi = vec2i(floor(g));
    let inside = cell_filled(gi.x, gi.y);
    var best = 1e9;
    if (inside) {
        // Nearest empty cell, or the outside of the grid.
        best = min(min(g.x, f32(COLS) - g.x), min(g.y, f32(ROWS) - g.y));
    }
    // First ring that can touch the grid.
    let gap = max(max(-gi.x, gi.x - (COLS - 1)), max(-gi.y, gi.y - (ROWS - 1)));
    let r0 = max(gap, 0);
    for (var r = r0; r <= r0 + COLS + ROWS; r++) {
        if (f32(r - 1) >= best) { break; }
        let j0 = max(gi.y - r, 0);
        let j1 = min(gi.y + r, ROWS - 1);
        for (var j = j0; j <= j1; j++) {
            // Whole row on the ring's top and bottom, only the two side cells in between.
            if (abs(j - gi.y) == r) {
                for (var i = max(gi.x - r, 0); i <= min(gi.x + r, COLS - 1); i++) {
                    if (cell_filled(i, j) != inside) { best = min(best, cell_distance(g, i, j)); }
                }
            } else {
                let il = gi.x - r;
                let ir = gi.x + r;
                if (il >= 0 && cell_filled(il, j) != inside) { best = min(best, cell_distance(g, il, j)); }
                if (ir < COLS && cell_filled(ir, j) != inside) { best = min(best, cell_distance(g, ir, j)); }
            }
        }
    }
    if (inside) { return -best * cell; }
    return best * cell;
}

fn hash11(x: f32) -> f32 {
    return fract(sin(x * 91.3458) * 47453.5453);
}

// Faint white squares drifting outward while the heart grows; returns their opacity at `p`.
fn sparks(p: vec2f, frame: f32) -> f32 {
    var a = 0.0;
    for (var k = 0; k < SPARKS; k++) {
        let fk = f32(k);
        let born = 10.0 + 22.0 * hash11(fk + 1.3);
        let life = (frame - born) / 14.0;
        if (life <= 0.0 || life >= 1.0) { continue; }
        let ang = 6.2831853 * hash11(fk + 5.1);
        let r0 = 40.0 + 200.0 * hash11(fk + 9.7);
        let r = r0 * (1.0 + 0.8 * life);
        let c = vec2f(cos(ang), sin(ang)) * r;
        let half = 3.0 + 8.0 * hash11(fk + 3.3);
        let q = abs(p - c);
        let inside = clamp(half + 0.5 - max(q.x, q.y), 0.0, 1.0);
        let fade = sin(3.14159265 * life);
        a = max(a, inside * fade * (0.15 + 0.25 * hash11(fk + 7.9)));
    }
    return a;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    let frame = clamp(i32(floor(params.progress * f32(FRAMES) + 0.5)), 0, FRAMES - 1);
    // The last frame of the animation is the second clip everywhere.
    if (frame >= FRAMES - 1) { gpufx_write(id, vec4f(b, 1.0)); return; }
    let w = WIDTHS[frame];
    if (w <= 0.0) { gpufx_write(id, vec4f(a, 1.0)); return; }
    let p = (uv - 0.5) * LAYOUT;
    let d = heart_distance(p, w * LAYOUT / f32(COLS));
    let fill = clamp(0.5 - d, 0.0, 1.0);
    var col = mix(a, b, fill);
    // Neon outline on the heart edge: a white core, a pink rim and a wide soft glow.
    let ad = abs(d);
    let core = exp(-(ad / 3.6) * (ad / 3.6));
    let glow = 0.7 * exp(-ad / 17.0);
    let line_a = 1.0 - (1.0 - core) * (1.0 - glow);
    let rim = exp(-((ad - 3.5) / 1.5) * ((ad - 3.5) / 1.5));
    let line_rgb = vec3f(1.0, 1.0 - 0.16 * rim, 1.0);
    let spark = sparks(p, f32(frame));
    let over_a = 1.0 - (1.0 - line_a) * (1.0 - spark);
    let over_rgb = mix(vec3f(1.0), line_rgb, line_a / max(over_a, 1e-4));
    col = mix(col, over_rgb, over_a);
    gpufx_write(id, vec4f(col, 1.0));
}
