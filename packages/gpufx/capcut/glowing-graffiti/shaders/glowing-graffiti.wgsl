// Glowing Graffiti: a red light leak and drifting sparks are screened over the clips while dripping graffiti paint and a blinding cream flash sweep across, cutting to the second clip under the flash.

const SPAN: f32 = 2.0;        // scene seconds covered by progress 0..1
const CUT: f32 = 0.958333;    // scene time of the cut to the second clip
const LEAK_FPS: f32 = 24.0;   // the light leak loops 12 frames at 24 fps
const PAINT_FPS: f32 = 24.0;  // the paint flash advances in 24 fps steps

const CREAM: vec3f = vec3f(1.0, 0.98, 0.78);
const PAINT: vec3f = vec3f(1.0, 0.62, 0.38);
const RED: vec3f = vec3f(0.86, 0.06, 0.0);

fn hash21(p: vec2f) -> f32 {
    var q = fract(p * vec2f(0.1031, 0.1030));
    q += dot(q, q.yx + 33.33);
    return fract((q.x + q.y) * q.x);
}

fn value_noise(p: vec2f) -> f32 {
    let c = floor(p);
    let f = p - c;
    let w = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(c), hash21(c + vec2f(1.0, 0.0)), w.x),
               mix(hash21(c + vec2f(0.0, 1.0)), hash21(c + vec2f(1.0, 1.0)), w.x), w.y);
}

fn screen(base: vec3f, top: vec3f) -> vec3f {
    return 1.0 - (1.0 - base) * (1.0 - clamp(top, vec3f(0.0), vec3f(1.0)));
}

// Opacity track: linear ramps between keys, held outside.
fn ramp(t: f32, t0: f32, t1: f32, v0: f32, v1: f32) -> f32 {
    return mix(v0, v1, clamp((t - t0) / (t1 - t0), 0.0, 1.0));
}

// Red light leak; its first three frames carry a bright streak band.
fn light_leak(uv: vec2f, t: f32) -> vec3f {
    let frame = floor(t * LEAK_FPS + 0.5) % 12.0;
    var c = vec3f(0.69, 0.0, 0.0) * (0.9 + 0.1 * smoothstep(0.0, 0.5, uv.x));
    if (frame < 3.0) {
        let bx = (uv.x - 0.42 - 0.04 * uv.y) / 0.07;
        let sx = (uv.x - 0.15) / 0.12;
        let band = exp(-bx * bx);
        let side = exp(-sx * sx) * 0.6;
        c = vec3f(1.0, 0.05, 0.0) + vec3f(0.0, 0.85, 0.35) * band + vec3f(0.0, 0.35, 0.05) * side;
    }
    // Thin slanted spark streaks.
    let s = vec2f(uv.x * 0.8 + uv.y * 0.6, uv.y * 0.8 - uv.x * 0.6) * vec2f(60.0, 6.0) + vec2f(frame * 7.3, frame * 1.9);
    let cell = floor(s);
    let lit = step(0.93, hash21(cell));
    let f = fract(s) - 0.5;
    let streak = lit * smoothstep(0.12, 0.0, abs(f.x)) * smoothstep(0.5, 0.2, abs(f.y));
    return c + vec3f(0.3, 0.25, 0.1) * streak;
}

// Small white and orange sparks drifting slowly upward.
fn sparks(uv: vec2f, t: f32) -> vec3f {
    let aspect = globals.size.x / globals.size.y;
    var sum = vec3f(0.0);
    for (var layer = 0; layer < 2; layer++) {
        let fl = f32(layer);
        let grid = 26.0 + 14.0 * fl;
        let p = vec2f(uv.x * aspect, uv.y + t * (0.05 + 0.04 * fl)) * grid;
        let cell = floor(p);
        let h = hash21(cell + fl * 17.0);
        if (h < 0.55) { continue; }
        let centre = vec2f(hash21(cell + 3.1), hash21(cell + 7.7)) * 0.7 + 0.15;
        let d = length((fract(p) - centre) * vec2f(1.0, 1.6));
        let size = 0.06 + 0.08 * hash21(cell + 11.3);
        let twinkle = 0.6 + 0.4 * sin(t * 9.0 + h * 40.0);
        let glow = smoothstep(size, 0.0, d) * twinkle;
        let tint = select(vec3f(1.0, 0.35, 0.05), vec3f(1.0, 0.97, 0.9), hash21(cell + 5.5) > 0.5);
        sum += tint * glow;
    }
    return sum;
}

