// Port of FFmpeg's vf_v360: output pixel -> direction on the sphere -> rotation -> input pixel.
// Projection ids (the same numbering for `input` and `output`):
//  0 equirect   1 cube3x2   2 cube6x1   3 cube1x6   4 eac        5 flat       6 dfisheye
//  7 fisheye    8 stereographic        9 mercator   10 ball       11 hammer    12 sinusoidal
//  13 pannini   14 cylindrical         15 cylindricalea           16 equisolid 17 orthographic
//  18 octahedron                       19 hequirect
// Directions: 0 right (+x), 1 left (-x), 2 up (+y), 3 down (-y), 4 front (+z), 5 back (-z), as FFmpeg's v360.h.

const PI: f32 = 3.14159265358979;
const HALF_PI: f32 = 1.57079632679490;
const SQRT2: f32 = 1.41421356237310;

fn finite(x: f32) -> bool { return abs(x) < 1.0e30; } // false for NaN and inf
fn sgn(x: f32) -> f32 { return select(-1.0, 1.0, x > 0.0); } // FFSIGN
fn asin_c(x: f32) -> f32 { return asin(clamp(x, -1.0, 1.0)); }
fn acos_c(x: f32) -> f32 { return acos(clamp(x, -1.0, 1.0)); }
fn rescale(i: f32, s: f32) -> f32 { return (2.0 * i + 1.0) / s - 1.0; }
fn scale(x: f32, s: f32) -> f32 { return (0.5 * x + 0.5) * (s - 1.0); }

// ---- cubemap helpers -------------------------------------------------------------------------

fn rot_fwd(p: vec2f, rot: i32) -> vec2f { // rotate_cube_face
    if (rot == 1) { return vec2f(-p.y, p.x); }
    if (rot == 2) { return -p; }
    if (rot == 3) { return vec2f(p.y, -p.x); }
    return p;
}
fn rot_inv(p: vec2f, rot: i32) -> vec2f { // rotate_cube_face_inverse
    if (rot == 1) { return vec2f(p.y, -p.x); }
    if (rot == 2) { return -p; }
    if (rot == 3) { return vec2f(-p.y, p.x); }
    return p;
}

// EAC face layout (top row: left front right, bottom row: down back up) as prepare_eac_in.
fn eac_face_of_dir(d: i32) -> i32 {
    var t = array<i32, 6>(2, 0, 5, 3, 1, 4);
    return t[d];
}
fn eac_rot_of_face(f: i32) -> i32 {
    var t = array<i32, 6>(0, 0, 0, 3, 1, 3);
    return t[f];
}

fn cube_to_xyz(uv: vec2f, dir: i32, rot: i32) -> vec3f {
    let p = rot_inv(uv, rot);
    switch (dir) {
        case 0: { return vec3f(1.0, p.y, -p.x); }
        case 1: { return vec3f(-1.0, p.y, p.x); }
        case 2: { return vec3f(p.x, -1.0, p.y); }
        case 3: { return vec3f(p.x, 1.0, -p.y); }
        case 4: { return vec3f(p.x, p.y, 1.0); }
        default: { return vec3f(-p.x, p.y, -1.0); }
    }
}

struct CubeHit { uv: vec2f, dir: i32 };

fn xyz_to_cube(v: vec3f) -> CubeHit {
    let phi = atan2(v.x, v.z);
    let theta = asin_c(v.y);
    var dir = 4;
    var phi_norm = phi;
    if (phi >= -PI / 4.0 && phi < PI / 4.0) {
        dir = 4; phi_norm = phi;
    } else if (phi >= -(HALF_PI + PI / 4.0) && phi < -PI / 4.0) {
        dir = 1; phi_norm = phi + HALF_PI;
    } else if (phi >= PI / 4.0 && phi < HALF_PI + PI / 4.0) {
        dir = 0; phi_norm = phi - HALF_PI;
    } else {
        dir = 5; phi_norm = phi + select(PI, -PI, phi > 0.0);
    }
    let thr = atan(cos(phi_norm));
    if (theta > thr) { dir = 3; } else if (theta < -thr) { dir = 2; }
    var uv = vec2f(0.0);
    switch (dir) {
        case 0: { uv = vec2f(-v.z / v.x, v.y / v.x); }
        case 1: { uv = vec2f(-v.z / v.x, -v.y / v.x); }
        case 2: { uv = vec2f(-v.x / v.y, -v.z / v.y); }
        case 3: { uv = vec2f(v.x / v.y, -v.z / v.y); }
        case 4: { uv = vec2f(v.x / v.z, v.y / v.z); }
        default: { uv = vec2f(v.x / v.z, -v.y / v.z); }
    }
    return CubeHit(uv, dir);
}

