// Port of FFmpeg's xfade (libavfilter/vf_xfade.c): every transition of its XFadeTransitions
// enum, numbered like FFmpeg (-1 = custom, 0 = fade, 1 = wipeleft, ... 57 = revealdown).
// FFmpeg's progress runs 1 -> 0 over the transition; P = 1 - progress is that value.
// The pixel math is FFmpeg's, on normalized floats (the integer truncations of the original
// are kept where they decide the shape), run on the RGBA channels.
// progress 0 and 1 are forced to exactly the first and the second clip.

fn ldA(x: i32, y: i32) -> vec4f { return textureLoad(first, vec2i(x, y), 0); }
fn ldB(x: i32, y: i32) -> vec4f { return textureLoad(second, vec2i(x, y), 0); }

// FFmpeg's mix(): m is the weight of the FIRST argument.
fn mixc(a: vec4f, b: vec4f, m: f32) -> vec4f { return a * m + b * (1.0 - m); }

fn sstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn frand(x: f32, y: f32) -> f32 {
    let r = sin(x * 12.9898 + y * 78.233) * 43758.545;
    return r - floor(r);
}

fn wrap(v: i32, n: i32) -> i32 {
    return v % n + n * select(0, 1, v < 0);
}

// Slide (mode 0), cover (1) and reveal (2) along x (axis 0) or y (axis 1).
fn shift(x: i32, y: i32, n: i32, z: i32, axis: i32, mode: i32) -> vec4f {
    let pos = select(x, y, axis == 1);
    let zp = z + pos;
    let zz = wrap(zp, n);
    let inside = zp >= 0 && zp < n;
    let xz = select(zz, x, axis == 1);
    let yz = select(y, zz, axis == 1);
    if (mode == 0) {
        return select(ldA(xz, yz), ldB(xz, yz), inside);
    } else if (mode == 1) {
        return select(ldA(x, y), ldB(xz, yz), inside);
    }
    return select(ldA(xz, yz), ldB(x, y), inside);
}

// circleopen / vertopen / horzopen weight the first clip by the smoothstep (first_is_a),
// the "close" variants weight the second clip.
fn open_close(a: vec4f, b: vec4f, smooth_v: f32, first_is_a: bool) -> vec4f {
    let s = sstep(0.0, 1.0, smooth_v);
    return select(mixc(b, a, s), mixc(a, b, s), first_is_a);
}

