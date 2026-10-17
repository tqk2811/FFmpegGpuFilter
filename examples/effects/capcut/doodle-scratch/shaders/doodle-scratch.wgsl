// Doodle Scratch: chalk doodles and scratched photo cut-outs jolt the first clip, then the second clip shows through the cut-outs and takes over.

// The animation runs over two seconds of scene time, 30 frames a second.
const SPAN: f32 = 2.0;

// Cut-out shapes of the displacement map, traced per frame in a 278 x 512 portrait board
// (0..1, y down) that covers the output. FRAME_SHAPES: (first shape, count); SHAPES: (first
// corner, corner count, grey level); BACKDROP: grey of the rest of the map; VEIL: grey of the
// dusty chalk layer laid over everything.
const FRAME_SHAPES = array<vec2i, 60>(vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 0), vec2i(0, 1), vec2i(1, 1), vec2i(2, 1), vec2i(3, 1), vec2i(4, 2), vec2i(6, 2), vec2i(8, 2), vec2i(10, 3), vec2i(13, 3), vec2i(16, 1), vec2i(17, 1), vec2i(18, 2), vec2i(20, 2), vec2i(22, 1), vec2i(23, 1), vec2i(24, 1), vec2i(25, 1), vec2i(26, 1), vec2i(27, 1), vec2i(28, 1), vec2i(29, 1), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0), vec2i(30, 0));
const SHAPES = array<vec3f, 30>(vec3f(0.0, 6.0, 0.0000), vec3f(6.0, 6.0, 0.0000), vec3f(12.0, 6.0, 0.0000), vec3f(18.0, 6.0, 0.0000), vec3f(24.0, 8.0, 0.0000), vec3f(32.0, 5.0, 1.0000), vec3f(37.0, 8.0, 0.0000), vec3f(45.0, 5.0, 1.0000), vec3f(50.0, 8.0, 0.0000), vec3f(58.0, 5.0, 1.0000), vec3f(63.0, 8.0, 0.0000), vec3f(71.0, 8.0, 0.2510), vec3f(79.0, 8.0, 1.0000), vec3f(87.0, 8.0, 0.0000), vec3f(95.0, 8.0, 0.2510), vec3f(103.0, 8.0, 1.0000), vec3f(111.0, 5.0, 0.2510), vec3f(116.0, 5.0, 0.2510), vec3f(121.0, 5.0, 0.1569), vec3f(126.0, 5.0, 0.2510), vec3f(131.0, 5.0, 0.1569), vec3f(136.0, 5.0, 0.2510), vec3f(141.0, 4.0, 0.0627), vec3f(145.0, 4.0, 0.0627), vec3f(149.0, 4.0, 0.0627), vec3f(153.0, 4.0, 0.0627), vec3f(157.0, 4.0, 0.0627), vec3f(161.0, 6.0, 0.1569), vec3f(167.0, 6.0, 0.1569), vec3f(173.0, 6.0, 0.1569));
const CORNERS = array<vec2f, 179>(vec2f(0.1511, 0.1523), vec2f(0.1331, 0.3770), vec2f(0.5647, 0.3848), vec2f(0.9029, 0.3848), vec2f(0.9101, 0.1621), vec2f(0.6439, 0.1562), vec2f(0.1511, 0.1523), vec2f(0.1331, 0.3770), vec2f(0.5647, 0.3848), vec2f(0.9029, 0.3848), vec2f(0.9101, 0.1621), vec2f(0.6439, 0.1562), vec2f(0.1511, 0.1523), vec2f(0.1331, 0.3770), vec2f(0.5647, 0.3848), vec2f(0.9029, 0.3848), vec2f(0.9101, 0.1621), vec2f(0.6439, 0.1562), vec2f(0.1511, 0.1523), vec2f(0.1331, 0.3770), vec2f(0.5647, 0.3848), vec2f(0.9029, 0.3848), vec2f(0.9101, 0.1621), vec2f(0.6439, 0.1562), vec2f(0.1511, 0.1523), vec2f(0.1331, 0.3770), vec2f(0.4712, 0.3828), vec2f(0.4712, 0.2402), vec2f(0.8669, 0.2520), vec2f(0.8813, 0.3867), vec2f(0.9029, 0.3848), vec2f(0.9101, 0.1621), vec2f(0.4820, 0.2422), vec2f(0.4820, 0.4277), vec2f(0.8777, 0.4473), vec2f(0.8633, 0.2578), vec2f(0.7698, 0.2520), vec2f(0.1511, 0.1523), vec2f(0.1331, 0.3770), vec2f(0.4712, 0.3828), vec2f(0.4712, 0.2402), vec2f(0.8669, 0.2520), vec2f(0.8813, 0.3867), vec2f(0.9029, 0.3848), vec2f(0.9101, 0.1621), vec2f(0.4820, 0.2422), vec2f(0.4820, 0.4277), vec2f(0.8777, 0.4473), vec2f(0.8633, 0.2578), vec2f(0.7698, 0.2520), vec2f(0.1511, 0.1523), vec2f(0.1331, 0.3770), vec2f(0.4712, 0.3828), vec2f(0.4712, 0.2402), vec2f(0.8669, 0.2520), vec2f(0.8813, 0.3867), vec2f(0.9029, 0.3848), vec2f(0.9101, 0.1621), vec2f(0.4820, 0.2422), vec2f(0.4820, 0.4277), vec2f(0.8777, 0.4473), vec2f(0.8633, 0.2578), vec2f(0.7698, 0.2520), vec2f(0.1511, 0.1523), vec2f(0.1475, 0.2051), vec2f(0.4856, 0.2051), vec2f(0.4892, 0.2363), vec2f(0.8669, 0.2520), vec2f(0.8813, 0.3867), vec2f(0.9029, 0.3848), vec2f(0.9101, 0.1621), vec2f(0.0612, 0.2109), vec2f(0.0324, 0.7285), vec2f(0.4640, 0.7227), vec2f(0.4748, 0.5703), vec2f(0.4748, 0.2578), vec2f(0.4820, 0.2383), vec2f(0.4820, 0.2090), vec2f(0.2194, 0.2070), vec2f(0.4856, 0.2441), vec2f(0.4856, 0.4277), vec2f(0.5216, 0.4316), vec2f(0.6583, 0.4355), vec2f(0.8777, 0.4473), vec2f(0.8633, 0.2578), vec2f(0.7194, 0.2500), vec2f(0.4964, 0.2422), vec2f(0.1511, 0.1523), vec2f(0.1475, 0.2051), vec2f(0.4856, 0.2051), vec2f(0.4892, 0.2363), vec2f(0.8669, 0.2520), vec2f(0.8813, 0.3867), vec2f(0.9029, 0.3848), vec2f(0.9101, 0.1621), vec2f(0.0612, 0.2109), vec2f(0.0324, 0.7285), vec2f(0.4640, 0.7227), vec2f(0.4748, 0.5703), vec2f(0.4748, 0.2578), vec2f(0.4820, 0.2383), vec2f(0.4820, 0.2090), vec2f(0.2194, 0.2070), vec2f(0.4856, 0.2441), vec2f(0.4856, 0.4277), vec2f(0.5216, 0.4316), vec2f(0.6583, 0.4355), vec2f(0.8777, 0.4473), vec2f(0.8633, 0.2578), vec2f(0.7194, 0.2500), vec2f(0.4964, 0.2422), vec2f(0.0612, 0.2109), vec2f(0.0324, 0.7285), vec2f(0.4640, 0.7227), vec2f(0.4748, 0.5703), vec2f(0.4784, 0.2090), vec2f(0.0612, 0.2109), vec2f(0.0324, 0.7285), vec2f(0.4640, 0.7227), vec2f(0.4748, 0.5703), vec2f(0.4784, 0.2090), vec2f(0.5360, 0.3027), vec2f(0.5324, 0.7812), vec2f(0.6331, 0.7852), vec2f(0.9964, 0.7812), vec2f(0.9964, 0.3066), vec2f(0.0612, 0.2109), vec2f(0.0324, 0.7285), vec2f(0.4640, 0.7227), vec2f(0.4748, 0.5703), vec2f(0.4784, 0.2090), vec2f(0.5360, 0.3027), vec2f(0.5324, 0.7812), vec2f(0.6331, 0.7852), vec2f(0.9964, 0.7812), vec2f(0.9964, 0.3066), vec2f(0.0612, 0.2109), vec2f(0.0324, 0.7285), vec2f(0.4640, 0.7227), vec2f(0.4748, 0.5703), vec2f(0.4784, 0.2090), vec2f(0.0180, 0.2969), vec2f(0.0180, 0.7168), vec2f(0.9676, 0.7168), vec2f(0.9712, 0.3105), vec2f(0.0180, 0.2969), vec2f(0.0180, 0.7168), vec2f(0.9676, 0.7168), vec2f(0.9712, 0.3105), vec2f(0.0180, 0.2969), vec2f(0.0180, 0.7168), vec2f(0.9676, 0.7168), vec2f(0.9712, 0.3105), vec2f(0.0180, 0.2969), vec2f(0.0180, 0.7168), vec2f(0.9676, 0.7168), vec2f(0.9712, 0.3105), vec2f(0.0180, 0.2969), vec2f(0.0180, 0.7168), vec2f(0.9676, 0.7168), vec2f(0.9712, 0.3105), vec2f(0.8885, 0.0664), vec2f(0.1115, 0.0723), vec2f(0.1259, 0.2539), vec2f(0.1259, 0.4414), vec2f(0.1475, 0.8809), vec2f(0.9173, 0.8887), vec2f(0.8885, 0.0664), vec2f(0.1115, 0.0723), vec2f(0.1259, 0.2539), vec2f(0.1259, 0.4414), vec2f(0.1475, 0.8809), vec2f(0.9173, 0.8887), vec2f(0.8885, 0.0664), vec2f(0.1115, 0.0723), vec2f(0.1259, 0.2539), vec2f(0.1259, 0.4414), vec2f(0.1475, 0.8809), vec2f(0.9173, 0.8887));
const BACKDROP = array<f32, 60>(0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.5020, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000);
const VEIL = array<f32, 60>(0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0902, 0.0902, 0.0863, 0.0863, 0.0902, 0.0863, 0.0863, 0.0863, 0.0863, 0.0863, 0.0863, 0.0863, 0.0863, 0.0863, 0.0863, 0.0902, 0.0784, 0.0784, 0.0784, 0.0784, 0.0784, 0.0784, 0.0784, 0.0667, 0.0667, 0.0667, 0.0667, 0.0667, 0.0667, 0.0667, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000);

