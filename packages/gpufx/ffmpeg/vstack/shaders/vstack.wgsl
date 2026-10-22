// Inputs one above the other: output y walks through the inputs' heights, top to bottom.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    var y = i32(id.y);
    for (var i = 0u; i < gpufx_input_count(); i++) {
        let h = i32(gpufx_input_size(i).y);
        if (y < h) {
            gpufx_write(id, gpufx_input_load(i, vec2i(i32(id.x), y)));
            return;
        }
        y -= h;
    }
    gpufx_write(id, vec4f(0.0));
}

// The output: the inputs one above the other, the same width (0, an error, when one differs).
fn gpufx_output_size(out_index: u32) -> vec2u {
    let first = gpufx_input_size(0u);
    var size = first;
    for (var i = 1u; i < gpufx_input_count(); i++) {
        let s = gpufx_input_size(i);
        if (s.x != first.x) { return vec2u(0u); }
        size.y += s.y;
    }
    return size;
}