fn yuv(c: vec4f) -> vec3f {
    let y = dot(c.rgb, vec3f(0.299, 0.587, 0.114));
    return vec3f(y, 0.5 + (c.b - y) * 0.564, 0.5 + (c.r - y) * 0.713);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let x = i32(id.x);
    let y = i32(id.y);
    let a = ldA(x, y);
    let b = ldB(x, y);
    let prog = clamp(params.progress, 0.0, 1.0);
    if (prog <= 0.0) { gpufx_write(id, a); return; }
    if (prog >= 1.0) { gpufx_write(id, b); return; }
    let P = 1.0 - prog;
    let W = i32(globals.size.x);
    let H = i32(globals.size.y);
    let fw = f32(W);
    let fh = f32(H);
    let fx = f32(x);
    let fy = f32(y);
    let cx = W / 2;
    let cy = H / 2;
    var res = a;
    switch (params.transition) {
        case -1: { // custom
            let a8 = a.rgb * 255.0;
            let b8 = b.rgb * 255.0;
            let c = vec3f(gpufx_expr_expr(fx, fy, fw, fh, P, a8.r, b8.r, 0.0),
                          gpufx_expr_expr(fx, fy, fw, fh, P, a8.g, b8.g, 1.0),
                          gpufx_expr_expr(fx, fy, fw, fh, P, a8.b, b8.b, 2.0));
            res = vec4f(clamp(c, vec3f(0.0), vec3f(255.0)) / 255.0, mix(a.a, b.a, prog));
        }
        case 0: { // fade
            res = mixc(a, b, P);
        }
        case 1: { // wipeleft
            res = select(a, b, x > i32(fw * P));
        }
        case 2: { // wiperight
            res = select(b, a, x > i32(fw * (1.0 - P)));
        }
        case 3: { // wipeup
            res = select(a, b, y > i32(fh * P));
        }
        case 4: { // wipedown
            res = select(b, a, y > i32(fh * (1.0 - P)));
        }
        case 5: { res = shift(x, y, W, i32(-P * fw), 0, 0); } // slideleft
        case 6: { res = shift(x, y, W, i32(P * fw), 0, 0); } // slideright
        case 7: { res = shift(x, y, H, i32(-P * fh), 1, 0); } // slideup
        case 8: { res = shift(x, y, H, i32(P * fh), 1, 0); } // slidedown
        case 9: { // circlecrop
            let z = pow(2.0 * abs(P - 0.5), 3.0) * length(vec2f(f32(cx), f32(cy)));
            let dist = length(vec2f(f32(x - cx), f32(y - cy)));
            let v = select(a, b, P < 0.5);
            // <= (FFmpeg: <) keeps the full frame at both ends.
            res = select(vec4f(0.0, 0.0, 0.0, 1.0), v, dist <= z);
        }
        case 10: { // rectcrop
            let s = abs(P - 0.5);
            let inside = abs(f32(x - cx)) <= s * fw && abs(f32(y - cy)) <= s * fh;
            let v = select(a, b, P < 0.5);
            res = select(vec4f(0.0, 0.0, 0.0, 1.0), v, inside);
        }
        case 11: { // distance
            let d = length(yuv(a) - yuv(b));
            let near = d <= P;
            res = mixc(select(b, a, near), b, P);
        }
        case 12, 13: { // fadeblack, fadewhite
            let bg = select(vec4f(0.0, 0.0, 0.0, 1.0), vec4f(1.0), params.transition == 13);
            let phase = 0.2;
            res = mixc(mixc(a, bg, sstep(1.0 - phase, 1.0, P)),
                       mixc(bg, b, sstep(phase, 1.0, P)), P);
        }
        case 14: { // radial
            // FFmpeg turns by 2.5 pi; 2 * (pi + 1) shows the second clip completely at the end.
            let sweep = 2.0 * (3.14159265 + 1.0);
            let sm = atan2(f32(x - cx), f32(y - cy)) - (P - 0.5) * sweep;
            res = mixc(b, a, sstep(0.0, 1.0, sm));
        }
        case 15: { res = mixc(b, a, sstep(0.0, 1.0, 1.0 + fx / fw - P * 2.0)); } // smoothleft
        case 16: { res = mixc(b, a, sstep(0.0, 1.0, 1.0 + (fw - 1.0 - fx) / fw - P * 2.0)); } // smoothright
        case 17: { res = mixc(b, a, sstep(0.0, 1.0, 1.0 + fy / fh - P * 2.0)); } // smoothup
        case 18: { res = mixc(b, a, sstep(0.0, 1.0, 1.0 + (fh - 1.0 - fy) / fh - P * 2.0)); } // smoothdown
        case 19: { // circleopen
            let z = length(vec2f(f32(cx), f32(cy)));
            let p = (P - 0.5) * 3.0;
            res = open_close(a, b, length(vec2f(f32(x - cx), f32(y - cy))) / z + p, true);
        }
        case 20: { // circleclose
            let z = length(vec2f(f32(cx), f32(cy)));
            let p = (1.0 - P - 0.5) * 3.0;
            res = open_close(a, b, length(vec2f(f32(x - cx), f32(y - cy))) / z + p, false);
        }
        case 21: { // vertopen
            let w2 = fw / 2.0;
            res = open_close(a, b, 2.0 - abs((fx - w2) / w2) - P * 2.0, false);
        }
        case 22: { // vertclose
            let w2 = fw / 2.0;
            res = open_close(a, b, 1.0 + abs((fx - w2) / w2) - P * 2.0, false);
        }
        case 23: { // horzopen
            let h2 = fh / 2.0;
            res = open_close(a, b, 2.0 - abs((fy - h2) / h2) - P * 2.0, false);
        }
        case 24: { // horzclose
            let h2 = fh / 2.0;
            res = open_close(a, b, 1.0 + abs((fy - h2) / h2) - P * 2.0, false);
        }
        case 25: { // dissolve
            let sm = frand(fx, fy) * 2.0 + P * 2.0 - 1.5;
            res = select(b, a, sm >= 0.5);
        }
        case 26: { // pixelize
            let d = min(P, 1.0 - P);
            let dist = ceil(d * 50.0) / 50.0;
            let sq = max(2.0 * dist * f32(min(W, H)) / 20.0, 1e-6);
            var sx = x;
            var sy = y;
            if (dist > 0.0) {
                sx = i32(min((floor(fx / sq) + 0.5) * sq, fw - 1.0));
                sy = i32(min((floor(fy / sq) + 0.5) * sq, fh - 1.0));
            }
            res = mixc(ldA(sx, sy), ldB(sx, sy), P);
        }
        case 27: { res = mixc(b, a, sstep(0.0, 1.0, 1.0 + fx / fw * fy / fh - P * 2.0)); } // diagtl
        case 28: { res = mixc(b, a, sstep(0.0, 1.0, 1.0 + (fw - 1.0 - fx) / fw * fy / fh - P * 2.0)); } // diagtr
        case 29: { res = mixc(b, a, sstep(0.0, 1.0, 1.0 + fx / fw * (fh - 1.0 - fy) / fh - P * 2.0)); } // diagbl
        case 30: { res = mixc(b, a, sstep(0.0, 1.0, 1.0 + (fw - 1.0 - fx) / fw * (fh - 1.0 - fy) / fh - P * 2.0)); } // diagbr
        case 31, 32, 33, 34: { // hlslice, hrslice, vuslice, vdslice
            let t = params.transition;
            var s: f32;
            var n: f32;
            if (t == 31) { s = fx / fw; n = 10.0 * fx / fw; }
            else if (t == 32) { s = (fw - 1.0 - fx) / fw; n = 10.0 * s; }
            else if (t == 33) { s = fy / fh; n = 10.0 * fy / fh; }
            else { s = (fh - 1.0 - fy) / fh; n = 10.0 * s; }
            let sm = sstep(-0.5, 0.0, s - P * 1.5);
            let ss = select(1.0, 0.0, sm <= n - floor(n));
            res = mixc(b, a, ss);
        }
        case 35: { // hblur: a box of 1 + W/2 * k taps to the right of the pixel, at most W/2 + 1
            let k = select((1.0 - P) * 2.0, P * 2.0, P <= 0.5);
            let size = 1 + i32(f32(W / 2) * k);
            let x1 = min(x + size, W);
            var sum_a = vec4f(0.0);
            var sum_b = vec4f(0.0);
            for (var i = x; i < x1; i = i + 1) {
                sum_a += ldA(i, y);
                sum_b += ldB(i, y);
            }
            let cnt = f32(x1 - x);
            res = mixc(sum_a / cnt, sum_b / cnt, P);
        }
        case 36: { // fadegrays: dip to the luma of each clip
            let luma = vec3f(0.299, 0.587, 0.114);
            let bg_a = vec4f(vec3f(dot(a.rgb, luma)), a.a);
            let bg_b = vec4f(vec3f(dot(b.rgb, luma)), b.a);
            let phase = 0.2;
            res = mixc(mixc(a, bg_a, sstep(1.0 - phase, 1.0, P)),
                       mixc(bg_b, b, sstep(phase, 1.0, P)), P);
        }
        case 37: { // wipetl
            res = select(b, a, y <= i32(fh * P) && x <= i32(fw * P));
        }
        case 38: { // wipetr
            res = select(b, a, y <= i32(fh * P) && x > i32(fw * (1.0 - P)));
        }
        case 39: { // wipebl
            res = select(b, a, y > i32(fh * (1.0 - P)) && x <= i32(fw * P));
        }
        case 40: { // wipebr
            res = select(b, a, y > i32(fh * (1.0 - P)) && x > i32(fw * (1.0 - P)));
        }
        case 41, 42: { // squeezeh, squeezev
            let vertical = params.transition == 42;
            let pos = select(fy, fx, vertical);
            let len = select(fh, fw, vertical);
            // (len - 1) instead of FFmpeg's len makes progress 0 the first clip pixel for pixel.
            let z = 0.5 + (pos / max(len - 1.0, 1.0) - 0.5) / P;
            if (z < 0.0 || z > 1.0) {
                res = b;
            } else {
                let src = i32(round(z * (len - 1.0)));
                res = select(ldA(x, src), ldA(src, y), vertical);
            }
        }
        case 43: { // zoomin
            let zf = sstep(0.5, 1.0, P);
            let u = 0.5 + (fx / fw - 0.5) * zf;
            let v = 0.5 + (fy / fh - 0.5) * zf;
            let iu = clamp(i32(ceil(u * (fw - 1.0))), 0, W - 1);
            let iv = clamp(i32(ceil(v * (fh - 1.0))), 0, H - 1);
            res = mixc(ldA(iu, iv), b, sstep(0.0, 0.5, P));
        }
        case 44, 45: { // fadefast, fadeslow
            let diff = abs(a - b);
            let e = select(1.0 + log(1.0 + diff), 1.0 + log(2.0 - diff), params.transition == 45);
            let w = pow(vec4f(P), e);
            res = a * w + b * (vec4f(1.0) - w);
        }
        case 46, 47, 48, 49: { // hlwind, hrwind, vuwind, vdwind
            let t = params.transition;
            var f: f32;
            var r: f32;
            if (t < 48) {
                r = frand(0.0, fy);
                f = fx / fw;
            } else {
                r = frand(fx, 0.0);
                f = fy / fh;
            }
            if (t == 46 || t == 48) { f = 1.0 - f; }
            let tt = clamp((f * (1.0 - 0.2) + 0.2 * r - (1.0 - P) * (1.0 + 0.2)) / -0.2, 0.0, 1.0);
            res = mixc(b, a, tt * tt * (3.0 - 2.0 * tt));
        }
        case 50: { res = shift(x, y, W, i32(-P * fw), 0, 1); } // coverleft
        case 51: { res = shift(x, y, W, i32(P * fw), 0, 1); } // coverright
        case 52: { res = shift(x, y, H, i32(-P * fh), 1, 1); } // coverup
        case 53: { res = shift(x, y, H, i32(P * fh), 1, 1); } // coverdown
        case 54: { res = shift(x, y, W, i32(-P * fw), 0, 2); } // revealleft
        case 55: { res = shift(x, y, W, i32(P * fw), 0, 2); } // revealright
        case 56: { res = shift(x, y, H, i32(-P * fh), 1, 2); } // revealup
        case 57: { res = shift(x, y, H, i32(P * fh), 1, 2); } // revealdown
        default: { res = mixc(a, b, P); }
    }
    gpufx_write(id, res);
}
