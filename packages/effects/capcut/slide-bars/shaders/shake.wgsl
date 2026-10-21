// Slide Bars, pass 2: a fading, motion-blurred camera shake, a ripple ring pushing the picture sideways, and a bright arc flare.
//
// Scene time is `progress` (0..1 s). The shake's wobble runs on the real clock
// (progress * duration); its strength eases from 3 to 0 over 0.533..0.933 s. The ripple
// and flare are short 12-frame animations (30 fps) that start at 0.6 s, drawn here
// procedurally as soft expanding rings.

const PI: f32 = 3.14159265;
const SHAKE_START: f32 = 0.533333;
const SHAKE_END: f32 = 0.933333;
const SHAKE_PIXELS: f32 = 192.0;  // wobble size at strength 1, on a 1080 px short side
const SHAKE_RATE: f32 = 8.0;
const SHAKE_HALF_SPAN: f32 = 0.0083333;  // half the exposure window of the shake blur (s)
const SHAKE_STEP: f32 = 10.0;  // design pixels per blur tap
const DESIGN: f32 = 1080.0;
const RING_START: f32 = 0.6;
const PUSH: f32 = 0.03;
const FLARE_GAIN: f32 = 0.72;

fn cubic(p1: f32, p2: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * p1 * r * r * s + 3.0 * p2 * r * s * s + s * s * s;
}

fn ease(k: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 16; n++) {
        let mid = (lo + hi) * 0.5;
        if (cubic(k.x, k.z, mid) > x) { hi = mid; } else { lo = mid; }
    }
    return cubic(k.y, k.w, (lo + hi) * 0.5);
}

fn mirror(p: vec2f) -> vec2f {
    return abs(((p + 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
}

// Shake displacement in design pixels (y up) at clock `c` for strength `amp`.
fn wobble(c: f32, amp: f32) -> vec2f {
    let x = PI * c * SHAKE_RATE;
    let a = amp * SHAKE_PIXELS;
    let dx = 0.25 * cos(x) + 0.16 * sin(1.5 * x) + 0.09 * cos(2.5 * x);
    let dy = 0.25 * sin(x) + 0.16 * cos(1.5 * x) + 0.09 * sin(2.5 * x);
    return vec2f(dx, dy) * a;
}

// Distance from the centre in a 16:9 frame stretched over the output.
fn ring_distance(uv: vec2f) -> f32 {
    return length((uv - 0.5) * vec2f(1.7777778, 1.0));
}

// Grey level of the ripple map at animation frame f (0..11).
fn ripple(uv: vec2f, f: f32) -> f32 {
    let r = max(0.0, 0.097 * (f - 0.35));
    let k = (ring_distance(uv) - r) / 0.12;
    return 0.64 * clamp(f, 0.0, 1.0) * exp(-k * k);
}

// Brightness of the flare arcs at animation frame f: a thin ring, strongest on the
// right and left, that swells and fades away by frame ~9.7.
fn flare(uv: vec2f, f: f32) -> f32 {
    let gain = clamp((f - 1.5) * 0.19, 0.0, 0.87) * clamp((9.7 - f) / 1.5, 0.0, 1.0);
    if (gain <= 0.0) { return 0.0; }
    let d = (uv - 0.5) * vec2f(1.7777778, 1.0);
    let r = 0.2 * (f - 1.9);
    let k = (length(d) - r) / 0.1;
    let side = d.x / max(length(d), 1e-4);
    let arc = smoothstep(0.3, 0.8, abs(side)) * select(0.6, 1.0, side > 0.0);
    return gain * arc * exp(-k * k);
}

// The bars composite with the flare added on top (Add blend), at position `pos`.
// Shake and ripple act on this whole layer stack, so the flare moves with the picture.
fn layered(pos: vec2f, f: f32) -> vec3f {
    var c = textureSampleLevel(stack, smp, pos, 0.0).rgb;
    if (f >= 0.0) { c = min(c + vec3f(FLARE_GAIN * flare(pos, f)), vec3f(1.0)); }
    return c;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = params.progress;
    // Exact clips at the ends, so the cut in and out is seamless.
    if (p <= 0.0) { gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0)); return; }
    if (p >= 1.0) { gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0)); return; }
    let t = p;

    var q = uv;
    var frame = -1.0;
    if (t >= RING_START) {
        frame = min((t - RING_START) * 30.0, 11.0);
        // Ripple pushes the picture sideways: black areas shift left, the ring shifts right.
        q = mirror(vec2f(uv.x + (ripple(uv, frame) - 0.5) * 2.0 * PUSH, uv.y));
    }

    var colour: vec3f;
    if (t < SHAKE_START) {
        colour = layered(q, frame);
    } else {
        let amp = mix(3.0, 0.0, ease(vec4f(0.33333333, 0.0, 0.66666667, 1.0),
            clamp((t - SHAKE_START) / (SHAKE_END - SHAKE_START), 0.0, 1.0)));
        let dims = vec2f(globals.size);
        let design = dims * (DESIGN / min(dims.x, dims.y));
        let clock = p * params.duration;
        let pa = q * design + wobble(clock - SHAKE_HALF_SPAN, amp) * vec2f(1.0, -1.0);
        let pb = q * design + wobble(clock + SHAKE_HALF_SPAN, amp) * vec2f(1.0, -1.0);
        let taps = clamp(ceil(length(pb - pa) / SHAKE_STEP), 1.0, 8.0);
        var acc = layered(mirror(pa / design), frame);
        for (var j = 1; j < 8; j++) {
            if (f32(j) >= taps) { break; }
            acc += layered(mirror(mix(pa, pb, f32(j) / taps) / design), frame);
        }
        colour = acc / taps;
    }

    gpufx_write(id, vec4f(clamp(colour, vec3f(0.0), vec3f(1.0)), 1.0));
}
