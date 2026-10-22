// Inputs side by side: output x walks through the inputs' widths, left to right.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    var x = i32(id.x);
    for (var i = 0u; i < gpufx_input_count(); i++) {
        let w = i32(gpufx_input_size(i).x);
        if (x < w) {
            gpufx_write(id, gpufx_input_load(i, vec2i(x, i32(id.y))));
            return;
        }
        x -= w;
    }
    gpufx_write(id, vec4f(0.0));
}

// The output: the inputs side by side, the same height (0, an error, when one differs).
fn gpufx_output_size(out_index: u32) -> vec2u {
    let first = gpufx_input_size(0u);
    var size = first;
    for (var i = 1u; i < gpufx_input_count(); i++) {
        let s = gpufx_input_size(i);
        if (s.y != first.y) { return vec2u(0u); }
        size.x += s.x;
    }
    return size;
}
