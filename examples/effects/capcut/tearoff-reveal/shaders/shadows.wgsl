// Tearoff Reveal: a perforated strip is torn down the middle of the first clip, then the two halves peel away to the sides, uncovering the second clip.

// The whole animation runs on a 1.73333 s timeline driven by `progress`.
const TIMELINE: f32 = 1.73332;
const PI: f32 = 3.14159265;
// Comp-space edges of the three paper pieces (left, centre strip, right), in 0..1 of the width.
const CUT_L: f32 = 0.455556;
const CUT_R: f32 = 0.544444;

// Cubic Bezier easing through (0,0), (c.x,c.y), (c.z,c.w), (1,1): x is solved by bisection.
fn ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
        let m = 0.5 * (lo + hi);
        let n = 1.0 - m;
        let bx = 3.0 * n * n * m * c.x + 3.0 * n * m * m * c.z + m * m * m;
        if (bx > x) { hi = m; } else { lo = m; }
    }
    let s = 0.5 * (lo + hi);
    let n = 1.0 - s;
    return 3.0 * n * n * s * c.y + 3.0 * n * s * s * c.w + s * s * s;
}

// Value moving from a to b between times t0 and t1 along the curve, held outside that span.
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, ease(x, c));
}

const STRAIGHT = vec4f(0.166667, 0.166667, 0.833333, 0.833333);

// 1 inside the unit square, 0 outside.
fn in_unit(p: vec2f) -> f32 {
    return step(0.0, p.x) * step(p.x, 1.0) * step(0.0, p.y) * step(p.y, 1.0);
}

// Line a*x + b*y + c = 0 through two points.
fn line_of(p: vec2f, q: vec2f) -> vec3f {
    return vec3f(p.y - q.y, q.x - p.x, p.x * q.y - p.y * q.x);
}

// Mirror image of a point across a line.
fn mirror_across(p: vec2f, l: vec3f) -> vec2f {
    let aa = l.x * l.x;
    let bb = l.y * l.y;
    let n = max(aa + bb, 1e-12);
    return vec2f(((bb - aa) * p.x - 2.0 * l.x * (l.y * p.y + l.z)) / n,
                 ((aa - bb) * p.y - 2.0 * l.y * (l.x * p.x + l.z)) / n);
}

// Keeps a divisor away from zero without changing its sign.
fn nonzero(d: f32) -> f32 {
    return select(d, select(-1e-12, 1e-12, d >= 0.0), abs(d) < 1e-12);
}

// Where a pixel of a rolling page reads its two faces.
struct Roll {
    page_pt: vec2f,  // point of the page face (flat part or the rolled cylinder)
    page_w: f32,
    flat: f32,       // 1 on the side of the crease the page still lies on
    cyl_keep: f32,
    back_pt: vec2f,  // point of the flipped-over face
    back_w: f32,
};

