
var<workgroup> acc: atomic<u32>;

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3u, @builtin(local_invocation_index) li: u32) {
    if (li == 0u) {
        atomicStore(&acc, 0u);
    }
    workgroupBarrier();
    let xy = id.xy * p.step;
    if (xy.x < p.w && xy.y < p.h) {
        let a = textureLoad(frame0, vec2i(xy), 0).rgb;
        let b = textureLoad(frame1, vec2i(xy), 0).rgb;
        let d = abs(dot(a - b, vec3f(0.299, 0.587, 0.114)));
        atomicAdd(&acc, u32(round(d * 255.0)));
    }
    workgroupBarrier();
    if (li == 0u) {
        atomicAdd(&state.sum, atomicLoad(&acc));
    }
}
