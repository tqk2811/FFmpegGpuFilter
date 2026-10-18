// Brush Portal, pass 2: highlights of the inverted brush composite, the source of the rim glow.

const SPAN: f32 = 2.0;
const FIRST_ENDS: f32 = 1.7;  // the outgoing clip stops feeding the composite here (scene seconds)
const THRESHOLD: f32 = 0.6;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let uv = gpufx_uv(id);
    let m = textureSampleLevel(masks, smp, uv, 0.0).r;
    var under = vec3f(0.0);
    if (t < FIRST_ENDS) { under = textureSampleLevel(first, smp, uv, 0.0).rgb; }
    let shown = mix(under, textureSampleLevel(second, smp, uv, 0.0).rgb, m);
    let inverted = 1.0 - shown;
    let lit = smoothstep(vec3f(THRESHOLD - 0.075 * THRESHOLD), vec3f(THRESHOLD + 0.115), inverted);
    gpufx_write(id, vec4f(pow(lit, vec3f(0.45454544)), 1.0));
}
