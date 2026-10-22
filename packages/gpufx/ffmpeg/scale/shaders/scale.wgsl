// Bilinear resize: each output pixel samples the input at its center.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = (vec2f(id.xy) + vec2f(0.5)) / globals.size;
    gpufx_write(id, textureSampleLevel(src, smp, uv, 0.0));
}

// `other * num / den` rounded to the nearest multiple of `n` (at least `n`).
fn scaled_side(other: u32, num: u32, den: u32, n: u32) -> u32 {
    let v = round(f32(other) * f32(num) / (f32(den) * f32(n)));
    return max(u32(v), 1u) * n;
}

// FFmpeg scale's rules: 0 is the input's side, -n follows the other side's aspect ratio
// rounded to a multiple of n, both negative is the input's size.
fn gpufx_output_size(out_index: u32) -> vec2u {
    let s = gpufx_input_size(0u);
    var w = params.w;
    var h = params.h;
    if (w < 0 && h < 0) { return s; }
    if (w == 0) { w = i32(s.x); }
    if (h == 0) { h = i32(s.y); }
    if (w < 0) { return vec2u(scaled_side(u32(h), s.x, s.y, u32(-w)), u32(h)); }
    if (h < 0) { return vec2u(u32(w), scaled_side(u32(w), s.y, s.x, u32(-h))); }
    return vec2u(u32(w), u32(h));
}
