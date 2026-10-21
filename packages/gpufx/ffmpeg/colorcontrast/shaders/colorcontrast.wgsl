@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let sum = params.gmw + params.byw + params.rcw;
    if (sum <= 1.1920929e-7) {
        gpufx_write(id, p);
        return;
    }
    let scale = 1.0 / sum;
    let gm = params.gm * 0.5;
    let by = params.by * 0.5;
    let rc = params.rc * 0.5;
    let r = p.r;
    let g = p.g;
    let b = p.b;
    let br = (b + r) * 0.5;
    let gb = (g + b) * 0.5;
    let rg = (r + g) * 0.5;
    let gd = g - br;
    let bd = b - rg;
    let rd = r - gb;

    let g0 = g + gd * gm;
    let b0 = b - gd * gm;
    let r0 = r - gd * gm;
    let g1 = g - bd * by;
    let b1 = b + bd * by;
    let r1 = r - bd * by;
    let g2 = g - rd * rc;
    let b2 = b - rd * rc;
    let r2 = r + rd * rc;

    let n = clamp(vec3f(r0 * params.gmw + r1 * params.byw + r2 * params.rcw,
                        g0 * params.gmw + g1 * params.byw + g2 * params.rcw,
                        b0 * params.gmw + b1 * params.byw + b2 * params.rcw) * scale, vec3f(0.0), vec3f(1.0));
    let li = max(r, max(g, b)) + min(r, min(g, b));
    let lo = max(n.x, max(n.y, n.z)) + min(n.x, min(n.y, n.z)) + 1e-6;
    let lf = li / lo;
    let c = mix(n, n * lf, params.pl);
    gpufx_write(id, vec4f(clamp(c, vec3f(0.0), vec3f(1.0)), p.a));
}