// Page curl in bottom-up coordinates: the crease passes through `pos` at `dir_deg`, the page
// corner on the far side rolls over a cylinder of the given radius.
fn page_roll(q: vec2f, pos: vec2f, dir_deg: f32, radius: f32) -> Roll {
    let r = (dir_deg + 1e-7) / 180.0 * PI;
    var corner = vec2f(select(0.0, 1.0, sin(r) < 0.0), select(0.0, 1.0, cos(r) < 0.0));
    let guide = pos + vec2f(cos(r), -sin(r));
    let tip = mirror_across(corner, line_of(guide, pos)) + vec2f(1e-8);
    if (corner.y >= 1.0) { corner.y = max(tip.y + 0.001, corner.y); }
    if (corner.y <= 0.0) { corner.y = min(tip.y - 0.001, corner.y); }
    if (corner.x >= 1.0) { corner.x = max(tip.x + 0.001, corner.x); }
    if (corner.x <= 0.0) { corner.x = min(tip.x - 0.001, corner.x); }
    let rad = max(radius, 1e-8);
    let quarter = PI * rad * 0.5;
    let mid = (corner + tip) * 0.5;
    let axis = line_of(corner, tip);
    let crease = vec3f(axis.y, -axis.x, axis.x * mid.y - axis.y * mid.x);
    let span = max(length(crease.xy), 1e-12);
    let side = sign(axis.y) * sign(1e-8 - axis.x);
    var ea = vec2f(-(crease.z + crease.y * corner.y) / nonzero(crease.x + 1e-8), corner.y);
    var eb = vec2f(corner.x, -(crease.z + crease.x * corner.x) / nonzero(crease.y + 1e-8));
    if (side > 0.0) {
        let tmp = ea;
        ea = eb;
        eb = tmp;
    }
    let d0 = ea - eb;
    let d1 = ea - q;
    let flat = select(0.0, 1.0, d0.x * d1.y - d0.y * d1.x > 0.0);
    let dist = abs(dot(crease.xy, q) + crease.z) / span;
    let in_cyl = step(dist, rad + 0.001);
    let away_raw = corner - tip;
    let away = away_raw / max(length(away_raw), 1e-12);
    let arc = asin(min(dist / rad, 1.0)) * in_cyl * rad;
    let cyl = clamp(q + away * (arc - dist), vec2f(-10.0), vec2f(10.0));
    var out: Roll;
    out.page_pt = select(cyl * in_unit(cyl), q, flat > 0.5);
    out.page_w = clamp(flat + in_unit(cyl), 0.0, 1.0);
    out.flat = flat;
    out.cyl_keep = step(dist, rad + 1e-4);
    let fold_line = vec3f(crease.xy, crease.z + quarter * span);
    let m0 = mirror_across(q, fold_line);
    let m1 = mirror_across(cyl, fold_line);
    let pick = in_unit(m1) * (1.0 - flat) * in_cyl;
    out.back_pt = mix(m0, m1, pick);
    out.back_w = clamp(pick + flat * in_unit(m0), 0.0, 1.0);
    return out;
}

// Page face colour from its sampled colour `b` (already weighted by page_w).
fn page_face(b: vec4f, g: Roll) -> vec4f {
    let kept = b * g.cyl_keep;
    return mix(b * g.flat, kept, kept.a);
}

// Left piece: crease sweeping left (page and its shadow use different curves).
fn left_pos(t: f32, shadow: bool) -> vec2f {
    let c = select(vec4f(0.001, 0.0, 0.36, 0.64), vec4f(0.65, 0.35, 0.999, 1.0), shadow);
    return vec2f(keyed(t, 1.066667, 1.5, 0.759259, -0.462963, c), 0.5);
}
fn left_dir(t: f32) -> f32 {
    return keyed(t, 1.066667, 1.5, -50.0, -90.0, vec4f(0.001, 0.0, 0.65, 0.15));
}
// Right piece: crease sweeping right.
fn right_pos(t: f32, shadow: bool) -> vec2f {
    let c = select(vec4f(0.001, 0.0, 0.35, 0.935), STRAIGHT, shadow);
    return vec2f(keyed(t, 1.266667, 1.7, 0.240741, 1.462963, c), 0.5);
}
fn right_dir(t: f32) -> f32 {
    return keyed(t, 1.266667, 1.7, 50.0, 90.0, vec4f(0.001, 0.0, 0.67, 0.359286));
}

// Keys of the centre strip as it is torn off downwards (shared times).
const STRIP_T = array<f32, 13>(0.133333, 0.233333, 0.3, 0.366667, 0.466667, 0.533333, 0.6,
    0.7, 0.766667, 0.833333, 0.933333, 1.0, 1.066667);
// Height of the tear line (bottom-up).
const STRIP_Y = array<f32, 13>(0.937369, 0.877190, 0.834310, 0.789090, 0.716416, 0.664294,
    0.608732, 0.517564, 0.450196, 0.375833, 0.245132, 0.136680, -0.009259);
// Vertical position (comp pixels, top-down, centre at 540) of the strip's paper backing.
const STRIP_BACKING = array<f32, 13>(-285.0, -268.0, -238.0, -192.0, -113.0, -50.0, 9.0,
    122.0, 197.0, 291.0, 450.0, 586.0, 694.0);