// ---- sampling --------------------------------------------------------------------------------

// Where to read the input: p in pixels (integer = pixel centre), rect = inclusive pixel bounds the
// interpolation window is clamped to (a cube face, a fisheye half), wrap 1 = equirect wrap/reflect.
struct Smp { p: vec2f, rect: vec4i, wrap: i32, vis: bool };

fn mk(p: vec2f, W: i32, H: i32) -> Smp { return Smp(p, vec4i(0, 0, W - 1, H - 1), 0, true); }

fn inside(p: vec2f, w: f32, h: f32) -> bool {
    return floor(p.x) >= 0.0 && floor(p.x) < w && floor(p.y) >= 0.0 && floor(p.y) < h;
}

fn fetch(ix: i32, iy: i32, s: Smp, W: i32, H: i32) -> vec4f {
    var x = ix;
    var y = iy;
    if (s.wrap == 1) {
        if (iy < 0 || iy >= H) { x = ix + W / 2; }
        x = ((x % W) + W) % W;
        if (iy < 0) { y = -iy; } else if (iy >= H) { y = 2 * H - 1 - iy; }
        y = clamp(y, 0, H - 1);
    } else {
        x = clamp(ix, s.rect.x, s.rect.z);
        y = clamp(iy, s.rect.y, s.rect.w);
    }
    if (params.ih_flip != 0u) { x = W - 1 - x; }
    if (params.iv_flip != 0u) { y = H - 1 - y; }
    return textureLoad(src, vec2i(x, y), 0);
}

fn cubic_w(t: f32) -> vec4f { // calculate_bicubic_coeffs
    let tt = t * t;
    let ttt = tt * t;
    return vec4f(-t / 3.0 + tt / 2.0 - ttt / 6.0,
                 1.0 - t / 2.0 - tt + ttt / 2.0,
                 t + tt / 2.0 - ttt / 2.0,
                 -t / 6.0 + ttt / 6.0);
}

fn sample_input(s: Smp, W: i32, H: i32) -> vec4f {
    let p = clamp(s.p, vec2f(-1.0e6), vec2f(1.0e6));
    let ui = i32(floor(p.x));
    let vi = i32(floor(p.y));
    let du = p.x - f32(ui);
    let dv = p.y - f32(vi);
    if (params.interp == 0) {
        return fetch(ui + select(0, 1, du >= 0.5), vi + select(0, 1, dv >= 0.5), s, W, H);
    }
    if (params.interp == 1) {
        let a = fetch(ui, vi, s, W, H);
        let b = fetch(ui + 1, vi, s, W, H);
        let c = fetch(ui, vi + 1, s, W, H);
        let d = fetch(ui + 1, vi + 1, s, W, H);
        return mix(mix(a, b, du), mix(c, d, du), dv);
    }
    let wu = cubic_w(du);
    let wv = cubic_w(dv);
    var acc = vec4f(0.0);
    for (var i = 0; i < 4; i++) {
        var row = vec4f(0.0);
        for (var j = 0; j < 4; j++) {
            row += fetch(ui + j - 1, vi + i - 1, s, W, H) * wu[j];
        }
        acc += row * wv[i];
    }
    return clamp(acc, vec4f(0.0), vec4f(1.0));
}

// ---- fields of view --------------------------------------------------------------------------

fn default_fov(proj: i32) -> vec2f {
    if (proj == 5 || proj == 14) { return vec2f(90.0, 45.0); }
    if (proj == 16 || proj == 17 || proj == 8 || proj == 6 || proj == 7) { return vec2f(180.0, 180.0); }
    return vec2f(360.0, 180.0);
}

