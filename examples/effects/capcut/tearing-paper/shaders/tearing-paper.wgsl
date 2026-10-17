// Paper tear: a ragged rip runs across the middle of the first clip, then the sheet shreds away.

// The tear animation is laid out on a 16:9 sheet that covers the frame (cropped, never stretched).
const SHEET: vec2f = vec2f(1920.0, 1080.0);
// Animation length in frames; `progress` 0..1 spans all of them.
const FRAMES: f32 = 45.0;
// Width of the anti-aliased rim of every torn edge, in sheet heights.
const EDGE: f32 = 0.004;

fn hash21(p: vec2f) -> f32 {
    var q = fract(p * vec2f(123.34, 456.21));
    q += dot(q, q + 45.32);
    return fract(q.x * q.y);
}

fn value_noise(p: vec2f) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash21(i);
    let b = hash21(i + vec2f(1.0, 0.0));
    let c = hash21(i + vec2f(0.0, 1.0));
    let d = hash21(i + vec2f(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn fbm(p: vec2f) -> f32 {
    var sum = 0.0;
    var amp = 0.5;
    var q = p;
    for (var i = 0; i < 4; i++) {
        sum += amp * value_noise(q);
        q = q * 2.03 + vec2f(17.1, 9.7);
        amp *= 0.5;
    }
    return sum / 0.9375;
}

// Fraction of the tear line already ripped (x in sheet widths), as the rip runs left to right.
fn rip_front(f: f32) -> f32 {
    return 0.075 * f + 0.03 * min(f, 1.0) - 0.01;
}

// How far the shredding has eaten into the sheet around the tear.
fn shred_reach(f: f32) -> f32 {
    let k = clamp((f - 20.5) / 14.0, 0.0, 1.0);
    return 0.25 * clamp((f - 20.5) / 1.5, 0.0, 1.0) + 1.2 * k;
}

// 0 = paper (first clip), 1 = torn open (second clip), for a point on the sheet.
fn opening(m: vec2f, f: f32) -> f32 {
    let q = vec2f(m.x * SHEET.x / SHEET.y, m.y);
    let line_y = 0.5 + 0.012 * (value_noise(vec2f(q.x * 3.0, 4.0)) - 0.5);
    let dy = q.y - line_y;

    // The rip itself: a band of slanted shards whose width wobbles along the line.
    let slant = q.x + 0.9 * dy;
    // Saw teeth of random height give the leaf-shaped shards along the rip.
    let tooth_pos = slant * 9.0 + 0.6 * value_noise(vec2f(slant * 3.0, 5.0));
    let tooth = fract(tooth_pos) * (0.35 + 0.65 * hash21(vec2f(floor(tooth_pos), 2.0)));
    let shard = 0.5 * tooth + 0.5 * value_noise(vec2f(slant * 6.0, 1.0));
    let thicken = 1.0 + 0.5 * smoothstep(13.0, 22.0, f);
    let half_width = (0.034 + 0.075 * shard * shard) * thicken;
    let front = rip_front(f) + 0.03 * (value_noise(vec2f(q.y * 30.0, 3.0)) - 0.5);
    var torn = smoothstep(-EDGE, EDGE, half_width - abs(dy)) * smoothstep(-EDGE, EDGE, front - m.x);

    // Hairline cracks that spread from the rip before the sheet gives way.
    let crack_n = fbm(q * vec2f(6.0, 1.6) + vec2f(2.0, 0.0));
    let crack = 1.0 - abs(2.0 * crack_n - 1.0);
    let crack_amount = smoothstep(12.0, 21.0, f) * (1.0 - smoothstep(0.05, 0.4, abs(dy)));
    torn = max(torn, smoothstep(-0.01, 0.01, crack - (1.0 - 0.025 * crack_amount)) * step(0.001, crack_amount));

    // Shredding: ragged pieces tear off, nearest the rip first.
    let piece = fbm(q * 4.0 + vec2f(5.3, 1.1));
    let rag = 1.0 - abs(2.0 * fbm(q * 7.0 + vec2f(1.7, 8.2)) - 1.0);
    let need = abs(dy) * 1.4 + 0.55 * piece + 0.25 * (1.0 - rag);
    torn = max(torn, smoothstep(-EDGE * 3.0, EDGE * 3.0, shred_reach(f) - need));
    return torn;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }

    // With `overlap` off, one clip feeds both sides: the first clip before the midpoint,
    // the second one after it, so the tear shows the same picture on both sides.
    var under = textureSampleLevel(second, smp, uv, 0.0).rgb;
    var over = textureSampleLevel(first, smp, uv, 0.0).rgb;
    if (params.overlap == 0u) {
        if (params.progress < 0.5) { under = over; } else { over = under; }
    }

    // Cover-fit the sheet onto the frame.
    let fit = max(globals.size.x / SHEET.x, globals.size.y / SHEET.y);
    let m = (uv - 0.5) * globals.size / (SHEET * fit) + 0.5;
    let f = params.progress * FRAMES;
    let a = opening(m, f);
    gpufx_write(id, vec4f(mix(over, under, a), 1.0));
}
