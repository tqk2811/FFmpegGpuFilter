// Dispersion Trail, pass 5: glow the clips, cross through black and lay the drifting rainbow streak curtain on top.

const SPAN: f32 = 2.13333333;      // animation length in seconds
const FPS: f32 = 30.0;
const SWITCH_AT: f32 = 1.0;
const STREAK_FRAMES: i32 = 57;
const FIELD_MEAN: f32 = 0.60;      // average light energy of the raw streak field

// Average level of the streak curtain for each of its frames (only frames 16..53 are shown).
const CURTAIN_LEVEL: array<f32, 57> = array<f32, 57>(
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.816, 0.763, 0.740, 0.662, 0.595, 0.514, 0.448, 0.372, 0.304, 0.319, 0.325, 0.403,
    0.465, 0.424, 0.476, 0.585, 0.677, 0.683, 0.651, 0.612, 0.567, 0.527, 0.503, 0.484,
    0.447, 0.385, 0.328, 0.291, 0.309, 0.330, 0.380, 0.380, 0.359, 0.353, 0.346, 0.338,
    0.305, 0.307, 0.0, 0.0, 0.0,
);

fn lin(t: f32, t0: f32, t1: f32, v0: f32, v1: f32) -> f32 {
    return mix(v0, v1, clamp((t - t0) / (t1 - t0), 0.0, 1.0));
}

fn unpack2(c: vec4f) -> vec2f {
    return vec2f(c.x + c.y / 255.0, c.z + c.w / 255.0);
}

fn hash_u(x: u32) -> u32 {
    var v = x * 747796405u + 2891336453u;
    v = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
    return (v >> 22u) ^ v;
}

fn rnd(cell: i32, salt: u32) -> f32 {
    return f32(hash_u(bitcast<u32>(cell) * 0x9E3779B9u + salt) & 0xFFFFu) / 65535.0;
}

fn tint(k: f32) -> vec3f {
    if (k < 0.45) { return vec3f(0.35, 0.32, 1.0); }    // violet blue
    if (k < 0.6) { return vec3f(0.3, 0.85, 1.0); }    // cyan
    if (k < 0.72) { return vec3f(1.0, 0.55, 0.18); }    // amber
    if (k < 0.85) { return vec3f(0.4, 0.95, 0.6); }     // mint
    return vec3f(1.0, 0.97, 0.92);                      // white
}

// One layer of soft streaks laid on a slanted grid of cells; each cell may hold one streak
// with its own colour, length, offset and drift speed.
fn streak_layer(along: f32, across: f32, band: f32, cell_len: f32, sharp: f32, fill: f32, t: f32, salt: u32) -> vec3f {
    var acc = vec3f(0.0);
    let c0 = i32(floor(across / band));
    for (var k = -1; k <= 1; k++) {
        let c = c0 + k;
        let speed = 0.10 + 0.20 * rnd(c, salt + 2u);
        let a = along - speed * t + rnd(c, salt + 3u) * cell_len;
        let r0 = i32(floor(a / cell_len));
        for (var m = -1; m <= 1; m++) {
            let r = r0 + m;
            let id = c * 7919 + r * 104729;
            if (rnd(id, salt + 6u) > fill) { continue; }
            let centre_x = (f32(c) + 0.2 + 0.6 * rnd(id, salt)) * band;
            let centre_y = (f32(r) + 0.5) * cell_len;
            let len = cell_len * (0.15 + 0.25 * rnd(id, salt + 1u));
            let d = (across - centre_x) / (band * sharp);
            let e = (a - centre_y) / len;
            let shape = exp(-d * d - e * e);
            acc += tint(rnd(id, salt + 4u)) * shape * (0.5 + rnd(id, salt + 5u));
        }
    }
    return acc;
}

// Light energy of the curtain (before exposure).
fn streak_field(uv: vec2f, t: f32) -> vec3f {
    let m = min(globals.size.x, globals.size.y);
    let q = (uv - 0.5) * globals.size / m;
    let dir = vec2f(0.5, -0.8660254);
    let side = vec2f(0.8660254, 0.5);
    let along = dot(q, dir);
    let across = dot(q, side);
    let hot = q - vec2f(-0.3, 0.4);
    var c = vec3f(0.10, 0.08, 0.07) + vec3f(1.0, 0.9, 0.75) * exp(-dot(hot, hot) * 7.0);
    c += streak_layer(along, across, 0.15, 0.7, 0.35, 0.8, t, 11u) * 1.0;
    c += streak_layer(along, across + 0.05, 0.08, 0.5, 0.25, 0.6, t * 1.3, 37u) * 0.9;
    c += streak_layer(along, across + 0.02, 0.06, 0.4, 0.08, 0.3, t * 1.8, 71u) * 1.4;
    return c;
}

fn screen_glow(src: vec3f, glow: vec3f, gain: f32) -> vec3f {
    return 1.0 - (1.0 - src) * (1.0 - glow * gain);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(a, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(b, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let glow = vec3f(unpack2(textureSampleLevel(glow_rg, smp, uv, 0.0)),
                     unpack2(textureSampleLevel(glow_b, smp, uv, 0.0)).x);

    // First clip: glow grows, then the layer fades to black.
    var col: vec3f;
    if (t < SWITCH_AT) {
        let gain = lin(t, 0.233333, 0.633333, 0.0, 36.5);
        col = clamp(screen_glow(a, glow, gain), vec3f(0.0), vec3f(1.0)) * lin(t, 0.633333, 0.766667, 1.0, 0.0);
    } else {
        // Second clip fades in from black with a strong glow that dies away.
        let lit = clamp(screen_glow(b, glow, 30.6), vec3f(0.0), vec3f(1.0));
        col = lit * lin(t, 1.3, 1.466667, 0.0, 1.0);
    }

    // Streak curtain, stepped at 30 frames per second like footage.
    let frame = clamp(i32(floor(t * FPS + 1e-4)), 0, STREAK_FRAMES - 1);
    var cover = 0.0;
    if (frame >= 16 && frame <= 19) { cover = f32(frame - 15) / 4.0; }
    else if (frame > 19 && frame <= 54) { cover = clamp(f32(54 - frame) / 12.0, 0.0, 1.0); }
    if (cover > 0.0) {
        let target_level = CURTAIN_LEVEL[frame];
        // Exposure chosen so the curtain's average level follows the footage it imitates.
        let exposure = -log(1.0 - min(target_level, 0.95)) / FIELD_MEAN;
        let s = 1.0 - exp(-streak_field(uv, f32(frame) / FPS) * exposure);
        col = mix(col, s, cover);
    }
    gpufx_write(id, vec4f(col, 1.0));
}