const BOARD: vec2f = vec2f(278.0, 512.0);

fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let s = 0.5 * (lo + hi);
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

const SOFT: vec4f = vec4f(0.166667, 0.166667, 0.833333, 0.833333);

// 0 before t0, 1 after t1, eased in between.
fn rise(t: f32, t0: f32, t1: f32) -> f32 {
    return bezier_ease(clamp((t - t0) / (t1 - t0), 0.0, 1.0), SOFT);
}

// Eases up over [a, b] and back down over [c, d].
fn window(t: f32, a: f32, b: f32, c: f32, d: f32) -> f32 {
    return rise(t, a, b) * (1.0 - rise(t, c, d));
}

fn hash(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

fn value_noise(p: vec2f) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2f(1.0, 0.0)), u.x), mix(hash(i + vec2f(0.0, 1.0)), hash(i + vec2f(1.0, 1.0)), u.x), u.y);
}

fn segment_distance(p: vec2f, a: vec2f, b: vec2f) -> f32 {
    let ab = b - a;
    let h = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-12), 0.0, 1.0);
    return length(p - a - ab * h);
}

// Distance (board pixels) to the outline of shape `s`, negative inside (even-odd).
fn shape_distance(p: vec2f, s: i32) -> f32 {
    let info = SHAPES[s];
    let start = i32(info.x);
    let n = i32(info.y);
    var d = 1e9;
    var inside = false;
    for (var i = 0; i < n; i++) {
        let a = CORNERS[start + i] * BOARD;
        let b = CORNERS[start + (i + 1) % n] * BOARD;
        d = min(d, segment_distance(p, a, b));
        if ((a.y > p.y) != (b.y > p.y)) {
            let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x);
            if (p.x < x) { inside = !inside; }
        }
    }
    return select(d, -d, inside);
}

