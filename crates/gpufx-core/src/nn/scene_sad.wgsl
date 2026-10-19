
var<workgroup> acc: atomic<u32>;

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3u, @builtin(local_invocation_index) li: u32, @builtin(workgroup_id) wg: vec3u) {
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
        let sum = atomicLoad(&acc);
        atomicAdd(&state.sum, sum);
        // Samples in this tile (fewer on the right and bottom edges): its mean in 1/16 of a level.
        let nx = (p.w + p.step - 1u) / p.step;
        let ny = (p.h + p.step - 1u) / p.step;
        let n = min(16u, nx - wg.x * 16u) * min(16u, ny - wg.y * 16u);
        atomicMax(&state.tile, sum * 16u / max(n, 1u));
    }
}
