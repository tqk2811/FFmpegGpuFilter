// The picture keeps its aspect ratio: fitted size (contain/cover/native) times zoom, with its pivot on the canvas anchor.
// Composited "over" the canvas with straight alpha, so a transparent canvas gives a transparent background.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let bg = textureLoad(canvas, vec2i(id.xy), 0);
    let ssize = vec2f(textureDimensions(src));
    let csize = globals.size;
    let ratio = csize / ssize;
    var k = 1.0;
    if (params.fit == 0) {
        k = min(ratio.x, ratio.y);
    } else if (params.fit == 1) {
        k = max(ratio.x, ratio.y);
    }
    let scale = k * params.zoom;
    let size = ssize * scale;
    if (scale <= 0.0) {
        gpufx_write(id, bg);
        return;
    }
    let tl = params.anchor * csize - params.pivot * size;
    let uv = (vec2f(id.xy) + 0.5 - tl) / size;
    if (any(uv < vec2f(0.0)) || any(uv > vec2f(1.0))) {
        gpufx_write(id, bg);
        return;
    }
    // Shrinking reads a smaller mip level so the picture does not alias.
    let lod = max(0.0, -log2(scale));
    let o = textureSampleLevel(src, smp, uv, lod);
    let a = o.a * params.opacity;
    let out_a = a + bg.a * (1.0 - a);
    var rgb = bg.rgb;
    if (out_a > 0.0) {
        rgb = (o.rgb * a + bg.rgb * bg.a * (1.0 - a)) / out_a;
    }
    gpufx_write(id, vec4f(rgb, out_a));
}