// Grey level of the displacement map (x) and chalk brightness of the cut-outs (y) at board pixel p.
fn board(p: vec2f, frame: i32, px: f32) -> vec2f {
    var level = BACKDROP[frame];
    var chalk = 0.0;
    let span = FRAME_SHAPES[frame];
    for (var k = 0; k < span.y; k++) {
        let s = span.x + k;
        let d = shape_distance(p, s);
        level = mix(level, SHAPES[s].z, clamp(0.5 - d / px, 0.0, 1.0));
        // Scratched print inside each cut-out, with a bright torn edge.
        chalk = max(chalk, 0.7 * clamp(1.0 - abs(d) / 1.2, 0.0, 1.0));
        if (d < 0.0) {
            let streak = value_noise(vec2f(p.x * 0.04 + f32(s) * 7.0, p.y * 0.9));
            chalk = max(chalk, 0.55 * pow(streak, 8.0));
        }
    }
    return vec2f(level, chalk);
}

// Chalk strokes drawn over the board in frame `frame`; returns brightness.
fn doodles(p: vec2f, frame: i32) -> f32 {
    var lit = 0.0;
    // Squiggly wave across the top: small at first, larger once the first cut-out lands.
    if (frame >= 18 && frame <= 29) {
        var x0 = 53.0;
        var x1 = 211.0;
        var yc = 146.0;
        var amp = 19.0;
        var waves = 5.0;
        if (frame >= 23) { x0 = 39.0; x1 = 256.0; yc = 128.0; amp = 27.0; waves = 5.5; }
        if (p.x > x0 - 4.0 && p.x < x1 + 4.0) {
            let x = clamp(p.x, x0, x1);
            let k = 6.2831853 * waves / (x1 - x0);
            let y = yc - amp * cos(k * (x - x0));
            let slope = amp * k * sin(k * (x - x0));
            let d = length(vec2f(p.x - x, (p.y - y) / sqrt(1.0 + slope * slope)));
            lit = max(lit, 0.85 * clamp(2.2 - d, 0.0, 1.0));
        }
    }
    // A chalk cross near the bottom.
    if (frame >= 18 && frame <= 34) {
        let c = vec2f(133.0, 374.0);
        let d = min(segment_distance(p, c - vec2f(11.0), c + vec2f(11.0)), segment_distance(p, c + vec2f(-11.0, 11.0), c + vec2f(11.0, -11.0)));
        lit = max(lit, 0.85 * clamp(4.5 - d, 0.0, 1.0));
    }
    // Zig-zag scribble filling the tall cut-out.
    if (frame >= 41 && frame <= 43) {
        var d = 1e9;
        for (var i = 0; i < 11; i++) {
            let a = vec2f(select(81.0, 222.0, i % 2 == 1), 61.0 + 31.8 * f32(i));
            let b = vec2f(select(81.0, 222.0, i % 2 == 0), 61.0 + 31.8 * f32(i + 1));
            d = min(d, segment_distance(p, a, b));
        }
        lit = max(lit, 0.55 * clamp(1.5 - d, 0.0, 1.0));
    }
    // One long scratch down the right side.
    if (frame >= 44 && frame <= 47) {
        let x = 256.0 + 8.0 * (p.y / 384.0) - 6.0 * sin(3.14159 * p.y / 384.0);
        let fade = 1.0 - smoothstep(370.0, 390.0, p.y);
        lit = max(lit, 0.9 * fade * clamp(2.0 - abs(p.x - x), 0.0, 1.0));
    }
    return lit;
}

