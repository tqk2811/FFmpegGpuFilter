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
