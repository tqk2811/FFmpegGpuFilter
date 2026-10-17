// Target zoom, step 2: edge smoothing of the warped picture, then the white aiming reticle on top.

const TIMELINE: f32 = 2.0;
// The reticle animation is drawn at this many frames per second of timeline.
const RETICLE_FPS: f32 = 30.0;
// Reticle geometry, in units of 1/512 of the shorter side.
const BOX_HALF: f32 = 27.25;
const CORNER_ARM: f32 = 15.8;
const STROKE: f32 = 4.5;
const CROSS_HALF: f32 = 11.6;

// Per timeline frame: reticle centre (x, y from the top, fractions of the frame), size factor, opacity.
const RETICLE = array<vec4f, 60>(
    vec4f(0.0982, 0.9015, 1.0, 0.0), vec4f(0.0982, 0.9015, 1.0, 1.0), vec4f(0.3575, 0.6908, 1.0, 1.0),
    vec4f(0.5616, 0.5241, 1.0, 1.0), vec4f(0.6553, 0.4482, 1.0, 1.0), vec4f(0.6553, 0.4482, 1.0, 1.0),
    vec4f(0.6553, 0.4482, 1.0, 1.0), vec4f(0.6553, 0.4482, 1.0, 1.0), vec4f(0.6424, 0.4521, 1.0, 1.0),
    vec4f(0.6092, 0.4623, 1.0, 1.0), vec4f(0.5622, 0.4765, 1.0, 1.0), vec4f(0.5082, 0.4928, 1.0, 1.0),
    vec4f(0.4531, 0.5095, 1.0, 1.0), vec4f(0.4037, 0.5246, 1.0, 1.0), vec4f(0.3671, 0.5361, 1.0, 1.0),
    vec4f(0.3525, 0.5400, 1.0, 1.0), vec4f(0.3525, 0.5400, 1.0, 1.0), vec4f(0.3525, 0.5400, 1.037, 1.0),
    vec4f(0.3525, 0.5400, 1.111, 1.0), vec4f(0.3525, 0.5400, 1.185, 1.0), vec4f(0.3525, 0.5400, 1.27, 1.0),
    vec4f(0.3525, 0.5400, 1.37, 0.79), vec4f(0.3525, 0.5400, 1.407, 0.59), vec4f(0.3525, 0.5400, 1.43, 0.385),
    vec4f(0.3525, 0.5400, 1.45, 0.165), vec4f(0.3525, 0.5400, 1.45, 0.0), vec4f(0.3525, 0.5400, 1.45, 0.0),
    vec4f(0.3525, 0.5400, 1.45, 0.0), vec4f(0.3525, 0.5400, 1.45, 0.0), vec4f(0.3525, 0.5400, 1.45, 0.0),
    vec4f(0.3525, 0.5400, 1.45, 0.0), vec4f(0.3525, 0.5400, 1.45, 0.0), vec4f(0.3525, 0.5400, 1.45, 0.0),
    vec4f(0.3525, 0.5400, 1.45, 0.0), vec4f(0.3525, 0.5400, 1.45, 0.0), vec4f(0.3525, 0.5400, 1.45, 0.0),
    vec4f(0.3525, 0.5400, 1.45, 0.165), vec4f(0.3525, 0.5400, 1.43, 0.385), vec4f(0.3525, 0.5400, 1.407, 0.59),
    vec4f(0.3525, 0.5400, 1.37, 0.79), vec4f(0.3525, 0.5400, 1.27, 1.0), vec4f(0.3525, 0.5400, 1.185, 1.0),
    vec4f(0.3525, 0.5400, 1.111, 1.0), vec4f(0.3525, 0.5400, 1.037, 1.0), vec4f(0.3525, 0.5400, 1.0, 1.0),
    vec4f(0.3525, 0.5400, 1.0, 1.0), vec4f(0.3525, 0.5400, 1.0, 1.0), vec4f(0.3525, 0.5400, 1.0, 1.0),
    vec4f(0.3525, 0.5400, 1.0, 1.0), vec4f(0.3525, 0.5400, 1.0, 1.0), vec4f(0.3525, 0.5400, 1.0, 1.0),
    vec4f(0.3674, 0.5291, 1.0, 1.0), vec4f(0.4102, 0.4977, 1.0, 1.0), vec4f(0.4782, 0.4481, 1.0, 1.0),
    vec4f(0.5693, 0.3818, 1.0, 1.0), vec4f(0.6795, 0.3002, 1.0, 1.0), vec4f(0.8070, 0.2066, 1.0, 1.0),
    vec4f(0.9464, 0.1044, 1.0, 1.0), vec4f(1.0900, 0.0000, 1.0, 1.0), vec4f(1.2300, -0.1000, 1.0, 1.0),
);

