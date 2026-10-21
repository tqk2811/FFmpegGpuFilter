// Port of FFmpeg's selectivecolor: CMYK-style corrections limited to color ranges.

fn median3(a: f32, b: f32, c: f32) -> f32 {
    return max(min(a, b), min(max(a, b), c));
}

// Added to the pixel for one range: cmyk = (cyan, magenta, yellow, black) adjustments.
fn comp_adjust(scale: f32, value: f32, adjust: f32, k: f32, relative: bool) -> f32 {
    let lo = -value;
    let hi = 1.0 - value;
    var res = (-1.0 - adjust) * k - adjust;
    if (relative) {
        res *= hi;
    }
    return clamp(res, lo, hi) * scale;
}

fn range_adjust(c: vec3f, cmyk: vec4f, scale: f32, relative: bool) -> vec3f {
    if (scale <= 0.0) {
        return vec3f(0.0);
    }
    return vec3f(
        comp_adjust(scale, c.x, cmyk.x, cmyk.w, relative),
        comp_adjust(scale, c.y, cmyk.y, cmyk.w, relative),
        comp_adjust(scale, c.z, cmyk.z, cmyk.w, relative));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let c = p.rgb;
    let relative = params.correction_method == 1;
    let mx = max(c.x, max(c.y, c.z));
    let mn = min(c.x, min(c.y, c.z));
    let mid = median3(c.x, c.y, c.z);
    let rgb_scale = mx - mid;
    let cmy_scale = mid - mn;
    var adj = vec3f(0.0);
    if (c.x == mx) { adj += range_adjust(c, params.reds, rgb_scale, relative); }
    if (c.z == mn) { adj += range_adjust(c, params.yellows, cmy_scale, relative); }
    if (c.y == mx) { adj += range_adjust(c, params.greens, rgb_scale, relative); }
    if (c.x == mn) { adj += range_adjust(c, params.cyans, cmy_scale, relative); }
    if (c.z == mx) { adj += range_adjust(c, params.blues, rgb_scale, relative); }
    if (c.y == mn) { adj += range_adjust(c, params.magentas, cmy_scale, relative); }
    if (c.x > 0.5 && c.y > 0.5 && c.z > 0.5) {
        adj += range_adjust(c, params.whites, 2.0 * mn - 1.0, relative);
    }
    let any_color = c.x > 0.0 || c.y > 0.0 || c.z > 0.0;
    let all_max = c.x == 1.0 && c.y == 1.0 && c.z == 1.0;
    if (any_color && !all_max) {
        adj += range_adjust(c, params.neutrals, (2.0 - abs(2.0 * mx - 1.0) - abs(2.0 * mn - 1.0)) * 0.5, relative);
    }
    if (c.x < 0.5 && c.y < 0.5 && c.z < 0.5) {
        adj += range_adjust(c, params.blacks, 1.0 - 2.0 * mx, relative);
    }
    gpufx_write(id, vec4f(c + adj, p.a));
}
