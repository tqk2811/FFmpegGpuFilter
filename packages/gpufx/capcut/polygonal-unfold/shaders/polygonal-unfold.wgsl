// Polygonal Unfold: a crumpled paper polygon pops up in the middle of the first clip, tears open onto the second clip and unfolds outwards until only flying corners are left.

// Animation timeline (seconds) played as progress goes 0 -> 1; it moves in 15 fps steps.
const TIMELINE: f32 = 1.96666;
const STEPS_PER_SEC: f32 = 15.0;
const PI: f32 = 3.14159265;
const CORNERS: u32 = 5u;

// Per step (frames 26..58 of the 30 fps sheet, every second frame): paper radius, opening
// radius (second clip shows inside it), hole radius in the paper (0 = none).
const KEY_COUNT: i32 = 17;
const PAPER_R = array<f32, 17>(0.04, 0.13, 0.22, 0.22, 0.24, 0.27, 0.27, 0.31, 0.33, 0.33, 0.34, 0.47, 0.47, 0.62, 0.68, 0.68, 0.0);
const OPEN_R = array<f32, 17>(0.03, 0.093, 0.16, 0.16, 0.16, 0.16, 0.16, 0.175, 0.185, 0.185, 0.245, 0.37, 0.37, 0.56, 0.62, 0.62, 2.0);
const HOLE_R = array<f32, 17>(0.0, 0.0, 0.0, 0.0, 0.0, 0.11, 0.11, 0.135, 0.15, 0.15, 0.2, 0.33, 0.33, 0.55, 0.62, 0.62, 0.0);

fn hash01(n: u32) -> f32 {
    var h = n * 747796405u + 2891336453u;
    h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
    h = (h >> 22u) ^ h;
    return f32(h & 0xffffffu) / 16777215.0;
}

// Inside test of an irregular polygon around the centre, `seed` picks the corner jitter.
// Returns a signed distance-like value (> 0 inside) in short-side units.
fn polygon(d: vec2f, radius: f32, seed: u32, step: u32, spin: f32) -> f32 {
    if (radius <= 0.0) { return -1.0; }
    var best = 1e9;
    for (var i = 0u; i < CORNERS; i++) {
        let j = (i + 1u) % CORNERS;
        let ai = (f32(i) + 0.35 * hash01(seed + i * 7u)) / f32(CORNERS) * 2.0 * PI + spin;
        let aj = (f32(j) + 0.35 * hash01(seed + j * 7u)) / f32(CORNERS) * 2.0 * PI + spin + select(0.0, 2.0 * PI, j == 0u);
        let ri = radius * (0.7 + 0.5 * hash01(seed + i * 13u + 1u) + 0.06 * hash01(step * 31u + i));
        let rj = radius * (0.7 + 0.5 * hash01(seed + j * 13u + 1u) + 0.06 * hash01(step * 31u + j));
        let pi = vec2f(cos(ai), sin(ai)) * ri;
        let pj = vec2f(cos(aj), sin(aj)) * rj;
        let e = pj - pi;
        let n = normalize(vec2f(e.y, -e.x));
        // Distance of d to the inner side of this edge (centre is inside every edge).
        best = min(best, -dot(d - pi, n) * sign(-dot(-pi, n) + 1e-9));
    }
    return best;
}

// Crumpled paper shading: faceted folds from a jittered cell pattern.
fn crumple(d: vec2f, step: u32) -> f32 {
    let g = d * 5.0;
    let c = floor(g);
    var near = 9.0;
    var second = 9.0;
    var shade = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let cell = c + vec2f(f32(x), f32(y));
            let k = u32(i32(cell.x) + 4096) * 7919u + u32(i32(cell.y) + 4096) * 104729u + step * 3u;
            let pt = cell + vec2f(hash01(k), hash01(k + 1u));
            let dd = length(g - pt);
            if (dd < near) { second = near; near = dd; shade = hash01(k + 2u); }
            else if (dd < second) { second = dd; }
        }
    }
    let crease = smoothstep(0.0, 0.05, second - near);
    return (0.9 + 0.09 * shade) * mix(0.9, 1.0, crease);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = params.progress;
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    // Exact clips at the ends of the transition.
    if (p <= 0.0) { gpufx_write(id, vec4f(a.rgb, 1.0)); return; }
    if (p >= 1.0) { gpufx_write(id, vec4f(b.rgb, 1.0)); return; }
    let frame = floor(p * TIMELINE * STEPS_PER_SEC) * 2.0;
    let k = i32(frame) / 2 - 13;
    if (k < 0) { gpufx_write(id, vec4f(a.rgb, 1.0)); return; }
    if (k >= KEY_COUNT - 1) { gpufx_write(id, vec4f(b.rgb, 1.0)); return; }
    let step = u32(k);
    let w = globals.size.x;
    let h = globals.size.y;
    let short_side = min(w, h);
    let d = (uv - 0.5) * vec2f(w, h) / short_side;
    // Late steps grow to the long side so the opening covers any frame shape.
    let reach = mix(1.0, max(w, h) / short_side, smoothstep(9.0, 13.0, f32(k)));
    let spin = 0.08 * (hash01(step * 5u + 3u) - 0.5) + 0.02 * f32(k);
    let paper = polygon(d, PAPER_R[k] * reach, 23u, step, spin + 0.2);
    let hole = polygon(d, HOLE_R[k] * reach, 37u, step, spin - 0.3);
    // The opening always covers the paper hole, so the first clip never peeks through it.
    let open = max(polygon(d, OPEN_R[k] * reach, 11u, step, spin), hole);
    var col = select(a.rgb, b.rgb, open > 0.0);
    // Soft contact shadow under the paper.
    let shadow = smoothstep(-0.02, 0.0, paper - 0.006) * select(1.0, smoothstep(0.02, 0.0, hole), HOLE_R[k] > 0.0);
    col *= 1.0 - 0.25 * shadow;
    if (paper > 0.0 && hole <= 0.0) {
        let edge = smoothstep(0.0, 0.006, paper) * smoothstep(0.0, 0.006, -hole + select(1.0, 0.0, HOLE_R[k] > 0.0));
        let tone = crumple(d / max(PAPER_R[k], 0.05) * 0.3, step / 2u);
        col = mix(col, vec3f(tone, tone, tone * 0.985), edge);
    }
    gpufx_write(id, vec4f(col, 1.0));
}
