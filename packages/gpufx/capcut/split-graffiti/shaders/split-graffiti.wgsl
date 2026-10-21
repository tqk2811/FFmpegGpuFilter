// Chalk scribbles sweep over the first clip, then the second clip breaks in as tilted white-edged shards closing along a jagged tear.

// Animation time covered by the whole transition, in seconds.
const SPAN: f32 = 1.4;
// Frame rate the scribble and shard animation is timed in.
const FPS: f32 = 30.0;
// Shards start to appear at this frame, the vertical tear is shut at SHUT_V and the horizontal one at SHUT_H.
const OPEN_AT: f32 = 11.0;
const SHUT_V: f32 = 20.0;
const SHUT_H: f32 = 25.0;

fn hash_u(x: u32) -> u32 {
    var h = x * 747796405u + 2891336453u;
    h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
    return (h >> 22u) ^ h;
}

fn hash01(a: u32, b: u32) -> f32 {
    return f32(hash_u(a ^ hash_u(b)) & 0xffffu) / 65535.0;
}

// Zigzag with `teeth` teeth over [0, 1] and amplitude `amp`, offset by `phase`.
fn zigzag(x: f32, teeth: f32, amp: f32, phase: f32) -> f32 {
    let s = fract(x * teeth + phase);
    return amp * (abs(s * 2.0 - 1.0) * 2.0 - 1.0);
}

// Signed distance (in uv-height units, positive = second clip) to the shard mask.
fn shard_field(uv: vec2f, f: f32, aspect: f32) -> f32 {
    let open_v = clamp((f - OPEN_AT) / (SHUT_V - OPEN_AT), 0.0, 1.0);
    let open_h = clamp((f - OPEN_AT) / (SHUT_H - OPEN_AT), 0.0, 1.0);
    // Half widths of the two tears, eased so the shards rush in then settle.
    let wv = 0.55 * (1.0 - open_v) * (1.0 - open_v);
    let wh = mix(0.55, 0.0, 1.0 - (1.0 - open_h) * (1.0 - open_h) * (1.0 - open_h * 0.5));
    // A tilted, jagged horizontal tear and a leaning vertical one.
    let cy = 0.5 + 0.06 * (uv.x - 0.5) + zigzag(uv.x, 2.5, 0.035, 0.2);
    let cx = 0.55 - 0.12 * (uv.y - 0.5) + zigzag(uv.y, 1.5, 0.04, 0.6);
    // Each side of a tear gets its own slight tilt so shard edges are not parallel.
    let side_y = select(-1.0, 1.0, uv.y > cy);
    let side_x = select(-1.0, 1.0, uv.x > cx);
    let dy = abs(uv.y - cy) - wh * (1.0 + 0.25 * side_x * (uv.x - 0.5));
    let dx = (abs(uv.x - cx) - wv * (1.0 + 0.3 * side_y * (uv.y - 0.5))) * aspect;
    // Once the vertical tear has shut it leaves no seam behind.
    return select(min(dy, dx), dy, wv <= 0.0);
}

// Distance from p to the segment a-b (pixels).
fn seg_dist(p: vec2f, a: vec2f, b: vec2f) -> vec2f {
    let ab = b - a;
    let h = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    return vec2f(length(p - a - ab * h), h);
}

// White chalk strokes: a fixed set of segments per scene, broken up along their length.
fn scribbles(px: vec2f, size: vec2f, f: f32) -> f32 {
    var scene = 0u;
    var count = 0u;
    var fade = 1.0;
    if (f < 6.0) {
        scene = 1u; count = 22u; fade = clamp(f / 3.0, 0.0, 1.0) * 0.8;
    } else if (f < 11.0) {
        scene = 2u; count = 14u;
    } else if (f < 16.0) {
        scene = 3u; count = 6u;
    } else if (f < 30.0) {
        scene = 4u; count = 4u; fade = 0.6 * clamp((30.0 - f) / 6.0, 0.0, 1.0);
    } else {
        return 0.0;
    }
    let unit = size.y;
    var ink = 0.0;
    for (var i = 0u; i < 22u; i++) {
        if (i >= count) { break; }
        let k = scene * 64u + i;
        let start = vec2f(hash01(k, 1u), hash01(k, 2u)) * size;
        var ang = (hash01(k, 3u) - 0.5) * 0.5 + 1.25;
        if (scene == 2u || scene == 4u) { ang = (hash01(k, 3u) - 0.5) * 0.9; }
        if (scene == 3u) { ang = hash01(k, 3u) * 3.1416; }
        let len = mix(0.25, 0.9, hash01(k, 4u)) * unit;
        let a = start - vec2f(cos(ang), sin(ang)) * len * 0.5;
        let b = start + vec2f(cos(ang), sin(ang)) * len * 0.5;
        let width = mix(0.7, 2.2, hash01(k, 5u)) * unit / 1080.0;
        let d = seg_dist(px, a, b);
        // Chalk grain: the stroke drops out in short gaps along its length.
        let grain = hash01(k * 977u + u32(d.y * 60.0), 6u);
        let taper = smoothstep(0.0, 0.15, d.y) * smoothstep(1.0, 0.85, d.y);
        let line = 1.0 - smoothstep(width, width + 1.0, d.x);
        ink = max(ink, line * taper * step(0.25, grain));
    }
    return ink * fade;
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
    let f = clamp(params.progress, 0.0, 1.0) * SPAN * FPS;
    let size = vec2f(globals.size);
    let aspect = size.x * globals.pixel_aspect / size.y;
    let px = uv * size;
    let pix = 1.0 / size.y;
    var col = a;
    if (f >= OPEN_AT) {
        let d = shard_field(uv, f, aspect);
        let cover = select(select(smoothstep(-pix, pix, d), 1.0, f >= SHUT_H), 0.0, f <= OPEN_AT);
        col = mix(a, b, cover);
        // White rim along the shard edges while they move.
        let rim_w = 3.5 * pix * clamp((SHUT_H + 2.0 - f) / 3.0, 0.0, 1.0);
        let rim = select(0.0, 1.0 - smoothstep(rim_w, rim_w + pix, abs(d)), rim_w > 0.0);
        col = mix(col, vec3f(1.0), rim);
    }
    let ink = scribbles(px, size, f);
    col = mix(col, vec3f(1.0), ink);
    gpufx_write(id, vec4f(col, 1.0));
}
