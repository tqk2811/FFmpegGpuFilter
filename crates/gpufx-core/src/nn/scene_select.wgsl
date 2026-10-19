
@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (state.cut == 0u || id.x >= p.w || id.y >= p.h) {
        return;
    }
    var c: vec4f;
    if (p.t < 0.5) {
        c = textureLoad(frame0, vec2i(id.xy), 0);
    } else {
        c = textureLoad(frame1, vec2i(id.xy), 0);
    }
    textureStore(dst, vec2i(id.xy), vec4f(c.rgb, 1.0));
}
