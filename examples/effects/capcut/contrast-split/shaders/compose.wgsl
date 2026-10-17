// Contrast Split, pass 1: the first clip jolts forward for two frames, then the second clip drops in shifted up a fifth of the
// height (the first clip still showing below it) and snaps into place.

// Composition clock: progress 0..1 covers one second of keyframes.
const SPAN: f32 = 0.99999;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    // First clip: held at 113.5 % and nudged up and left between 0.267 s and 0.333 s.
    var src_a = uv;
    if (t >= 0.266667 && t < 0.333333) {
        src_a = (uv - vec2f(0.5 - 40.0 / 680.0, 0.5 - 32.0 / 510.0)) / 1.13529412 + 0.5;
    }
    var colour = textureSampleLevel(first, smp, src_a, 0.0).rgb;
    // Second clip from 0.433 s on top, raised by 112 / 510 of the height until 0.5 s.
    if (t >= 0.433333) {
        let lift = select(0.0, 112.0 / 510.0, t < 0.5);
        let src_b = uv + vec2f(0.0, lift);
        if (src_b.y <= 1.0) {
            colour = textureSampleLevel(second, smp, src_b, 0.0).rgb;
        }
    }
    gpufx_write(id, vec4f(colour, 1.0));
}
