// Target zoom, step 1: both clips swirl around the target point while a lens bulge zooms into it.

// The animation runs over this many seconds of timeline, whatever the real length.
const TIMELINE: f32 = 2.0;
// Target point in bottom-up texture space (x right, y up).
const TARGET: vec2f = vec2f(0.34074074, 0.45);
// Swirl radius as a fraction of the longer side, before the aspect boost.
const SWIRL_RADIUS: f32 = 0.15;

// CSS-like cubic-bezier easing through (0,0) (x1,y1) (x2,y2) (1,1), solved for x by bisection.
fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(e: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 22; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(e.x, e.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(e.y, e.w, 0.5 * (lo + hi));
}

// One keyframe segment: keeps `cur` before `t0`, eases from v0 to v1 inside, holds v1 after.
fn key(cur: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, e: vec4f) -> f32 {
    if (t < t0) { return cur; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(e, (t - t0) / (t1 - t0)));
}

const LINEAR = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

// Lens strength in degrees of field of view: up to 166 at the middle, back to 0.
fn lens_fov(t: f32) -> f32 {
    let e = vec4f(0.3333333, 0.0, 0.6666667, 1.0);
    var v = key(0.0, t, 0.5, 1.0, 0.0, 166.0, e);
    return key(v, t, 1.0, 1.5, 166.0, 0.0, e);
}

// Pincushion coefficients (r and r^2 terms) for a field-of-view fraction f in [0, 1].
fn lens_terms(f: f32) -> vec2f {
    let lo = 150.0 / 180.0;
    let mid = 178.0 / 180.0;
    let hi = 179.9 / 180.0;
    var k1 = 14.77 * pow(f, 10.0) + 2.7 * pow(f, 3.0);
    let k2 = 3.82 * pow(f, 2.54) + 0.529 * f;
    if (f > lo) {
        if (f < mid) {
            k1 = 218.48 * pow(f, 73.79) - 54.266 + 69.83 * f;
        } else if (f < hi) {
            k1 = pow(658.399 * (f - mid), 4.0) + 110.58;
        } else {
            k1 = pow(33162.0 * (f - hi), 4.0) + 2443.4;
        }
    }
    return vec2f(k1, k2);
}

// Folds a coordinate back into [0, 1] like a mirror.
fn fold(x: f32) -> f32 {
    let a = abs(x);
    return abs(floor(ceil(a) * 0.5) * 2.0 - a);
}

// Reads a clip at a bottom-up coordinate after swirling it `deg` degrees around the target.
fn swirled(tex: texture_2d<f32>, g: vec2f, deg: f32, aspect: f32) -> vec4f {
    var d = g - TARGET;
    if (aspect < 1.0) { d.x *= aspect; } else { d.y /= aspect; }
    let boost = mix(1.0, 1.25, smoothstep(0.0, 0.45, 1.7777778 / max(aspect, 1.0 / aspect) - 1.0));
    let radius = SWIRL_RADIUS * boost;
    let dist = length(d);
    if (dist < radius) {
        let a = (1.0 - smoothstep(0.0, 1.0, dist / radius)) * radians(deg);
        let s = sin(a);
        let c = cos(a);
        d = vec2f(c * d.x - s * d.y, s * d.x + c * d.y);
    }
    if (aspect < 1.0) { d.x /= aspect; } else { d.y *= aspect; }
    let q = d + TARGET;
    if (q.x < 0.0 || q.x > 1.0 || q.y < 0.0 || q.y > 1.0) { return vec4f(0.0); }
    return vec4f(textureSampleLevel(tex, smp, vec2f(q.x, 1.0 - q.y), 0.0).rgb, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * TIMELINE;
    let aspect = globals.size.x / globals.size.y;

    // Lens: pull every pixel towards the target, mirrored at the borders.
    var g = vec2f(uv.x, 1.0 - uv.y);
    let terms = lens_terms(clamp(lens_fov(t), 0.0, 180.0) / 180.0);
    let off = g - TARGET;
    let r = length(off * vec2f(1.0, globals.size.y / globals.size.x));
    g = TARGET + off / (1.0 + terms.x * r + terms.y * r * r);
    g = vec2f(fold(g.x), fold(g.y));

    // Swirl angles and the short crossfade around the middle.
    let spin_out = key(0.0, t, 0.6666667, 1.0, 0.0, 360.0, vec4f(0.3333333, 0.0, 0.8333333, 0.8333333));
    let spin_in = key(-360.0, t, 1.0, 1.3333333, -360.0, 0.0, vec4f(0.1666667, 0.1666667, 0.6666667, 1.0));
    let fade = key(0.0, t, 0.9333333, 1.0666667, 0.0, 1.0, LINEAR);

    var acc = vec4f(0.0);
    if (fade > 0.0) { acc = swirled(second, g, spin_in, aspect) * fade; }
    if (fade < 1.0) {
        let top = swirled(first, g, spin_out, aspect) * (1.0 - fade);
        acc = top + acc * (1.0 - top.a);
    }
    // Premultiplied colour; the next pass treats it as already composited over black.
    gpufx_write(id, acc);
}
