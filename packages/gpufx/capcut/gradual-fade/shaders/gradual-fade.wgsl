// The first clip splits into red/blue fringes while it dissolves into the second clip.

// Diagonal UV shift (right and up) of the red and blue channels at full split.
const SPLIT: vec2f = vec2f(0.01, -0.01);
// Fringe distance at which the dissolve reaches its full weight.
const FULL_AT: f32 = 0.04;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = params.progress;
    // Exact clips at the ends of the transition.
    if (p <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (p >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }

    // The animation idles for the first and last 15 % and runs linearly in between.
    let drive = clamp((p - 0.15) / 0.7, 0.0, 1.0);
    // Inside that, the split grows between 10 % and 90 %.
    let split = clamp((drive - 0.1) / 0.8, 0.0, 1.0);

    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    let shift = SPLIT * split;
    let fringed = vec3f(
        textureSampleLevel(first, smp, uv + shift, 0.0).r,
        a.g,
        textureSampleLevel(first, smp, uv - shift, 0.0).b);
    let weight = smoothstep(0.0, FULL_AT, length(2.0 * shift));
    let blended = mix(fringed, b, weight);

    // Soft hand-over from the plain first clip in, and to the plain second clip out.
    var col = mix(a, blended, smoothstep(0.0, 0.1, drive));
    col = mix(col, b, smoothstep(0.9, 1.0, drive));
    gpufx_write(id, vec4f(col, 1.0));
}