fn fov_from_dfov(proj: i32, d_fov: f32, w: f32, h: f32) -> vec2f { // fov_from_dfov
    switch (proj) {
        case 0: { return vec2f(d_fov, d_fov * 0.5); }
        case 17: {
            let d = 0.5 * length(vec2f(w, h));
            let l = sin(d_fov * PI / 360.0) / d;
            var r = vec2f(asin_c(w * 0.5 * l), asin_c(h * 0.5 * l)) * 360.0 / PI;
            if (d_fov > 180.0) { r = vec2f(180.0) - r; }
            return r;
        }
        case 16: {
            let d = 0.5 * length(vec2f(w, h));
            let l = d / max(sin(d_fov * PI / 720.0), 1.0e-6);
            return 2.0 * vec2f(asin_c(w * 0.5 / l), asin_c(h * 0.5 / l)) * 360.0 / PI;
        }
        case 8: {
            let d = 0.5 * length(vec2f(w, h));
            let l = d / max(tan(d_fov * PI / 720.0), 1.0e-6);
            return 2.0 * vec2f(atan2(w * 0.5, l), atan2(h * 0.5, l)) * 360.0 / PI;
        }
        case 6: {
            let d = length(vec2f(w * 0.5, h));
            return vec2f(0.5 * w / d * d_fov, h / d * d_fov);
        }
        case 7: {
            let d = length(vec2f(w, h));
            return vec2f(w / d * d_fov, h / d * d_fov);
        }
        default: {
            let da = tan(0.5 * min(d_fov, 359.0) * PI / 180.0);
            let d = length(vec2f(w, h));
            var r = vec2f(atan2(da * w, d), atan2(da * h, d)) * 360.0 / PI;
            if (r.x < 0.0) { r.x += 360.0; }
            if (r.y < 0.0) { r.y += 360.0; }
            return r;
        }
    }
}

// ---- output: pixel -> direction --------------------------------------------------------------

struct OutRes { v: vec3f, ok: bool };

