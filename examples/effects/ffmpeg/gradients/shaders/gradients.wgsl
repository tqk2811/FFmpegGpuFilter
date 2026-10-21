// Bindings (globals, params, src, smp, out_tex) and gpufx_* helpers come from the prelude.
const PI = 3.14159265;

fn project(origin: vec2f, dest: vec2f, p: vec2f, kind: i32) -> f32 {
    let op = p - origin;
    let od = dest - origin;
    var denom = 1.0;
    var num = 0.0;
    if (kind == 0) {
        denom = dot(od, od);
        num = dot(op, od);
    } else if (kind == 1) {
        denom = length(od);
        num = length(op);
    } else if (kind == 2) {
        denom = 2.0 * PI;
        num = atan2(op.x, op.y) + PI;
    } else if (kind == 3) {
        denom = 2.0 * PI;
        num = (atan2(op.x, op.y) + PI + p.x / max(max(origin.x, dest.x), 1.0)) % (2.0 * PI);
    } else {
        denom = max(abs(od.x), abs(od.y));
        num = max(abs(op.x), abs(op.y));
    }
    return clamp(num / max(denom, 1e-4), 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let base = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let t = f32(globals.time_int) + globals.time_frac;
    let angle = params.speed * params.rate * t;
    let c = cos(angle);
    let s = sin(angle);
    let ctr = globals.size * 0.5;
    let a0 = params.p0 * globals.size - ctr;
    let a1 = params.p1 * globals.size - ctr;
    let o = vec2f(a0.x * c - a0.y * s, a0.x * s + a0.y * c) + ctr;
    let d = vec2f(a1.x * c - a1.y * s, a1.x * s + a1.y * c) + ctr;

    let kind = clamp(params.kind, 0, 4);
    let nb = clamp(params.nb_colors, 2, 8);
    let wrap = kind == 2 || kind == 3;
    let nwrap = nb + select(0, 1, wrap);
    let f = project(o, d, vec2f(id.xy), kind);

    var cols = array<vec4f, 8>(params.c0, params.c1, params.c2, params.c3, params.c4, params.c5, params.c6, params.c7);
    var g = cols[0];
    if (f >= 1.0) {
        g = cols[nb - 1];
    } else if (f > 0.0) {
        let scl = f * f32(nwrap - 1);
        var i = i32(floor(scl));
        var j = i + 1;
        if (i >= nb - 1) { i = nb - 1; j = 0; }
        g = mix(cols[i], cols[j], scl - floor(scl));
    }
    let a = g.a * params.opacity;
    gpufx_write(id, vec4f(mix(base.rgb, g.rgb, a), mix(base.a, 1.0, a)));
}
