// Bindings (globals, params, src, smp, out_tex) and gpufx_* helpers come from the prelude.
// Pass 2: draw the bars from the table that pass 1 wrote into `tmp` (entry e at texel (e % width, e / width)).
fn height_of(bins: i32, bin: i32, row: i32) -> f32 {
    let w = i32(globals.size.x);
    let e = row * bins + clamp(bin, 0, bins - 1);
    let t = textureLoad(tmp, vec2i(e % w, e / w), 0);
    return (round(t.r * 255.0) * 256.0 + round(t.g * 255.0)) / 65535.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let base = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let W = i32(globals.size.x);
    let H = i32(globals.size.y);
    let bins = clamp((W * H) / 4, 1, 256);
    let x = i32(id.x);
    let y = i32(id.y);
    let up = 1.0 - (f32(y) + 0.5) / f32(H);   // 1 at the top, 0 at the bottom
    var rgb = vec3f(0.0);
    if (params.display == 0) {
        let bin = (x * bins) / W;
        rgb = vec3f(select(0.0, 1.0, up <= height_of(bins, bin, 3)));
    } else if (params.display == 1) {
        let bin = (x * bins) / W;
        rgb = vec3f(
            select(0.0, 1.0, up <= height_of(bins, bin, 0)),
            select(0.0, 1.0, up <= height_of(bins, bin, 1)),
            select(0.0, 1.0, up <= height_of(bins, bin, 2)));
    } else {
        let pw = max(W / 3, 1);
        let panel = min(x / pw, 2);
        let bin = ((x - panel * pw) * bins) / pw;
        if (up <= height_of(bins, bin, panel)) { rgb[panel] = 1.0; }
    }
    gpufx_write(id, vec4f(mix(base.rgb, rgb, params.opacity), mix(base.a, 1.0, params.opacity)));
}