fn out_to_xyz(proj: i32, i: i32, j: i32, w: f32, h: f32, fov: vec2f) -> OutRes {
    let fi = f32(i);
    let fj = f32(j);
    switch (proj) {
        case 0: { // equirect
            let phi = rescale(fi, w) * (fov.x * PI / 360.0);
            let theta = rescale(fj, h) * (fov.y * PI / 360.0);
            return OutRes(vec3f(cos(theta) * sin(phi), sin(theta), cos(theta) * cos(phi)), true);
        }
        case 1, 2, 3: { // cubemaps
            var cols = 3.0;
            var rows = 2.0;
            if (proj == 2) { cols = 6.0; rows = 1.0; }
            if (proj == 3) { cols = 1.0; rows = 6.0; }
            let ew = w / cols;
            let eh = h / rows;
            let uface = i32(floor(fi / ew));
            let vface = i32(floor(fj / eh));
            let face = clamp(uface + i32(cols) * vface, 0, 5);
            let ushift = i32(ceil(ew * f32(uface)));
            let vshift = i32(ceil(eh * f32(vface)));
            let ewi = i32(ceil(ew * f32(uface + 1))) - ushift;
            let ehi = i32(ceil(eh * f32(vface + 1))) - vshift;
            let uv = vec2f(rescale(f32(i - ushift), f32(max(ewi, 1))), rescale(f32(j - vshift), f32(max(ehi, 1))));
            return OutRes(cube_to_xyz(uv, face, 0), true);
        }
        case 4: { // eac
            let pad = 2.0;
            let u_pad = pad / w;
            let v_pad = pad / h;
            var uf = (fi + 0.5) / w;
            var vf = (fj + 0.5) / h;
            uf = 3.0 * (uf - u_pad) / (1.0 - 2.0 * u_pad);
            var u_face = 0;
            if (uf < 0.0) {
                u_face = 0;
                uf -= 0.5;
            } else if (uf >= 3.0) {
                u_face = 2;
                uf -= 2.5;
            } else {
                u_face = i32(floor(uf));
                uf = (uf - floor(uf)) - 0.5;
            }
            let v_face = clamp(i32(floor(vf * 2.0)), 0, 1);
            vf = (vf - v_pad - 0.5 * f32(v_face)) / (0.5 - 2.0 * v_pad) - 0.5;
            if (uf >= -0.5 && uf < 0.5) { uf = tan(HALF_PI * uf); } else { uf = 2.0 * uf; }
            if (vf >= -0.5 && vf < 0.5) { vf = tan(HALF_PI * vf); } else { vf = 2.0 * vf; }
            let face = u_face + 3 * v_face;
            var r = vec3f(0.0, 0.0, 1.0);
            switch (face) {
                case 0: { r = vec3f(-1.0, vf, uf); }
                case 1: { r = vec3f(uf, vf, 1.0); }
                case 2: { r = vec3f(1.0, vf, -uf); }
                case 3: { r = vec3f(-vf, 1.0, -uf); }
                case 4: { r = vec3f(-vf, -uf, -1.0); }
                default: { r = vec3f(-vf, -1.0, uf); }
            }
            return OutRes(r, true);
        }
        case 5: { // flat
            let rx = tan(0.5 * fov.x * PI / 180.0);
            let ry = tan(0.5 * fov.y * PI / 180.0);
            return OutRes(vec3f(rx * rescale(fi, w), ry * rescale(fj, h), 1.0), true);
        }
        case 6: { // dfisheye
            let ew = w * 0.5;
            let right = fi >= ew;
            let ei = select(fi, f32(i32(fi - ew)), right);
            let m = select(-1.0, 1.0, right);
            let uf = (fov.x / 180.0) * rescale(ei, ew);
            let vf = (fov.y / 180.0) * rescale(fj, h);
            let hh = length(vec2f(uf, vf));
            let lh = select(1.0, hh, hh > 0.0);
            let theta = m * HALF_PI * (1.0 - hh);
            return OutRes(vec3f(cos(theta) * m * uf / lh, cos(theta) * vf / lh, sin(theta)), true);
        }
        case 7: { // fisheye
            let uf = (fov.x / 180.0) * rescale(fi, w);
            let vf = (fov.y / 180.0) * rescale(fj, h);
            let phi = atan2(vf, uf);
            let theta = HALF_PI * (1.0 - length(vec2f(uf, vf)));
            return OutRes(vec3f(cos(theta) * cos(phi), cos(theta) * sin(phi), sin(theta)), true);
        }
        case 8: { // stereographic
            let x = rescale(fi, w) * tan(min(fov.x, 359.0) * PI / 720.0);
            let y = rescale(fj, h) * tan(min(fov.y, 359.0) * PI / 720.0);
            let r = length(vec2f(x, y));
            let theta = atan(r) * 2.0;
            if (r > 0.0) { return OutRes(vec3f(x / r * sin(theta), y / r * sin(theta), cos(theta)), true); }
            return OutRes(vec3f(0.0, 0.0, 1.0), true);
        }
        case 9: { // mercator
            let phi = rescale(fi, w) * PI + HALF_PI;
            let y = rescale(fj, h) * PI;
            let e2 = exp(2.0 * y);
            let div = e2 + 1.0;
            let sin_t = 2.0 * exp(y) / div;
            let cos_t = (e2 - 1.0) / div;
            return OutRes(vec3f(-sin_t * cos(phi), cos_t, sin_t * sin(phi)), true);
        }
        case 10: { // ball
            let x = rescale(fi, w);
            let y = rescale(fj, h);
            let l = length(vec2f(x, y));
            if (l > 1.0) { return OutRes(vec3f(0.0, 1.0, 0.0), false); }
            let z = 2.0 * l * sqrt(max(1.0 - l * l, 0.0));
            let d = select(1.0, l, l > 0.0);
            return OutRes(vec3f(z * x / d, z * y / d, 1.0 - 2.0 * l * l), true);
        }
        case 11: { // hammer
            let x = rescale(fi, w);
            let y = rescale(fj, h);
            let zz = 1.0 - x * x * 0.5 - y * y * 0.5;
            if (zz < 0.0) { return OutRes(vec3f(0.0, 0.0, 1.0), false); }
            let z = sqrt(zz);
            let a = SQRT2 * x * z;
            let b = 2.0 * z * z - 1.0;
            let aa = a * a;
            let bb = b * b;
            let ww = sqrt(max(1.0 - 2.0 * y * y * z * z, 0.0));
            let den = max(aa + bb, 1.0e-12);
            return OutRes(vec3f(ww * 2.0 * a * b / den, SQRT2 * y * z, ww * (bb - aa) / den), true);
        }
        case 12: { // sinusoidal
            let theta = rescale(fj, h) * HALF_PI;
            let phi = rescale(fi, w) * PI / max(cos(theta), 1.0e-6);
            return OutRes(vec3f(cos(theta) * sin(phi), sin(theta), cos(theta) * cos(phi)), true);
        }
        case 13: { // pannini
            let uf = rescale(fi, w);
            let vf = rescale(fj, h);
            let d = fov.x;
            let k = uf * uf / ((d + 1.0) * (d + 1.0));
            let dscr = k * k * d * d - (k + 1.0) * (k * d * d - 1.0);
            let clon = (-k * d + sqrt(max(dscr, 0.0))) / (k + 1.0);
            let S = (d + 1.0) / (d + clon);
            let lon = atan2(uf, S * clon);
            let lat = atan2(vf, S);
            return OutRes(vec3f(sin(lon) * cos(lat), sin(lat), cos(lon) * cos(lat)), true);
        }
        case 14: { // cylindrical
            let phi = (PI * fov.x / 360.0) * rescale(fi, w);
            let theta = atan(tan(0.5 * fov.y * PI / 180.0) * rescale(fj, h));
            return OutRes(vec3f(cos(theta) * sin(phi), sin(theta), cos(theta) * cos(phi)), true);
        }
        case 15: { // cylindricalea
            let phi = (fov.x * PI / 360.0) * rescale(fi, w);
            let vf = (fov.y / 180.0) * rescale(fj, h);
            if (abs(vf) > 1.0) { return OutRes(vec3f(0.0, 0.0, 1.0), false); }
            let theta = asin_c(vf);
            return OutRes(vec3f(cos(theta) * sin(phi), sin(theta), cos(theta) * cos(phi)), true);
        }
        case 16: { // equisolid
            let x = rescale(fi, w) * sin(fov.x * PI / 720.0);
            let y = rescale(fj, h) * sin(fov.y * PI / 720.0);
            let r = length(vec2f(x, y));
            if (r > 1.0) { return OutRes(vec3f(0.0, 0.0, 1.0), false); }
            let theta = asin_c(r) * 2.0;
            if (r > 0.0) { return OutRes(vec3f(x / r * sin(theta), y / r * sin(theta), cos(theta)), true); }
            return OutRes(vec3f(0.0, 0.0, 1.0), true);
        }
        case 17: { // orthographic
            let x = rescale(fi, w) * sin(min(fov.x, 180.0) * PI / 360.0);
            let y = rescale(fj, h) * sin(min(fov.y, 180.0) * PI / 360.0);
            let r = length(vec2f(x, y));
            if (r >= 1.0) { return OutRes(vec3f(0.0, 0.0, 1.0), false); }
            return OutRes(vec3f(x, y, cos(asin_c(r))), true);
        }
        case 18: { // octahedron
            let x = rescale(fi, w);
            let y = rescale(fj, h);
            let ax = abs(x);
            let ay = abs(y);
            let z = 1.0 - (ax + ay);
            if (ax + ay > 1.0) { return OutRes(vec3f((1.0 - ay) * sgn(x), (1.0 - ax) * sgn(y), z), true); }
            return OutRes(vec3f(x, y, z), true);
        }
        default: { // 19 hequirect
            let phi = rescale(fi, w) * HALF_PI;
            let theta = rescale(fj, h) * HALF_PI;
            return OutRes(vec3f(cos(theta) * sin(phi), sin(theta), cos(theta) * cos(phi)), true);
        }
    }
}

