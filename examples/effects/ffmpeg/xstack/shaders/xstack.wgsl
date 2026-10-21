// Inputs in a grid, row by row. Every cell is the first input's size divided by the columns and rows;
// an input is scaled (bilinear) into its cell.
fn sample_bilinear(i: u32, uv: vec2f) -> vec4f {
    let s = vec2f(gpufx_input_size(i));
    let p = uv * s - 0.5;
    let f = floor(p);
    let t = p - f;
    let hi = vec2i(s) - vec2i(1);
    let a = clamp(vec2i(f), vec2i(0), hi);
    let b = clamp(vec2i(f) + vec2i(1), vec2i(0), hi);
    let c00 = gpufx_input_load(i, vec2i(a.x, a.y));
    let c10 = gpufx_input_load(i, vec2i(b.x, a.y));
    let c01 = gpufx_input_load(i, vec2i(a.x, b.y));
    let c11 = gpufx_input_load(i, vec2i(b.x, b.y));
    return mix(mix(c00, c10, t.x), mix(c01, c11, t.x), t.y);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let n = i32(gpufx_input_count());
    var cols = params.columns;
    if (cols < 1) { cols = i32(ceil(sqrt(f32(n)))); }
    cols = min(cols, n);
    let rows = (n + cols - 1) / cols;

    let g = (vec2f(id.xy) + 0.5) / globals.size * vec2f(f32(cols), f32(rows));
    let cell = vec2i(floor(g));
    let idx = cell.y * cols + cell.x;
    if (cell.x >= cols || cell.y >= rows || idx >= n) {
        gpufx_write(id, params.fill);
        return;
    }
    var uv = g - floor(g); // 0..1 inside the cell
    if (params.fit != 0) {
        // keep the input's aspect ratio, bars in the fill color
        let cell_px = globals.size / vec2f(f32(cols), f32(rows));
        let s = vec2f(gpufx_input_size(u32(idx)));
        let k = min(cell_px.x / s.x, cell_px.y / s.y);
        let shown = s * k / cell_px; // fraction of the cell the input covers
        uv = (uv - 0.5) / shown + 0.5;
        if (any(uv < vec2f(0.0)) || any(uv > vec2f(1.0))) {
            gpufx_write(id, params.fill);
            return;
        }
    }
    gpufx_write(id, sample_bilinear(u32(idx), uv));
}
