// Pass 4 of CRT 2 Digital: a dim room with an old TV, the second clip on its screen, and the first clip's screen cut-out falling onto the floor in 3-D.

const SPAN: f32 = 2.5;
const HANDOFF: f32 = 0.96667;
// Distance of the comp camera (1000-px comp, 39.6 degree horizontal field of view).
const CAMERA_DIST: f32 = 1388.9;
// Drop shadow of the floor-bound copy: offset (layer px) and opacity.
const SHADOW_OFFSET: vec2f = vec2f(-39.9, 2.79);
const SHADOW_OPACITY: f32 = 0.55;

const SCREEN_MIN: vec2f = vec2f(344.0, 384.0);
const SCREEN_MAX: vec2f = vec2f(646.0, 610.0);
const SCREEN_RADIUS: f32 = 10.0;
const REST_CENTER: vec2f = vec2f(494.5, 497.0);
const FLOOR_Y: f32 = 668.0;

// Camera pull-back (video frames 0..16) and push-in (frames 53..69) at 30 fps.
const PULL_ZOOM = array<f32, 17>(4.6, 4.36, 4.04, 3.566, 3.088, 2.664, 2.305, 2.013, 1.779,
    1.504, 1.372, 1.261, 1.173, 1.106, 1.053, 1.018, 1.0);
const PULL_CX = array<f32, 17>(480.0, 480.0, 480.0, 481.0, 483.0, 485.0, 487.0, 488.5, 490.0,
    491.5, 492.0, 493.0, 493.5, 493.5, 494.0, 494.5, 494.5);
const PULL_CY = array<f32, 17>(494.0, 493.0, 488.5, 490.0, 491.0, 492.0, 493.5, 494.5, 495.0,
    496.0, 496.0, 496.5, 496.5, 497.0, 497.0, 497.0, 497.0);
const PUSH_ZOOM = array<f32, 17>(1.0, 1.018, 1.053, 1.106, 1.173, 1.261, 1.372, 1.588, 1.779,
    2.013, 2.305, 2.664, 3.088, 3.566, 4.04, 4.36, 4.6);
const PUSH_CX = array<f32, 17>(494.5, 494.5, 494.0, 493.5, 493.5, 493.0, 492.0, 491.0, 490.0,
    488.5, 487.0, 485.0, 483.0, 481.0, 480.0, 480.0, 480.0);
const PUSH_CY = array<f32, 17>(497.0, 497.0, 497.0, 497.0, 496.5, 496.5, 496.0, 495.5, 495.0,
    494.5, 493.5, 492.0, 491.0, 490.0, 488.5, 493.0, 494.0);

fn ramp(t: f32, t0: f32, t1: f32) -> f32 {
    return clamp((t - t0) / (t1 - t0), 0.0, 1.0);
}

// Zoom (z) and screen centre (xy) of the camera move at video frame f.
fn camera_at(f: f32) -> vec3f {
    if (f < 53.0) {
        let x = clamp(f, 0.0, 16.0);
        let i = min(u32(floor(x)), 15u);
        let w = x - f32(i);
        return vec3f(mix(PULL_CX[i], PULL_CX[i + 1u], w), mix(PULL_CY[i], PULL_CY[i + 1u], w),
            mix(PULL_ZOOM[i], PULL_ZOOM[i + 1u], w));
    }
    let x = clamp(f - 53.0, 0.0, 16.0);
    let i = min(u32(floor(x)), 15u);
    let w = x - f32(i);
    return vec3f(mix(PUSH_CX[i], PUSH_CX[i + 1u], w), mix(PUSH_CY[i], PUSH_CY[i + 1u], w),
        mix(PUSH_ZOOM[i], PUSH_ZOOM[i + 1u], w));
}

// Output uv -> square comp position (0..1); the comp covers the frame.
fn frame_to_comp(uv: vec2f) -> vec2f {
    let ratio = globals.size.x * globals.pixel_aspect / globals.size.y;
    if (ratio >= 1.0) { return vec2f(uv.x, 0.5 + (uv.y - 0.5) / ratio); }
    return vec2f(0.5 + (uv.x - 0.5) * ratio, uv.y);
}