// ---- input: direction -> pixel ---------------------------------------------------------------

fn in_to_pixel(proj: i32, v: vec3f, W: i32, H: i32, fov: vec2f) -> Smp {
    let w = f32(W);
    let h = f32(H);
    switch (proj) {
        case 0: { // equirect
            let phi = atan2(v.x, v.z) / (fov.x * PI / 360.0);
            let theta = asin_c(v.y) / (fov.y * PI / 360.0);
            var s = mk(vec2f(scale(phi, w), scale(theta, h)), W, H);
            s.wrap = 1;
            // FFmpeg wraps/reflects here and never treats a pixel as outside
            return s;
        }
        case 1, 2, 3: { // cubemaps
            var cols = 3.0;
            var rows = 2.0;
            if (proj == 2) { cols = 6.0; rows = 1.0; }
            if (proj == 3) { cols = 1.0; rows = 6.0; }
            let ew = w / cols;
            let eh = h / rows;
            let hit = xyz_to_cube(v);
            let face = hit.dir;
            let uface = face % i32(cols);
            let vface = face / i32(cols);
            let ushift = i32(ceil(ew * f32(uface)));
            let vshift = i32(ceil(eh * f32(vface)));
            let ewi = max(i32(ceil(ew * f32(uface + 1))) - ushift, 1);
            let ehi = max(i32(ceil(eh * f32(vface + 1))) - vshift, 1);
            let uf = 0.5 * f32(ewi) * (hit.uv.x + 1.0) - 0.5;
            let vf = 0.5 * f32(ehi) * (hit.uv.y + 1.0) - 0.5;
            return Smp(vec2f(f32(ushift) + uf, f32(vshift) + vf),
                       vec4i(ushift, vshift, ushift + ewi - 1, vshift + ehi - 1), 0, true);
        }
        case 4: { // eac
            let pad = 2.0;
            let u_pad = pad / w;
            let v_pad = pad / h;
            let hit = xyz_to_cube(v);
            let face = eac_face_of_dir(hit.dir);
            let uv = rot_fwd(hit.uv, eac_rot_of_face(face));
            let u_face = f32(face % 3);
            let v_face = f32(face / 3);
            var uf = 0.6366197723675814 * atan(uv.x) + 0.5;
            var vf = 0.6366197723675814 * atan(uv.y) + 0.5;
            uf = (uf + u_face) * (1.0 - 2.0 * u_pad) / 3.0 + u_pad;
            vf = vf * (0.5 - 2.0 * v_pad) + v_pad + 0.5 * v_face;
            return mk(vec2f(uf * w - 0.5, vf * h - 0.5), W, H);
        }
        case 5: { // flat
            let theta = acos_c(v.z);
            let r = tan(theta);
            let rr = select(length(vec2f(w, h)), r, abs(r) < 1.0e6);
            let hh = length(v.xy);
            let c = select(rr / hh, 1.0, hh <= 1.0e-6);
            let rx = tan(0.5 * fov.x * PI / 180.0);
            let ry = tan(0.5 * fov.y * PI / 180.0);
            var s = mk(vec2f(scale(v.x * c / rx, w), scale(v.y * c / ry, h)), W, H);
            s.vis = v.z >= 0.0 && inside(s.p, w, h);
            return s;
        }
        case 6: { // dfisheye
            let ew = w * 0.5;
            let hh = length(v.xy);
            let lh = select(1.0, hh, hh > 0.0);
            let theta = acos_c(abs(v.z)) / PI;
            var uf = scale(theta * (v.x / lh) / (fov.x / 360.0), ew);
            let vf = scale(theta * (v.y / lh) / (fov.y / 360.0), h);
            var ushift = 0;
            if (v.z >= 0.0) { ushift = i32(ceil(ew)); } else { uf = ew - uf - 1.0; }
            return Smp(vec2f(f32(ushift) + uf, vf), vec4i(ushift, 0, ushift + i32(ew - 1.0), H - 1), 0, true);
        }
        case 7: { // fisheye
            let hh = length(v.xy);
            let lh = select(1.0, hh, hh > 0.0);
            let phi = atan2(hh, v.z) / PI;
            let uf = v.x / lh * phi / (fov.x / 180.0);
            let vf = v.y / lh * phi / (fov.y / 180.0);
            var s = mk(vec2f(scale(uf * 2.0, w), scale(vf * 2.0, h)), W, H);
            s.vis = -0.5 < uf && uf < 0.5 && -0.5 < vf && vf < 0.5;
            return s;
        }
        case 8: { // stereographic: c = tan(theta/2) / hypot(x, y) = 1 / (1 + z)
            let c = 1.0 / (1.0 + v.z);
            let x = v.x * c / tan(min(fov.x, 359.0) * PI / 720.0);
            let y = v.y * c / tan(min(fov.y, 359.0) * PI / 720.0);
            var s = mk(vec2f(scale(x, w), scale(y, h)), W, H);
            s.vis = finite(x) && finite(y) && inside(s.p, w, h);
            return s;
        }
        case 9: { // mercator
            let yy = clamp(v.y, -0.9999999, 0.9999999);
            let phi = atan2(v.x, v.z) / PI;
            let theta = clamp(log((1.0 + yy) / (1.0 - yy)) / (2.0 * PI), -1.0, 1.0);
            return mk(vec2f(scale(phi, w), scale(theta, h)), W, H);
        }
        case 10: { // ball
            let l = length(v.xy);
            let r = sqrt(max(1.0 - v.z, 0.0)) / SQRT2;
            let d = select(1.0, l, l > 0.0);
            return mk(vec2f(scale(r * v.x / d, w), scale(r * v.y / d, h)), W, H);
        }
        case 11: { // hammer
            let theta = atan2(v.x, v.z);
            let s1 = sqrt(max(1.0 - v.y * v.y, 0.0));
            let z = sqrt(1.0 + s1 * cos(theta * 0.5));
            let x = s1 * sin(theta * 0.5) / z;
            let y = v.y / z;
            return mk(vec2f((x + 1.0) * w / 2.0, (y + 1.0) * h / 2.0), W, H);
        }
        case 12: { // sinusoidal
            let theta = asin_c(v.y);
            let phi = atan2(v.x, v.z) * cos(theta);
            return mk(vec2f(scale(phi / PI, w), scale(theta / HALF_PI, h)), W, H);
        }
        case 13: { // pannini
            let phi = atan2(v.x, v.z);
            let theta = asin_c(v.y);
            let d = fov.x;
            let S = (d + 1.0) / (d + cos(phi));
            var s = mk(vec2f(scale(S * sin(phi), w), scale(S * tan(theta), h)), W, H);
            s.vis = inside(s.p, w, h) && v.z >= 0.0;
            return s;
        }
        case 14: { // cylindrical
            let phi = atan2(v.x, v.z) / (PI * fov.x / 360.0);
            let theta = asin_c(v.y);
            var s = mk(vec2f(scale(phi, w), scale(tan(theta) / tan(0.5 * fov.y * PI / 180.0), h)), W, H);
            s.vis = inside(s.p, w, h) && abs(theta) <= PI * fov.y / 180.0;
            return s;
        }
        case 15: { // cylindricalea
            let phi = atan2(v.x, v.z) / (PI * fov.x / 360.0);
            let theta = asin_c(v.y);
            var s = mk(vec2f(scale(phi, w), scale(sin(theta) / (fov.y / 180.0), h)), W, H);
            s.vis = inside(s.p, w, h) && abs(theta) <= PI * fov.y / 180.0;
            return s;
        }
        case 16: { // equisolid: c = sin(theta/2) / hypot(x, y) = 1 / (2 cos(theta/2))
            let c = 1.0 / (2.0 * sqrt(max((1.0 + v.z) * 0.5, 0.0)));
            let x = v.x * c / sin(min(fov.x, 359.0) * PI / 720.0);
            let y = v.y * c / sin(min(fov.y, 359.0) * PI / 720.0);
            var s = mk(vec2f(scale(x, w), scale(y, h)), W, H);
            s.vis = finite(x) && finite(y) && inside(s.p, w, h);
            return s;
        }
        case 17: { // orthographic: c = sin(theta) / hypot(x, y) = 1
            let x = v.x / sin(min(fov.x, 180.0) * PI / 360.0);
            let y = v.y / sin(min(fov.y, 180.0) * PI / 360.0);
            var s = mk(vec2f(scale(x, w), scale(y, h)), W, H);
            s.vis = v.z >= 0.0 && finite(x) && finite(y) && inside(s.p, w, h);
            return s;
        }
        case 18: { // octahedron
            let div = max(abs(v.x) + abs(v.y) + abs(v.z), 1.0e-12);
            var uf = v.x / div;
            var vf = v.y / div;
            var zf = v.z;
            if (zf < 0.0) {
                zf = vf;
                vf = (1.0 - abs(uf)) * sgn(zf);
                uf = (1.0 - abs(zf)) * sgn(uf);
            }
            return mk(vec2f(scale(uf, w), scale(vf, h)), W, H);
        }
        default: { // 19 hequirect
            let phi = atan2(v.x, v.z) / HALF_PI;
            let theta = asin_c(v.y) / HALF_PI;
            var s = mk(vec2f(scale(phi, w), scale(theta, h)), W, H);
            // FFmpeg clamps here and never treats a pixel as outside
            return s;
        }
    }
}

