// Spotlight, pass 3: cut the softened, mirrored clip to the light beam and brighten it.

const SPAN: f32 = 1.5999;
// Comp time at which the beam stops showing the second clip and starts showing the first.
const SWAP_AT: f32 = 0.8;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// At the ends the last pass shows the plain clips, so the passes before it have nothing to do.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0; }

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

// Keeps `v` before t0, eases from a to b between t0 and t1, holds b after.
fn key(v: f32, t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    if (t < t0) { return v; }
    if (t >= t1) { return b; }
    return mix(a, b, ease((t - t0) / (t1 - t0), c));
}

const LINEAR = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

// How far both clips (and the beam with them) have slid down, as a fraction of the frame height.
fn slide(t: f32) -> f32 {
    var v = key(0.0, t, 0.0, 0.8, 0.0, 0.5, vec4f(1.0, 0.0, 0.999, 0.478261));
    v = key(v, t, 0.8, 1.566667, 0.5, 1.0, vec4f(0.001, 0.5, 0.0, 1.0));
    return v;
}

// Beam picture: a triangle with its tip at the top centre (half width 0.6575 of the depth), drawn
// 1.3889 frame heights tall and stretched sideways from nothing, plus a solid sheet that rises
// from below to fill the frame at the clip switch.
const PICTURE: f32 = 1.3888889;
const SPREAD: f32 = 0.6575;

fn triangle_width(t: f32) -> f32 {
    var v = key(0.0, t, 0.0, 0.7, 0.0, 88.0, vec4f(1.0, 0.0315, 0.999, 1.0));
    v = key(v, t, 0.7, 0.8, 88.0, 100.0, LINEAR);
    v = key(v, t, 0.8, 0.9, 100.0, 88.0, LINEAR);
    v = key(v, t, 0.9, 1.566667, 88.0, 0.0, vec4f(0.001, 0.0, 0.0, 0.98));
    return v * 0.01 * PICTURE;
}

fn triangle_height(t: f32) -> f32 {
    var v = key(100.0, t, 0.7, 0.8, 100.0, 0.0, LINEAR);
    v = key(v, t, 0.8, 0.9, 0.0, 100.0, LINEAR);
    return v * 0.01 * PICTURE;
}

fn sheet_top(t: f32) -> f32 {
    let low = 1210.0 / 1080.0;
    var v = key(low, t, 0.7, 0.8, low, 0.0, LINEAR);
    v = key(v, t, 0.8, 0.9, 0.0, low, LINEAR);
    return v;
}

// Coverage of the beam picture at frame point p (x across, y down from the top), 0..1.
fn beam_cover(p: vec2f, t: f32) -> f32 {
    if (p.y < 0.0 || p.y > 1.0 || p.x < 0.0 || p.x > 1.0) { return 0.0; }
    let px = globals.size;
    let top = sheet_top(t);
    let sheet = clamp((p.y - top) * px.y + 0.5, 0.0, 1.0) * step(p.y, top + PICTURE);
    var tri = 0.0;
    let sx = triangle_width(t);
    let sy = triangle_height(t);
    if (sx > 1e-5 && sy > 1e-5) {
        let depth = p.y / sy;
        if (depth <= 1.0) {
            let dx = abs(p.x - 0.5) / sx;
            // Edge softness: one output pixel, or one picture texel when the picture is blown up.
            let span = sx * px.x;
            let soft = max(1.0, span / 1500.0);
            tri = clamp((SPREAD * depth - dx) * span / soft + 0.5, 0.0, 1.0) * step(dx, 0.5);
        }
    }
    return sheet + tri * (1.0 - sheet);
}

// Brightness curve: up first, slightly dark at the switch, up again, back to neutral.
fn brightness(t: f32) -> f32 {
    var v = key(1.0, t, 0.0, 0.8, 1.0, -0.3, LINEAR);
    v = key(v, t, 0.8, 1.4, -0.3, 1.0, vec4f(0.166666667, 0.166666667, 0.910652522, 1.0));
    v = key(v, t, 1.4, 1.566667, 1.0, 0.0, vec4f(0.29017766, 0.0, 0.618700905, 1.0));
    return v;
}

fn brighten(c: vec3f, amount: f32) -> vec3f {
    var k = amount;
    if (amount > 0.0 && amount <= 0.7) { k = 0.3 * amount; }
    else if (amount > 0.7) { k = 0.6333 * amount - 0.2333; }
    var x = c;
    var power: f32;
    if (k > 0.0) {
        power = k * 5.0 + 1.0;
    } else {
        x = c + vec3f(k * 0.01);
        power = 1.0 / (-k * 2.5 + 1.0);
    }
    return clamp(1.0 - pow(max(1.0 - x, vec3f(0.0)), vec3f(power)), vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let uv = gpufx_uv(id);
    let t = clock();
    let drop = slide(t);
    // The clip is mirrored upside down at 133 %; before the switch it hangs below the slide line
    // (second clip), after it stands above it (first clip). The beam picture follows the slide,
    // flipped upside down after the switch.
    var src: vec2f;
    var at: vec2f;
    if (t < SWAP_AT) {
        src = vec2f(0.5 + (uv.x - 0.5) / 1.33, 1.0 - (uv.y - drop) / 1.33);
        at = vec2f(uv.x, uv.y - drop);
    } else {
        src = vec2f(0.5 + (uv.x - 0.5) / 1.33, (drop - uv.y) / 1.33);
        at = vec2f(uv.x, drop - uv.y);
    }
    if (any(src < vec2f(0.0)) || any(src > vec2f(1.0))) { gpufx_write(id, vec4f(0.0)); return; }
    let c = textureSampleLevel(soft, smp, src, 0.0);
    let a = c.a * beam_cover(at, t);
    gpufx_write(id, vec4f(brighten(c.rgb * a, brightness(t)), a));
}