// Mirror coordinates outside [0, 1] back inside.
fn mirror(q: vec2f) -> vec2f {
    let m = q - 2.0 * floor(q * 0.5);
    return clamp(select(m, 2.0 - m, m > vec2f(1.0)), vec2f(0.0), vec2f(1.0));
}

// Ramp from a to b, as the luma keyer does.
fn key_ramp(a: f32, b: f32, x: f32) -> f32 {
    return clamp((x - a) / (b - a + 1e-5), 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends of the transition.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let frame = clamp(i32(floor(t * 30.0 + 0.5)), 0, 59);

    // The portrait board covers the output, centred.
    let aspect = globals.size.x / globals.size.y;
    let board_aspect = BOARD.x / BOARD.y;
    var q = uv;
    if (aspect > board_aspect) {
        q.y = (uv.y - 0.5) * board_aspect / aspect + 0.5;
    } else {
        q.x = (uv.x - 0.5) * aspect / board_aspect + 0.5;
    }
    let p = q * BOARD;
    let px = max(BOARD.x / globals.size.x * min(1.0, aspect / board_aspect), 0.2);
    let b = board(p, frame, px);
    let level = b.x;

    // Both clips are pushed by the map's grey, mostly vertically; the push scales with the frame aspect.
    let push_a = window(t, 0.719987, 0.759993, 1.166667, 1.2);
    let push_b = window(t, 0.733333, 0.766667, 1.433333, 1.466667);
    let shove = (level - 0.5) * 2.0 * vec2f(0.02, -0.59 * aspect);
    let a_moved = textureSampleLevel(first, smp, mirror(uv + shove * push_a), 0.0).rgb;
    let b_moved = textureSampleLevel(second, smp, mirror(uv + shove * push_b), 0.0).rgb;

    // The darker cut-outs, keyed by luma, let the pushed second clip through.
    let black = (38.0 * rise(t, 1.1, 1.133333) + 24.0 * rise(t, 1.333333, 1.366667)) * (1.0 - rise(t, 1.433333, 1.466667)) / 255.0;
    let white = rise(t, 1.066667, 1.1);
    let matte = abs(1.0 - key_ramp(black, black, level) * (1.0 - key_ramp(white, white, level)));
    let show_cut = window(t, 1.1, 1.133333, 1.433333, 1.466667);
    var color = mix(a_moved, b_moved, matte * show_cut);
    color = mix(color, textureSampleLevel(second, smp, uv, 0.0).rgb, rise(t, 1.433333, 1.466667));

    // Chalk layer: its brightness doubles as its alpha.
    let dust = VEIL[frame] * (0.75 + 0.5 * value_noise(p * 0.35));
    let edges = select(0.0, b.y, frame >= 23 && frame <= 43);
    let chalk = clamp(max(max(edges, doodles(p, frame)), dust), 0.0, 1.0);
    color = vec3f(chalk) + color * (1.0 - chalk);
    gpufx_write(id, vec4f(clamp(color, vec3f(0.0), vec3f(1.0)), 1.0));
}
