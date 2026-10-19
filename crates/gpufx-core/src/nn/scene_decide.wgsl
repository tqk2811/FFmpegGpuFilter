
@compute @workgroup_size(1)
fn main() {
    let mafd = f32(atomicLoad(&state.sum)) / f32(max(p.count, 1u)) * 100.0 / 255.0;
    let score = min(mafd, abs(mafd - state.prev));
    state.prev = mafd;
    let cut = p.threshold > 0.0 && score >= p.threshold;
    let still = mafd < STATIC_MAFD && atomicLoad(&state.tile) <= STATIC_TILE;
    state.cut = select(select(0u, 2u, still), 1u, cut);
}
