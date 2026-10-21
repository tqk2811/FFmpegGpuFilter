// Port of FFmpeg's `blend` (libavfilter/blend_modes.c), float version, per RGB channel.
// A = top (first input), B = bottom (second input). Mode numbers follow FFmpeg's BLEND_* enum.

fn bits8(x: vec3f) -> vec3u {
    return vec3u(round(clamp(x, vec3f(0.0), vec3f(1.0)) * 255.0));
}

fn burn(a: vec3f, b: vec3f) -> vec3f {
    let r = max(vec3f(0.0), vec3f(1.0) - (vec3f(1.0) - b) / max(a, vec3f(1e-6)));
    return select(r, a, a <= vec3f(0.0));
}

fn dodge(a: vec3f, b: vec3f) -> vec3f {
    let r = min(vec3f(1.0), b / max(vec3f(1.0) - a, vec3f(1e-6)));
    return select(r, a, a >= vec3f(1.0));
}

fn blend_mode(mode: i32, a: vec3f, b: vec3f) -> vec3f {
    let one = vec3f(1.0);
    let zero = vec3f(0.0);
    let half = vec3f(0.5);
    let pi = 3.14159265358979;
    switch (mode) {
        case 1: { return min(one, a + b); }
        case 2: { return vec3f(bits8(a) & bits8(b)) / 255.0; }
        case 3: { return (a + b) * 0.5; }
        case 4: { return burn(a, b); }
        case 5: { return min(a, b); }
        case 6: { return abs(a - b); }
        case 7: { return clamp(half + a - b, zero, one); }
        case 8: { return select(clamp(a / max(b, vec3f(1e-6)), zero, one), one, b <= zero); }
        case 9: { return dodge(a, b); }
        case 10: { return a + b - 2.0 * a * b; }
        case 11: { return select(one - 2.0 * (one - b) * (one - a), 2.0 * b * a, b < half); }
        case 12: { return max(a, b); }
        case 13: { return a * b; }
        case 14: { return one - abs(one - a - b); }
        case 15: { return vec3f(bits8(a) | bits8(b)) / 255.0; }
        case 16: { return select(one - 2.0 * (one - a) * (one - b), 2.0 * a * b, a < half); }
        case 17: { return min(a, b) - max(a, b) + one; }
        case 18: { return select(max(a, 2.0 * (b - half)), min(a, 2.0 * b), b < half); }
        case 19: { return select(min(one, a * a / max(one - b, vec3f(1e-6))), b, b >= one); }
        case 20: { return one - (one - a) * (one - b); }
        case 21: { return clamp(a * a + 2.0 * b * a * (one - a), zero, one); }
        case 22: { return max(zero, a - b); }
        case 23: { return select(dodge(2.0 * (a - half), b), burn(2.0 * a, b), a < half); }
        case 24: { return vec3f(bits8(a) ^ bits8(b)) / 255.0; }
        case 25: { return select(one, zero, a < one - b); }
        case 26: { return clamp(select(b + 2.0 * (a - half), b + 2.0 * a - one, b < half), zero, one); }
        case 27: { return select(min(one, b * b / max(one - a, vec3f(1e-6))), a, a >= one); }
        case 28: { return clamp(a + b - half, zero, one); }
        case 29: { return clamp((a - half) * b / 0.125 + half, zero, one); }
        case 30: {
            let r = one - min((one - b) * (one - b) / max(a, vec3f(1e-6)), one);
            return select(r, zero, a <= zero);
        }
        case 31: {
            let r = one - min((one - a) * (one - a) / max(b, vec3f(1e-6)), one);
            return select(r, zero, b <= zero);
        }
        case 32: { return abs(one - a - b); }
        case 33: {
            let hi = select((a - b) / max(one - b, vec3f(1e-6)), zero, b >= one);
            let lo = select((b - a) / max(b, vec3f(1e-6)), zero, b <= zero);
            return clamp(select(lo, hi, a > b), zero, one);
        }
        case 34: { return sqrt(max(a, zero) * max(b, zero)); }
        case 35: { return select(2.0 * a * b / max(a + b, vec3f(1e-6)), zero, (a <= zero) & (b <= zero)); }
        case 36: { return (one - b) + (one - a) - one; }
        case 37: { return 2.0 * one - a - b; }
        case 38: { return (2.0 * one - cos(a * pi) - cos(b * pi)) * 0.25; }
        case 39: {
            let hi = b / max(2.0 * (one - a), vec3f(1e-6));
            let lo = 2.0 * a * b;
            return select(one, min(one, select(hi, lo, a <= half)), a < one);
        }
        default: { return a; }
    }
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = textureSampleLevel(top, smp, uv, 0.0);
    let b = textureSampleLevel(bottom, smp, uv, 0.0);
    let op = clamp(params.opacity, 0.0, 1.0);
    var rgb: vec3f;
    if (params.mode == 0) {
        // FFmpeg's normal: top * opacity + bottom * (1 - opacity)
        rgb = t.rgb * op + b.rgb * (1.0 - op);
    } else {
        // every other mode: top + (blended - top) * opacity
        let r = clamp(blend_mode(params.mode, t.rgb, b.rgb), vec3f(0.0), vec3f(1.0));
        rgb = t.rgb + (r - t.rgb) * op;
    }
    gpufx_write(id, vec4f(rgb, t.a));
}