const STRIP_CURVE = vec4f(0.8, 0.2, 0.8, 0.2);
// Strip lifetime on the timeline.
const STRIP_END: f32 = 1.066667;

fn strip_seg(t: f32) -> i32 {
    var k = 0;
    for (var i = 1; i < 12; i++) {
        if (t >= STRIP_T[i]) { k = i; }
    }
    return k;
}

fn strip_pos(t: f32) -> vec2f {
    var y: f32;
    if (t < 0.066667) {
        y = keyed(t, 0.0, 0.066667, 1.009259, 0.974713, vec4f(0.52, 0.15, 0.86, 0.49));
    } else if (t < 0.133333) {
        y = keyed(t, 0.066667, 0.133333, 0.974713, 0.937369, vec4f(0.63, 0.2, 0.82, 0.4));
    } else {
        let k = strip_seg(t);
        y = keyed(t, STRIP_T[k], STRIP_T[k + 1], STRIP_Y[k], STRIP_Y[k + 1], STRIP_CURVE);
    }
    return vec2f(0.5, y);
}

fn strip_backing_y(t: f32) -> f32 {
    let k = strip_seg(t);
    return keyed(t, STRIP_T[k], STRIP_T[k + 1], STRIP_BACKING[k], STRIP_BACKING[k + 1], STRIP_CURVE);
}

fn strip_dir(t: f32) -> f32 {
    if (t < 0.266667) {
        return keyed(t, 0.0, 0.266667, 181.0, 175.0, vec4f(0.349037, 0.0, 0.420485, 1.0));
    }
    if (t < 0.666667) {
        return keyed(t, 0.266667, 0.666667, 175.0, 178.53283, vec4f(0.38421, 0.0, 0.680652, 1.0));
    }
    return keyed(t, 0.666667, 1.066667, 178.53283, 176.0, vec4f(0.342368, 0.0, 0.678219, 0.55152));
}

fn strip_radius(t: f32) -> f32 {
    if (t < 0.366667) {
        return keyed(t, 0.0, 0.366667, 0.02, 0.04, vec4f(0.455789, 0.0, 0.690415, 1.0));
    }
    return keyed(t, 0.366667, 1.066667, 0.04, 0.0, vec4f(0.251324, 0.0, 0.682529, 0.250263));
}

fn strip_mask(p: vec2f) -> f32 {
    return select(0.0, 1.0, p.x >= CUT_L && p.x < CUT_R);
}

fn left_mask(p: vec2f) -> f32 { return select(0.0, 1.0, p.x < CUT_L && p.x >= 0.0); }
fn right_mask(p: vec2f) -> f32 { return select(0.0, 1.0, p.x >= CUT_R && p.x <= 1.0); }

// Coverage of a rolled solid piece (both faces).
fn rolled_cover(g: Roll, page_m: f32, back_m: f32) -> f32 {
    let page = page_face(vec4f(page_m * g.page_w), g).a;
    let back = back_m * g.back_w;
    return mix(page, back, back);
}

// Shadow shapes before blurring: r = right half, g = left half, b = flap of the strip.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let q = vec2f(uv.x, 1.0 - uv.y);
    let t = params.progress * TIMELINE;
    var s = vec3f(0.0);
    if (t <= 1.7) {
        let g = page_roll(q, right_pos(t, true), right_dir(t), 0.45);
        s.r = rolled_cover(g, right_mask(g.page_pt), right_mask(g.back_pt)) * in_unit(q);
    }
    if (t <= 1.5) {
        let g = page_roll(q, left_pos(t, true), left_dir(t), 0.45);
        s.g = rolled_cover(g, left_mask(g.page_pt), left_mask(g.back_pt)) * in_unit(q);
    }
    if (t <= STRIP_END) {
        let g = page_roll(q, strip_pos(t), strip_dir(t), strip_radius(t));
        s.b = strip_mask(g.back_pt) * g.back_w * in_unit(q);
    }
    gpufx_write(id, vec4f(s, 1.0));
}
