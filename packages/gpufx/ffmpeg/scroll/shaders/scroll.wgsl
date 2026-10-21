// Offset (0..1) of the picture after `speed` frame sizes per second, exact for long clips.
fn offset(speed: f32, ipos: f32) -> f32 {
    let whole = fract(speed * f32(globals.time_int));
    return fract(1.0 - ipos + whole + speed * globals.time_frac);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let sz = vec2i(textureDimensions(src));
    // FFmpeg: out(x, y) = in((x + h_pos) % w, (y + v_pos) % h) with the position truncated to whole pixels.
    let ph = i32(floor(offset(params.hspeed, params.hpos) * f32(sz.x)));
    let pv = i32(floor(offset(params.vspeed, params.vpos) * f32(sz.y)));
    let p = (vec2i(id.xy) + vec2i(ph, pv)) % sz;
    gpufx_write(id, textureLoad(src, min(p, sz - vec2i(1)), 0));
}
