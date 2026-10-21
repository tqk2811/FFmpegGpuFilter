// A glossy heart spins up from the bottom, bursts into a pink heart that floods the frame, then a soft heart-shaped hole opens onto the second clip while the little heart drops away.

// The animation is laid out on a square canvas of 45 frames at 25 fps (1.8 s), scaled to cover the output.
const FRAMES: f32 = 45.0;
// The clips swap behind the full pink cover at 1.0 s of the 1.8 s animation.
const SWAP_FRAME: f32 = 25.0;
const PI: f32 = 3.14159265;

// Signed distance to a heart whose bounding box is centred on the origin (y down), with width 1
// and the given width / height ratio. Built from a 45-degree square with two circles on its upper sides.
fn heart_dist(q: vec2f, ratio: f32) -> f32 {
    let x = abs(q.x) * 1.70711;
    let y = (0.5 / ratio - q.y) * 1.56066 * ratio;
    let r2 = 0.70711;
    let uw = vec2f((x + y) * r2, (y - x) * r2) - vec2f(0.5);
    let e = abs(uw) - vec2f(0.5);
    let d_square = length(max(e, vec2f(0.0))) + min(max(e.x, e.y), 0.0);
    let d_lobe = length(vec2f(x, y) - vec2f(0.35355, 1.06066)) - 0.5;
    return min(d_square, d_lobe) / 1.70711;
}

// Piecewise-linear lookup in a table of (frame, value) pairs sorted by frame.
fn track(keys: ptr<function, array<vec2f, 12>>, count: i32, f: f32) -> f32 {
    if (f <= (*keys)[0].x) { return (*keys)[0].y; }
    for (var i = 1; i < count; i++) {
        let b = (*keys)[i];
        if (f <= b.x) {
            let a = (*keys)[i - 1];
            return mix(a.y, b.y, (f - a.x) / max(b.x - a.x, 1e-4));
        }
    }
    return (*keys)[count - 1].y;
}

// Vertical centre of the small heart (canvas units, y down).
fn small_heart_y(f: f32) -> f32 {
    var k = array<vec2f, 12>(
        vec2f(0.0, 1.095), vec2f(3.0, 1.032), vec2f(5.0, 0.959), vec2f(7.0, 0.87), vec2f(9.0, 0.771),
        vec2f(12.0, 0.674), vec2f(14.0, 0.594), vec2f(16.0, 0.54), vec2f(27.0, 0.535), vec2f(35.0, 0.852),
        vec2f(39.0, 1.017), vec2f(44.0, 1.15));
    return track(&k, 12, f);
}

// Spin of the small heart about its vertical axis, in degrees (0 = facing the camera).
fn small_heart_turn(f: f32) -> f32 {
    var k = array<vec2f, 12>(
        vec2f(0.0, -165.0), vec2f(3.0, -130.0), vec2f(6.0, -100.0), vec2f(9.0, -50.0), vec2f(11.0, -45.0),
        vec2f(12.0, -40.0), vec2f(13.0, -34.0), vec2f(14.0, -27.0), vec2f(15.0, -18.0), vec2f(16.0, 0.0),
        vec2f(27.0, 0.0), vec2f(44.0, -191.0));
    return track(&k, 12, f);
}

// Width of the pink heart that grows out of the small one.
fn cover_width(f: f32) -> f32 {
    var k = array<vec2f, 12>(
        vec2f(17.4, 0.0), vec2f(18.0, 0.3), vec2f(19.0, 0.6), vec2f(20.0, 0.96), vec2f(21.0, 1.4),
        vec2f(22.0, 1.9), vec2f(23.0, 2.5), vec2f(24.0, 3.3), vec2f(25.0, 4.2), vec2f(26.0, 5.0),
        vec2f(27.0, 6.0), vec2f(45.0, 6.0));
    return track(&k, 12, f);
}

// Integer PCG hash; inputs are snapped to 1/16 steps first so tiny float
// differences between backends cannot change the result.
fn pcg(v: u32) -> u32 {
    let s = v * 747796405u + 2891336453u;
    let w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}

fn unit(h: u32) -> f32 {
    return f32(h >> 8u) * (1.0 / 16777216.0);
}

fn snap(x: f32) -> u32 {
    return bitcast<u32>(i32(round(x * 16.0)));
}

fn hash11(n: f32) -> f32 {
    return unit(pcg(snap(n)));
}

// Pink cover colour: a soft four-corner gradient.
fn cover_colour(s: vec2f) -> vec3f {
    let t = clamp(s, vec2f(0.0), vec2f(1.0));
    let top = mix(vec3f(200.0, 76.0, 102.0), vec3f(213.0, 87.0, 121.0), t.x);
    let bottom = mix(vec3f(212.0, 86.0, 120.0), vec3f(192.0, 70.0, 89.0), t.x);
    return mix(top, bottom, t.y) / 255.0;
}

// Thin light streaks flying outward from the centre; returns their coverage.
fn streaks(s: vec2f, f: f32, reach: f32) -> f32 {
    let rel = s - vec2f(0.5, 0.5);
    let r = length(rel);
    if (r < 0.03 || r > reach) { return 0.0; }
    let cells = 160.0;
    let ang = (atan2(rel.y, rel.x) + PI) / (2.0 * PI) * cells;
    let secs = max(f - 17.5, 0.0) / 25.0;
    var cover = 0.0;
    for (var layer = 0; layer < 2; layer++) {
        let shifted = ang + f32(layer) * 0.5;
        let cell = floor(shifted);
        let seed = cell + f32(layer) * 517.0;
        let keep = hash11(seed + 3.1);
        if (keep < 0.3) { continue; }
        let offset = (hash11(seed + 7.7) - 0.5) * 0.5;
        let across = (fract(shifted) - 0.5 - offset) * (2.0 * PI / cells) * r;
        let centre = fract(hash11(seed) + secs * (0.35 + 0.5 * hash11(seed + 1.9))) * 0.8 + 0.04;
        let half_len = 0.008 + 0.03 * centre * hash11(seed + 5.3);
        let along = abs(r - centre) / half_len;
        let line = (1.0 - smoothstep(0.0012, 0.0028, abs(across))) * (1.0 - smoothstep(0.0, 1.0, along));
        cover = max(cover, line * (0.55 + 0.45 * keep));
    }
    return cover;
}