// Dripping paint edge: covered below a wavy line of rounded drips hanging from the top.
fn drips(uv: vec2f, top: f32) -> f32 {
    let lobes = 7.0;
    let x = uv.x * lobes;
    let k = fract(x) - 0.5;
    let reach = top - 0.12 * (1.0 - 4.0 * k * k) * (0.6 + 0.8 * hash21(vec2f(floor(x), 2.0)));
    return smoothstep(reach - 0.01, reach + 0.01, uv.y);
}

// The graffiti flash as premultiplied colour, picked by its 24 fps frame.
fn paint_flash(uv: vec2f, t: f32) -> vec3f {
    let frame = floor(t * PAINT_FPS + 0.5);
    let grain = value_noise(uv * vec2f(40.0, 8.0));
    let warm_from_br = smoothstep(0.2, 1.2, length(uv - vec2f(1.1, 1.1)));
    if (frame < 11.0 || frame > 29.0) { return vec3f(0.0); }
    if (frame <= 13.0) {
        let a = drips(uv, 0.32 - (frame - 11.0) * 0.03);
        let streaky = PAINT * (0.85 + 0.25 * grain);
        let creamy = select(0.0, smoothstep(0.55, 0.75, grain), frame > 11.0);
        return mix(streaky, CREAM, creamy) * a;
    }
    if (frame == 14.0) { return CREAM * (0.92 + 0.08 * grain); }
    if (frame <= 17.0) {
        let a = drips(uv, 0.2);
        let blob = smoothstep(0.32, 0.22, length((uv - vec2f(0.45, 0.6)) * vec2f(1.0, 1.4)) + 0.05 * grain);
        return mix(mix(RED, PAINT * 0.95, a), CREAM, blob);
    }
    if (frame <= 22.0) {
        let reach = mix(0.55, 0.35, (frame - 18.0) / 4.0);
        let k = smoothstep(reach + 0.25, reach - 0.1, length(uv - vec2f(1.0, 1.0)) * 0.7 - 0.1 * (1.0 - warm_from_br));
        let warm = mix(RED * 0.8, vec3f(1.0, 0.75, 0.2), smoothstep(0.0, 0.6, k));
        return mix(warm, CREAM, smoothstep(0.5, 1.0, k));
    }
    if (frame <= 25.0) {
        let ring = smoothstep(0.03, 0.0, abs(length((uv - vec2f(0.45, 0.6)) * vec2f(1.6, 1.0)) - 0.35));
        let edge = smoothstep(0.75, 1.05, uv.x) * (frame - 23.0) / 2.0;
        return mix(CREAM, RED, edge * 0.8) + vec3f(0.0, 0.0, 0.2) * ring;
    }
    // Red disc fading away to the left.
    let fade = 1.0 - (frame - 26.0) / 4.0;
    let edge = mix(0.85, 0.72, (frame - 26.0) / 3.0);
    let disc = smoothstep(edge + 0.02, edge - 0.02, length((uv - vec2f(0.2, 0.5)) * vec2f(1.0, 0.75)));
    return RED * mix(1.0, 0.75, uv.x) * disc * fade;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;

    var c = textureSampleLevel(first, smp, uv, 0.0).rgb;
    if (t >= CUT) { c = textureSampleLevel(second, smp, uv, 0.0).rgb; }
    c = screen(c, paint_flash(uv, t));
    let leak_opacity = ramp(t, 1.125, 1.333333, 1.0, 0.1);
    c = screen(c, light_leak(uv, t) * leak_opacity);
    var spark_opacity = ramp(t, 0.0, 0.583333, 0.0, 1.0);
    if (t > 1.541667) { spark_opacity = ramp(t, 1.541667, 1.958333, 1.0, 0.0); }
    c = screen(c, sparks(uv, t) * spark_opacity);
    gpufx_write(id, vec4f(c, 1.0));
}