// ---- rotation (quaternions, as calculate_rotation / rotate) ----------------------------------

fn qmul(a: vec4f, b: vec4f) -> vec4f {
    return vec4f(a.x * b.x - a.y * b.y - a.z * b.z - a.w * b.w,
                 a.y * b.x + a.x * b.y + a.z * b.w - a.w * b.z,
                 a.z * b.x + a.x * b.z + a.w * b.y - a.y * b.w,
                 a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y);
}

fn rotate_dir(v: vec3f) -> vec3f {
    let d2r = PI / 180.0;
    let yh = params.yaw * d2r * 0.5;
    let ph = params.pitch * d2r * 0.5;
    let rh = params.roll * d2r * 0.5;
    var m = array<vec4f, 3>(vec4f(cos(yh), 0.0, sin(yh), 0.0),
                            vec4f(cos(ph), sin(ph), 0.0, 0.0),
                            vec4f(cos(rh), 0.0, 0.0, sin(rh)));
    var orders = array<vec3i, 6>(vec3i(0, 1, 2), vec3i(0, 2, 1), vec3i(1, 0, 2),
                                 vec3i(1, 2, 0), vec3i(2, 0, 1), vec3i(2, 1, 0));
    let o = orders[clamp(params.rorder, 0, 5)];
    let q = qmul(qmul(m[o.x], m[o.y]), m[o.z]);
    let qc = vec4f(q.x, -q.y, -q.z, -q.w);
    let r = qmul(qmul(q, vec4f(0.0, v.x, v.y, v.z)), qc);
    return vec3f(r.y, r.z, r.w);
}

