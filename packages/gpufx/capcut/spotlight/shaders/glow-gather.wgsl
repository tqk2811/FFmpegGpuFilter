// Spotlight glow, first step: take the beam down to a quarter-size picture in linear light.

const SPAN: f32 = 1.5999;
// Comp time at which the beam stops showing the second clip and starts showing the first.
const SWAP_AT: f32 = 0.8;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// At the ends the last pass shows the plain clips, so the passes before it have nothing to do.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0; }

fn cells() -> vec2f { return max(floor(globals.size * 0.25), vec2f(1.0)); }

const GLOW_GAMMA: f32 = 2.2222;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let n = cells();
    let cell = vec2f(id.xy);
    if (cell.y >= n.y || cell.x >= 2.0 * n.x) { return; }
    // Right of the small picture: the screen sum of the rounds starts empty.
    if (cell.x >= n.x) { gpufx_write(id, vec4f(0.0)); return; }
    let c = max(textureSampleLevel(beam, smp, (cell + 0.5) / n, 0.0), vec4f(0.0));
    gpufx_write(id, vec4f(pow(c.rgb, vec3f(GLOW_GAMMA)), 1.0));
}
