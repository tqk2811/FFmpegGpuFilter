// Port of FFmpeg's huesaturation: one 4x4 color matrix (intensity, saturation, hue rotation),
// optionally limited to some colors. Matrices follow FFmpeg's row-vector convention:
// rowm() builds a matrix from its rows and `v * M` is the row vector times the matrix.

const SQRT2: f32 = 1.4142135623730951;

fn rowm(r0: vec4f, r1: vec4f, r2: vec4f, r3: vec4f) -> mat4x4f {
    return transpose(mat4x4f(r0, r1, r2, r3));
}

fn x_rotate(rs: f32, rc: f32) -> mat4x4f {
    return rowm(vec4f(1.0, 0.0, 0.0, 0.0), vec4f(0.0, rc, rs, 0.0), vec4f(0.0, -rs, rc, 0.0), vec4f(0.0, 0.0, 0.0, 1.0));
}

fn y_rotate(rs: f32, rc: f32) -> mat4x4f {
    return rowm(vec4f(rc, 0.0, -rs, 0.0), vec4f(0.0, 1.0, 0.0, 0.0), vec4f(rs, 0.0, rc, 0.0), vec4f(0.0, 0.0, 0.0, 1.0));
}

fn z_rotate(rs: f32, rc: f32) -> mat4x4f {
    return rowm(vec4f(rc, rs, 0.0, 0.0), vec4f(-rs, rc, 0.0, 0.0), vec4f(0.0, 0.0, 1.0, 0.0), vec4f(0.0, 0.0, 0.0, 1.0));
}

fn z_shear(dx: f32, dy: f32) -> mat4x4f {
    return rowm(vec4f(1.0, 0.0, dx, 0.0), vec4f(0.0, 1.0, dy, 0.0), vec4f(0.0, 0.0, 1.0, 0.0), vec4f(0.0, 0.0, 0.0, 1.0));
}

fn saturation_matrix(saturation: f32, rlw: f32, glw: f32, blw: f32) -> mat4x4f {
    let s = 1.0 - saturation;
    return rowm(
        vec4f(s * rlw + saturation, s * rlw, s * rlw, 0.0),
        vec4f(s * glw, s * glw + saturation, s * glw, 0.0),
        vec4f(s * blw, s * blw, s * blw + saturation, 0.0),
        vec4f(0.0, 0.0, 0.0, 1.0));
}

fn build_matrix() -> mat4x4f {
    let i = 1.0 + params.intensity;
    let saturation = 1.0 + params.saturation;
    let rlw = params.rw;
    let glw = params.gw;
    let blw = params.bw;
    var m = rowm(vec4f(i, 0.0, 0.0, 0.0), vec4f(0.0, i, 0.0, 0.0), vec4f(0.0, 0.0, i, 0.0), vec4f(0.0, 0.0, 0.0, 1.0));
    m = m * saturation_matrix(saturation, rlw, glw, blw);

    let xrs = 1.0 / SQRT2;
    let xrc = 1.0 / SQRT2;
    let mag = sqrt(3.0);
    let yrs = -1.0 / mag;
    let yrc = SQRT2 / mag;
    let zrs = sin(radians(params.hue));
    let zrc = cos(radians(params.hue));

    m = m * x_rotate(xrs, xrc);
    m = m * y_rotate(yrs, yrc);
    if (params.lightness != 0u) {
        // FFmpeg's transform_point() overwrites x with y; kept as is.
        let t = vec4f(glw, glw, blw, 1.0) * m;
        let zsx = t.x / t.z;
        let zsy = t.y / t.z;
        m = m * z_shear(zsx, zsy);
        m = m * z_rotate(zrs, zrc);
        m = m * z_shear(-zsx, -zsy);
    } else {
        m = m * z_rotate(zrs, zrc);
    }
    m = m * y_rotate(-yrs, yrc);
    m = m * x_rotate(-xrs, xrc);
    return m;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let m = build_matrix();
    let c = p.rgb;
    let transformed = (vec4f(c, 1.0) * m).rgb;
    let colors = u32(params.colors);
    let all_colors = (colors & 63u) == 63u;
    var o = c;
    if (all_colors && params.strength >= 99.0) {
        o = transformed;
    } else {
        let mx = max(c.x, max(c.y, c.z));
        let mn = min(c.x, min(c.y, c.z));
        var flags = 0u;
        if (c.x == mx) { flags |= 1u; }   // red
        if (c.z == mn) { flags |= 2u; }   // yellow
        if (c.y == mx) { flags |= 4u; }   // green
        if (c.x == mn) { flags |= 8u; }   // cyan
        if (c.z == mx) { flags |= 16u; }  // blue
        if (c.y == mn) { flags |= 32u; }  // magenta
        if ((colors & flags) != 0u) {
            var f = 0.0;
            if ((colors & 1u) != 0u) { f = max(f, c.x - max(c.y, c.z)); }
            if ((colors & 2u) != 0u) { f = max(f, min(c.x, c.y) - c.z); }
            if ((colors & 4u) != 0u) { f = max(f, c.y - max(c.x, c.z)); }
            if ((colors & 8u) != 0u) { f = max(f, min(c.y, c.z) - c.x); }
            if ((colors & 16u) != 0u) { f = max(f, c.z - max(c.x, c.y)); }
            if ((colors & 32u) != 0u) { f = max(f, min(c.x, c.z) - c.y); }
            f = min(f * params.strength, 1.0);
            o = mix(c, transformed, f);
        }
    }
    gpufx_write(id, vec4f(o, p.a));
}