// The small glossy heart: returns premultiplied colour and coverage.
fn small_heart(s: vec2f, f: f32) -> vec4f {
    let width = 0.232;
    let centre = vec2f(0.5, small_heart_y(f));
    let turn = cos(radians(small_heart_turn(f)));
    let side = 1.0 - smoothstep(0.0, 0.55, abs(turn));
    let squash = max(abs(turn), 0.59);
    let q = (s - centre) / width;
    let qs = vec2f(q.x / squash, q.y);
    let d_front = heart_dist(qs, 1.06) * squash;
    let d_side = (length(q / vec2f(0.29, 0.47)) - 1.0) * 0.29;
    let d = mix(d_front, d_side, side);
    let px = 1.5 / 800.0 / width;
    let alpha = 1.0 - smoothstep(-px, px, d);
    // Puffy shading from the distance to the edge.
    let e = 0.004;
    let dx = mix(heart_dist(qs + vec2f(e, 0.0), 1.06), length((q + vec2f(e, 0.0)) / vec2f(0.29, 0.47)) - 1.0, side)
        - mix(heart_dist(qs - vec2f(e, 0.0), 1.06), length((q - vec2f(e, 0.0)) / vec2f(0.29, 0.47)) - 1.0, side);
    let dy = mix(heart_dist(qs + vec2f(0.0, e), 1.06), length((q + vec2f(0.0, e)) / vec2f(0.29, 0.47)) - 1.0, side)
        - mix(heart_dist(qs - vec2f(0.0, e), 1.06), length((q - vec2f(0.0, e)) / vec2f(0.29, 0.47)) - 1.0, side);
    let g = vec2f(dx, dy) / max(length(vec2f(dx, dy)), 1e-5);
    let depth = clamp(-d / 0.16, 0.0, 1.0);
    let bulge = 1.0 - (1.0 - depth) * (1.0 - depth);
    let nxy = g * (1.0 - bulge) * 0.7;
    let n = vec3f(nxy, sqrt(max(1.0 - dot(nxy, nxy), 0.0)));
    let light = normalize(vec3f(-0.45, -0.6, 0.66));
    let diffuse = max(dot(n, light), 0.0);
    let spec = pow(max(dot(reflect(-light, n), vec3f(0.0, 0.0, 1.0)), 0.0), 18.0);
    let base = vec3f(250.0, 92.0, 150.0) / 255.0;
    var c = base * (0.78 + 0.3 * diffuse) + vec3f(1.0, 0.85, 0.9) * spec * 0.55;
    // Soft pink glow while the big heart bursts out of it.
    let glow_on = smoothstep(17.5, 18.5, f) * (1.0 - smoothstep(26.5, 28.0, f));
    let glow = glow_on * 0.3 * exp(-pow(max(d, 0.0) / 0.12, 2.0));
    let a = alpha + (1.0 - alpha) * glow;
    let col = c * alpha + vec3f(1.0, 0.6, 0.78) * glow * (1.0 - alpha);
    return vec4f(col, a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = params.progress;
    // Exact clips at the ends of the transition.
    if (p <= 0.0) {
        gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    if (p >= 1.0) {
        gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    // Shift by half a frame so the smooth motion is centred on the 25 fps source frames.
    let f = p * FRAMES - 0.5;
    let size = globals.size;
    let s = vec2f(0.5) + (uv - vec2f(0.5)) * size / max(size.x, size.y);

    var col = textureSampleLevel(first, smp, uv, 0.0).rgb;
    if (f >= SWAP_FRAME) {
        col = textureSampleLevel(second, smp, uv, 0.0).rgb;
    }

    // Pink heart flood: a heart that grows past the frame, then a feathered heart hole.
    let centre = vec2f(0.5, 0.52);
    let cw = cover_width(f);
    var cover = 0.0;
    if (cw > 1e-3) {
        let dc = heart_dist((s - centre) / cw, 1.2) * cw;
        let feather = 0.075 * cw;
        cover = 1.0 - smoothstep(-0.5 * feather, 0.5 * feather, dc);
    }
    let hw = 0.274 + 0.194 * (f - 27.0);
    if (hw > 1e-3) {
        let dh = heart_dist((s - vec2f(0.5, 0.527)) / hw, 1.17) * hw;
        let feather = 0.43 * hw;
        cover *= smoothstep(-0.5 * feather, 0.5 * feather, dh);
    }
    col = mix(col, cover_colour(s), cover);

    // Light streaks bursting outward.
    let shown = smoothstep(17.5, 18.5, f) * (1.0 - smoothstep(29.5, 31.5, f));
    if (shown > 0.0) {
        let reach = 0.16 + 0.6 * min(cw, 1.4);
        let st = streaks(s, f, reach) * shown;
        col = mix(col, vec3f(1.0, 0.82, 0.9), st);
    }

    let h = small_heart(s, f);
    col = col * (1.0 - h.a) + h.rgb;
    gpufx_write(id, vec4f(col, 1.0));
}
