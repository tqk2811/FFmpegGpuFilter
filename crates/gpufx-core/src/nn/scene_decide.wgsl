
@compute @workgroup_size(1)
fn main() {
    let mafd = f32(atomicLoad(&state.sum)) / f32(max(p.count, 1u)) * 100.0 / 255.0;
    let score = min(mafd, abs(mafd - state.prev));
    state.prev = mafd;
    state.cut = select(0u, 1u, score >= p.threshold);
}
