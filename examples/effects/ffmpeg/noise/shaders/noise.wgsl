fn hash(v: u32) -> u32 {
    let s = v * 747796405u + 2891336453u;
    let w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}

// uniform random in [0, 1) from a key and a stream number
fn rnd(key: u32, k: u32) -> f32 {
    return f32(hash(key ^ hash(k + 0x9e3779b9u)) >> 8u) / 16777216.0;
}

fn noise_at(x: u32, y: u32, ch: u32) -> f32 {
    let s = f32(params.strength);
    var frame = 0u;
    if (params.temporal != 0u) { frame = globals.frame; }
    let key = hash(x + hash(y + hash(u32(params.seed) + hash(ch * 31415u + frame * 2654435u))));
    let patt = array<f32, 4>(-1.0, 0.0, 1.0, 0.0)[(x + 2u * y) & 3u];
    var n = 0.0;
    if (params.uniform != 0u) {
        n = rnd(key, 1u) * s - s * 0.5;
        if (params.pattern != 0u) { n = n * 0.5 + patt * s * 0.25; }
    } else {
        let u1 = 1.0 - rnd(key, 1u);
        let u2 = rnd(key, 2u);
        n = sqrt(-2.0 * log(u1)) * cos(6.2831853 * u2) * s / 1.7320508;
        if (params.pattern != 0u) { n = n * 0.5 + patt * s * 0.35; }
        n = clamp(n, -128.0, 127.0);
    }
    return n / 255.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureLoad(src, vec2i(id.xy), 0);
    var n = vec3f(noise_at(id.x, id.y, 0u));
    if (params.mono == 0u) {
        n = vec3f(n.x, noise_at(id.x, id.y, 1u), noise_at(id.x, id.y, 2u));
    }
    gpufx_write(id, vec4f(c.rgb + n, c.a));
}
