// Money burst: banknotes explode from the centre, one note fills the camera at the cut, notes rain down after.

// Animation length in frames; `progress` 0..1 spans all of them.
const FRAMES: f32 = 52.0;
// Frame at which the picture underneath switches from the first clip to the second.
const CUT_FRAME: f32 = 30.0;
// Height / width of a note (the $100 bill images are 512x216).
const NOTE_ASPECT: f32 = 0.421875;
const BURST_COUNT: i32 = 56;
const RAIN_COUNT: i32 = 22;
const TAU: f32 = 6.2831853;

fn rand(i: f32, k: f32) -> f32 {
    return fract(sin(i * 12.9898 + k * 78.233) * 43758.5453);
}

// Paints one note over `under`. `s` is the pixel on the square stage (side = longer frame
// side, so the stage covers the frame). `tumble` is the cosine of the note's flip about its
// long axis: it squeezes the note sideways and darkens it as it turns edge-on.
fn paint_note(under: vec3f, s: vec2f, center: vec2f, width: f32, angle: f32, tumble: f32, blur: f32, opacity: f32) -> vec3f {
    let side = max(globals.size.x, globals.size.y);
    let squeeze = max(abs(tumble), 0.04);
    let half_size = vec2f(width * 0.5 * squeeze, width * 0.5 * NOTE_ASPECT);
    let d = s - center;
    let c = cos(angle);
    let sn = sin(angle);
    let local = vec2f(c * d.x + sn * d.y, -sn * d.x + c * d.y);
    let rim = (half_size - abs(local)) * side;
    let cover = clamp(min(rim.x, rim.y) + 0.5, 0.0, 1.0) * opacity;
    if (cover <= 0.0) { return under; }
    var uv = local / half_size * 0.5 + 0.5;
    // Both note images are 512 px wide.
    let lod = max(log2(512.0 / max(width * squeeze * side, 1.0)), 0.0) + blur;
    let shade = 0.72 + 0.28 * squeeze;
    // Turned past edge-on, the note shows its back, seen from behind (mirrored).
    var face: vec3f;
    if (tumble < 0.0) {
        face = textureSampleLevel(bill_back, smp, vec2f(1.0 - uv.x, uv.y), lod).rgb;
    } else {
        face = textureSampleLevel(bill_front, smp, uv, lod).rgb;
    }
    let note = face * shade;
    return mix(under, note, cover);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }

    let f = params.progress * FRAMES * 0.999;
    var color: vec3f;
    if (f < CUT_FRAME) {
        color = textureSampleLevel(first, smp, uv, 0.0).rgb;
    } else {
        color = textureSampleLevel(second, smp, uv, 0.0).rgb;
    }
    let side = max(globals.size.x, globals.size.y);
    let s = (uv - 0.5) * globals.size / side + 0.5;

    if (f >= 0.9 && f < CUT_FRAME) {
        // The burst: notes thrown out from a tight cluster at the centre, then drifting.
        let age = f - 1.0;
        let throw_out = 1.0 - exp(-max(age, 0.0) * 0.55);
        let appear = clamp((f - 0.9) / 0.3, 0.0, 1.0);
        for (var i = 0; i < BURST_COUNT; i++) {
            let n = f32(i);
            let dir_angle = rand(n, 1.0) * TAU;
            let reach = sqrt(rand(n, 2.0)) * 0.8 + 0.04;
            let dir = vec2f(cos(dir_angle), sin(dir_angle));
            let center = vec2f(0.5) + dir * reach * (0.62 * throw_out + 0.014 * max(age, 0.0))
                + vec2f(0.0, 0.004 * max(age, 0.0));
            let width = (0.07 + 0.11 * rand(n, 3.0)) * (0.25 + 0.75 * throw_out) * (1.0 + 0.015 * max(age, 0.0));
            let spin = (rand(n, 4.0) - 0.5) * 0.12;
            let angle = rand(n, 5.0) * TAU + spin * age;
            let tumble = cos(rand(n, 6.0) * TAU + (0.15 + 0.25 * rand(n, 7.0)) * age);
            color = paint_note(color, s, center, width, angle, tumble, 0.0, appear);
        }
    }

    if (f >= CUT_FRAME) {
        // The rain: big notes tumbling down past the second clip.
        let age = f - CUT_FRAME;
        for (var i = 0; i < RAIN_COUNT; i++) {
            let n = f32(i) + 100.0;
            let start_y = -0.25 + 1.1 * rand(n, 1.0);
            let fall = (1.4 - start_y) / (8.0 + 12.0 * rand(n, 2.0));
            let sway = 0.03 * sin(rand(n, 3.0) * TAU + 0.2 * age);
            let center = vec2f(rand(n, 4.0) * 1.1 - 0.05 + sway, start_y + fall * age);
            let width = 0.2 + 0.22 * rand(n, 5.0);
            let angle = 1.5708 + (rand(n, 6.0) - 0.5) * 1.2 + 0.03 * sin(0.3 * age + n);
            let tumble = cos(rand(n, 7.0) * TAU + (0.12 + 0.2 * rand(n, 8.0)) * age);
            color = paint_note(color, s, center, width, angle, tumble, 0.0, 1.0);
        }
    }

    if (f >= 11.0 && f < CUT_FRAME + 1.0) {
        // The hero note: drifts in from the left, then rushes into the lens to hide the cut.
        let k = f - 13.0;
        let rush = max(f - 22.0, 0.0);
        let inv_width = max(2.0 - 0.052 * k - 0.011 * rush * rush - 0.0012 * rush * rush * rush, 0.12);
        let width = 1.35 / inv_width;
        let approach = clamp((f - 11.0) / 19.0, 0.0, 1.0);
        let center = mix(vec2f(0.33, 0.62), vec2f(0.5, 0.5), approach * approach * approach);
        let angle = mix(-0.09, -0.02, approach);
        let blur = max(f - 27.5, 0.0) * 1.6;
        let appear = clamp((f - 11.0) / 2.0, 0.0, 1.0);
        color = paint_note(color, s, center, width, angle, 0.97, blur, appear);
    }
    gpufx_write(id, vec4f(color, 1.0));
}