fn norm_safe(v: vec3f) -> vec3f {
    let l = length(v);
    if (!(l > 1.0e-20) || !finite(l)) { return vec3f(0.0, 0.0, 1.0); }
    return v / l;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let W = i32(globals.size.x);
    let H = i32(globals.size.y);
    let w = globals.size.x;
    let h = globals.size.y;
    let pin = clamp(params.input, 0, 19);
    let pout = clamp(params.output, 0, 19);

    var ofov = vec2f(params.h_fov, params.v_fov);
    let odef = default_fov(pout);
    if (ofov.x == 0.0) { ofov.x = odef.x; }
    if (ofov.y == 0.0) { ofov.y = odef.y; }
    if (params.d_fov > 0.0) { ofov = fov_from_dfov(pout, params.d_fov, w, h); }

    var ifov = vec2f(params.ih_fov, params.iv_fov);
    let idef = default_fov(pin);
    if (ifov.x == 0.0) { ifov.x = idef.x; }
    if (ifov.y == 0.0) { ifov.y = idef.y; }
    if (params.id_fov > 0.0) { ifov = fov_from_dfov(pin, params.id_fov, w, h); }

    let res = out_to_xyz(pout, i32(id.x), i32(id.y), w, h, ofov);
    var v = res.v;
    if (!finite(v.x) || !finite(v.y) || !finite(v.z)) { v = vec3f(0.0, 0.0, 1.0); }
    v.x += params.h_offset;
    v.y += params.v_offset;
    v = norm_safe(v);
    v = norm_safe(rotate_dir(v));
    v = v * vec3f(select(1.0, -1.0, params.h_flip != 0u),
                  select(1.0, -1.0, params.v_flip != 0u),
                  select(1.0, -1.0, params.d_flip != 0u));

    let s = in_to_pixel(pin, v, W, H, ifov);
    if (!res.ok || !s.vis || !finite(s.p.x) || !finite(s.p.y)) {
        gpufx_write(id, params.background);
        return;
    }
    gpufx_write(id, sample_input(s, W, H));
}
