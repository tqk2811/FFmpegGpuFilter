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