fn luma(c: vec4f) -> f32 { return dot(c.rgb, vec3f(0.299, 0.587, 0.114)); }

fn grab(uv: vec2f) -> vec4f { return textureSampleLevel(warped, smp, uv, 0.0); }

// Edge smoothing: blur along the local edge direction, falling back to the narrow blur
// when the wide one leaves the neighbourhood's luma range.
fn smoothed(uv: vec2f, texel: vec2f) -> vec4f {
    // Diagonal neighbours, (sw, se, nw, ne in bottom-up terms).
    let l_sw = luma(grab(uv + vec2f(-1.0, 1.0) * texel));
    let l_se = luma(grab(uv + vec2f(1.0, 1.0) * texel));
    let l_nw = luma(grab(uv + vec2f(-1.0, -1.0) * texel));
    let l_ne = luma(grab(uv + vec2f(1.0, -1.0) * texel));
    // The centre luma is read at uv scaled by one texel (a corner pixel), as the original look does.
    let corner = vec2f(uv.x, 1.0 - uv.y) * texel;
    let l_mid = luma(grab(vec2f(corner.x, 1.0 - corner.y)));
    let low_pair = l_sw + l_se;
    var dir = vec2f(-(low_pair - (l_nw + l_ne)), (l_sw + l_nw) - (l_se + l_ne));
    let reduce = max((low_pair + l_nw + l_ne) * 0.03125, 0.0078125);
    dir = clamp(dir / (min(abs(dir.x), abs(dir.y)) + reduce), vec2f(-8.0), vec2f(8.0)) * texel;
    // dir is bottom-up; flip y for top-down sampling.
    let step = vec2f(dir.x, -dir.y);
    let near = (grab(uv - step / 6.0) + grab(uv + step / 6.0)) * 0.5;
    let wide = near * 0.5 + (grab(uv - step * 0.5) + grab(uv + step * 0.5)) * 0.25;
    let l_near = luma(near);
    let lo = min(l_mid, min(min(l_sw, l_se), min(l_nw, l_ne)));
    let hi = max(l_mid, max(max(l_sw, l_se), max(l_nw, l_ne)));
    if (l_near < lo || l_near > hi) { return near; }
    return wide;
}

// Coverage of the reticle (corner brackets and a centre cross) at pixel offset `d`, in reticle units.
fn reticle_mask(d: vec2f, size: f32, px: f32) -> f32 {
    let half = STROKE * 0.5;
    let a = abs(d);
    // Brackets: the outer edge sits at BOX_HALF * size, strokes keep their width.
    let edge = BOX_HALF * size;
    let in_band_x = clamp((edge - a.x) / px + 0.5, 0.0, 1.0) * clamp((a.x - (edge - STROKE)) / px + 0.5, 0.0, 1.0);
    let in_band_y = clamp((edge - a.y) / px + 0.5, 0.0, 1.0) * clamp((a.y - (edge - STROKE)) / px + 0.5, 0.0, 1.0);
    let reach_x = clamp((a.x - (edge - CORNER_ARM * size)) / px + 0.5, 0.0, 1.0) * clamp((edge - a.x) / px + 0.5, 0.0, 1.0);
    let reach_y = clamp((a.y - (edge - CORNER_ARM * size)) / px + 0.5, 0.0, 1.0) * clamp((edge - a.y) / px + 0.5, 0.0, 1.0);
    let brackets = max(in_band_x * reach_y, in_band_y * reach_x);
    // Cross.
    let arm = CROSS_HALF * size;
    let bar_h = clamp((half - a.y) / px + 0.5, 0.0, 1.0) * clamp((arm - a.x) / px + 0.5, 0.0, 1.0);
    let bar_v = clamp((half - a.x) / px + 0.5, 0.0, 1.0) * clamp((arm - a.y) / px + 0.5, 0.0, 1.0);
    return max(brackets, max(bar_h, bar_v));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * TIMELINE;
    var col = smoothed(uv, 1.0 / globals.size).rgb;

    let frame = clamp(i32(floor(t * RETICLE_FPS)), 0, 59);
    let r = RETICLE[frame];
    if (r.w > 0.0) {
        // Reticle units: 1/512 of the shorter side, in pixels.
        let unit = min(globals.size.x, globals.size.y) / 512.0;
        let d = (uv - r.xy) * globals.size / unit;
        let m = reticle_mask(d, r.z, 1.0 / unit) * r.w;
        col = mix(col, vec3f(1.0), m);
    }
    gpufx_write(id, vec4f(col, 1.0));
}