// Signed distance to a rounded box given by corners.
fn box_dist(p: vec2f, lo: vec2f, hi: vec2f, r: f32) -> f32 {
    let c = (lo + hi) * 0.5;
    let d = abs(p - c) - ((hi - lo) * 0.5 - vec2f(r));
    return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0) - r;
}

fn fill(dist: f32, aa: f32) -> f32 {
    return 1.0 - smoothstep(-aa, aa, dist);
}

fn seg_dist(p: vec2f, a: vec2f, b: vec2f) -> f32 {
    let ab = b - a;
    let h = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
    return length(p - a - ab * h);
}

// Integer hash -> 0..1.
fn hash2(p: vec2i) -> f32 {
    var h = (u32(p.x) * 0x8da6b343u) ^ (u32(p.y) * 0xd8163841u);
    h = (h ^ (h >> 15u)) * 0x2c1b3c6du;
    h = (h ^ (h >> 12u)) * 0x297a2d39u;
    h = h ^ (h >> 15u);
    return f32(h & 0xffffffu) / 16777215.0;
}

fn value_noise(p: vec2f) -> f32 {
    let i = vec2i(floor(p));
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash2(i);
    let b = hash2(i + vec2i(1, 0));
    let c = hash2(i + vec2i(0, 1));
    let d = hash2(i + vec2i(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn grime(p: vec2f) -> f32 {
    return value_noise(p * 0.08) * 0.5 + value_noise(p * 0.3) * 0.3 + value_noise(p * 1.1) * 0.2;
}

// The room and the TV set, in comp pixels of the resting camera; `aa` is the pixel footprint there.
fn room(p: vec2f, aa: f32) -> vec3f {
    // Wall: cold blue-black at the top warming to a dark red near the floor.
    let wy = clamp(p.y / FLOOR_Y, 0.0, 1.0);
    var col = mix(vec3f(0.051, 0.075, 0.098), vec3f(0.105, 0.055, 0.06), wy * wy);
    col *= 0.9 + 0.2 * value_noise(p * 0.9);
    let halo = exp(-dot((p - vec2f(495.0, 520.0)) / vec2f(330.0, 240.0), (p - vec2f(495.0, 520.0)) / vec2f(330.0, 240.0)));
    col += vec3f(0.035, 0.025, 0.03) * halo;

    // Floor: dark maroon carpet lit by the screen, with a bright rim at the wall line.
    let on_floor = smoothstep(FLOOR_Y - aa, FLOOR_Y + aa, p.y);
    let fy = max(p.y - FLOOR_Y, 0.0);
    let sx = (p.x - 495.0) / 300.0;
    let spread = exp(-sx * sx);
    var floor_col = vec3f(0.12, 0.062, 0.066) * (0.85 + 0.3 * value_noise(p * 1.3));
    floor_col += vec3f(0.42, 0.2, 0.17) * spread * exp(-fy / 45.0);
    floor_col += vec3f(0.12, 0.05, 0.04) * exp(-fy / 12.0);
    floor_col *= 1.0 - 0.45 * smoothstep(60.0, 340.0, fy) * (1.0 - spread * 0.5);
    // Contact shadow below the set.
    floor_col *= 1.0 - 0.6 * exp(-fy / 10.0) * smoothstep(330.0, 400.0, p.x) * (1.0 - smoothstep(740.0, 800.0, p.x));
    col = mix(col, floor_col, on_floor);

    // Antennas.
    let ant = min(seg_dist(p, vec2f(643.0, 360.0), vec2f(612.0, 190.0)),
        seg_dist(p, vec2f(657.0, 360.0), vec2f(688.0, 175.0)));
    col = mix(col, vec3f(0.03, 0.03, 0.035), fill(ant - 1.2, aa));

    // Feet.
    let feet = min(box_dist(p, vec2f(340.0, 630.0), vec2f(385.0, 652.0), 3.0),
        box_dist(p, vec2f(705.0, 630.0), vec2f(750.0, 652.0), 3.0));
    col = mix(col, vec3f(0.02, 0.015, 0.015), fill(feet, aa));

    // Cabinet: worn dark brown with a lighter top edge.
    let body = box_dist(p, vec2f(322.0, 357.0), vec2f(770.0, 640.0), 14.0);
    let g = grime(p);
    var cab = vec3f(0.07, 0.052, 0.042) * (0.6 + 0.8 * g);
    cab += vec3f(0.09, 0.07, 0.055) * smoothstep(-6.0, 0.0, body) * (1.0 - smoothstep(0.0, 1.0, body));
    cab *= 1.0 - 0.35 * smoothstep(560.0, 640.0, p.y);
    col = mix(col, cab, fill(body, aa));

    // Metal bezel around the screen, with a bright inner lip.
    let bezel = box_dist(p, vec2f(332.0, 372.0), vec2f(658.0, 622.0), 16.0);
    var metal = vec3f(0.17, 0.15, 0.13) * (0.7 + 0.6 * g);
    let lip = abs(box_dist(p, vec2f(339.0, 379.0), vec2f(651.0, 615.0), 13.0));
    metal = mix(metal, vec3f(0.36, 0.32, 0.27), fill(lip - 1.5, aa));
    col = mix(col, metal, fill(bezel, aa));
    // Dark glass border just around the picture.
    col = mix(col, vec3f(0.02, 0.02, 0.022), fill(box_dist(p, vec2f(341.0, 381.0), vec2f(649.0, 613.0), 12.0), aa));

    // Control plate with two knobs, and a speaker grille below it.
    let plate = box_dist(p, vec2f(677.0, 381.0), vec2f(748.0, 514.0), 4.0);
    let brushed = 0.75 + 0.5 * value_noise(vec2f(p.x * 0.05, p.y * 1.5));
    col = mix(col, vec3f(0.23, 0.19, 0.14) * brushed, fill(plate, aa));
    let grille = box_dist(p, vec2f(672.0, 523.0), vec2f(752.0, 612.0), 3.0);
    let slat = smoothstep(0.35, 0.5, abs(fract(p.y / 6.0) - 0.5));
    col = mix(col, mix(vec3f(0.035, 0.028, 0.025), vec3f(0.09, 0.075, 0.06), slat), fill(grille, aa));
    for (var k = 0; k < 2; k++) {
        let c = vec2f(713.0, 414.0 + 60.0 * f32(k));
        let d = length(p - c);
        let shade = clamp(1.0 - d / 17.0, 0.0, 1.0);
        var knob = mix(vec3f(0.3, 0.26, 0.21), vec3f(0.78, 0.72, 0.62), shade * shade);
        knob *= 0.8 + 0.4 * clamp(dot(normalize(p - c + vec2f(1e-4)), vec2f(-0.6, -0.8)), 0.0, 1.0);
        let ang = select(-1.05, -0.8, k == 1);
        let dir = vec2f(cos(ang), sin(ang));
        let slot = seg_dist(p, c - dir * 13.0, c + dir * 13.0);
        knob = mix(knob, vec3f(0.06, 0.05, 0.045), fill(slot - 1.6, aa));
        col = mix(col, vec3f(0.03, 0.025, 0.02), fill(d - 19.0, aa));
        col = mix(col, knob, fill(d - 17.0, aa));
    }
    return col;
}

struct Layer {
    pos: vec3f,
    scale: f32,
    rot_x: f32,
    rot_y: f32,
    shadow: f32,
};

fn layer_at(t: f32) -> Layer {
    var l: Layer;
    if (t < HANDOFF) {
        l.pos = mix(vec3f(500.0, 500.0, 0.0), vec3f(500.0, 526.841, 1.912), ramp(t, 0.6, 0.7));
        l.pos = mix(l.pos, vec3f(500.0, 672.985, 25.544), ramp(t, 0.7, 1.1));
        l.scale = mix(mix(1.0, 1.056, ramp(t, 0.6, 0.7)), 0.93, ramp(t, 0.7, 1.1));
        l.rot_x = 112.0 * ramp(t, 0.6, 1.1);
        l.rot_y = 0.0;
        l.shadow = 0.0;
    } else {
        l.pos = mix(vec3f(500.0, 500.0, 0.0), vec3f(500.0, 672.985, 25.544), ramp(t, 0.6, 1.1));
        l.pos = mix(l.pos, vec3f(500.0, 1035.945, -599.755), ramp(t, 1.83333, 2.46667));
        l.scale = mix(0.64, 1.89, ramp(t, 1.83333, 2.46667));
        l.rot_x = 117.0 * ramp(t, 0.6, 1.1);
        l.rot_x = mix(l.rot_x, 107.13333, ramp(t, 1.1, 1.33333));
        l.rot_x = mix(l.rot_x, 120.13333, ramp(t, 1.33333, 1.6));
        l.rot_y = mix(1.0, 9.0, ramp(t, 0.96667, 1.1));
        l.rot_y = mix(l.rot_y, 18.0, ramp(t, 1.1, 1.33333));
        l.rot_y = mix(l.rot_y, -13.0, ramp(t, 1.33333, 1.6));
        l.shadow = 1.0;
    }
    return l;
}

// Rotate about X, then about Y (degrees; y points down, z away from the camera).
fn rotate(v: vec3f, ax: f32, ay: f32) -> vec3f {
    let a = radians(ax);
    let b = radians(ay);
    let r1 = vec3f(v.x, v.y * cos(a) - v.z * sin(a), v.y * sin(a) + v.z * cos(a));
    return vec3f(r1.x * cos(b) + r1.z * sin(b), r1.y, -r1.x * sin(b) + r1.z * cos(b));
}

fn sheet_sample(lq: vec2f) -> vec4f {
    if (any(lq < vec2f(0.0)) || any(lq > vec2f(1.0))) { return vec4f(0.0); }
    return textureSampleLevel(glowed, smp, lq, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }

    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let f = t * 30.0;
    let comp = frame_to_comp(uv) * 1000.0;
    let px = 1000.0 / min(globals.size.x, globals.size.y);

    // Background: room and set, seen through the moving camera.
    let cam = camera_at(f);
    let rest = REST_CENTER + (comp - cam.xy) / cam.z;
    let aa = px / cam.z;
    var col = room(rest, aa);

    // Second clip on the screen (not scaled, only cut out by the screen shape).
    let on_screen = fill(box_dist(rest, SCREEN_MIN, SCREEN_MAX, SCREEN_RADIUS), aa);
    col = mix(col, textureSampleLevel(second, smp, uv, 0.0).rgb, on_screen);

    // First clip's cut-out as a 3-D card (premultiplied), with its drop shadow.
    let l = layer_at(t);
    let ex = rotate(vec3f(l.scale, 0.0, 0.0), l.rot_x, l.rot_y);
    let ey = rotate(vec3f(0.0, l.scale, 0.0), l.rot_x, l.rot_y);
    let n = cross(ex, ey);
    let eye = vec3f(500.0, 500.0, -CAMERA_DIST);
    let ray = vec3f(comp, 0.0) - eye;
    let denom = dot(ray, n);
    if (abs(denom) > 1e-6) {
        let s = dot(l.pos - eye, n) / denom;
        if (s > 0.0) {
            let hit = eye + ray * s - l.pos;
            let local = vec2f(dot(hit, ex), dot(hit, ey)) / (l.scale * l.scale) + vec2f(500.0);
            let card = sheet_sample(local / 1000.0);
            var under = col;
            if (l.shadow > 0.0) {
                let sa = sheet_sample((local - SHADOW_OFFSET) / 1000.0).a;
                under = col * (1.0 - SHADOW_OPACITY * sa);
            }
            col = card.rgb + under * (1.0 - card.a);
        }
    }
    gpufx_write(id, vec4f(col, 1.0));
}
