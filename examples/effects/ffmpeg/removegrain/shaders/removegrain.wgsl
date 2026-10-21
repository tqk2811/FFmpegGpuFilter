// RemoveGrain modes 0 to 24 on 8-bit levels, per channel (m0 = R, m1 = G, m2 = B).
// a1 a2 a3 / a4 c a5 / a6 a7 a8 are the eight neighbours of the centre c, row by row.
// Port of the C reference functions of FFmpeg's vf_removegrain.c.

fn clip(v: i32, lo: i32, hi: i32) -> i32 {
    if (v < lo) { return lo; }
    if (v > hi) { return hi; }
    return v;
}

fn mode_of(channel: i32) -> i32 {
    if (channel == 0) { return params.m0; }
    if (channel == 1) { return params.m1; }
    return params.m2;
}

fn remove_grain(mode: i32, c: i32, a: array<i32, 8>) -> i32 {
    let a1 = a[0]; let a2 = a[1]; let a3 = a[2]; let a4 = a[3];
    let a5 = a[4]; let a6 = a[5]; let a7 = a[6]; let a8 = a[7];
    // the four lines through the centre
    let ma1 = max(a1, a8); let mi1 = min(a1, a8);
    let ma2 = max(a2, a7); let mi2 = min(a2, a7);
    let ma3 = max(a3, a6); let mi3 = min(a3, a6);
    let ma4 = max(a4, a5); let mi4 = min(a4, a5);

    if (mode == 1) {
        let mi = min(min(min(a1, a2), min(a3, a4)), min(min(a5, a6), min(a7, a8)));
        let ma = max(max(max(a1, a2), max(a3, a4)), max(max(a5, a6), max(a7, a8)));
        return clip(c, mi, ma);
    }
    if (mode >= 2 && mode <= 4) {
        var s = a;
        for (var i = 0; i < 7; i++) {
            for (var j = 0; j < 7 - i; j++) {
                if (s[j] > s[j + 1]) {
                    let t = s[j];
                    s[j] = s[j + 1];
                    s[j + 1] = t;
                }
            }
        }
        // mode 2: 2nd and 7th, mode 3: 3rd and 6th, mode 4: 4th and 5th smallest
        return clip(c, s[mode - 1], s[8 - mode]);
    }
    if (mode == 5) {
        let c1 = abs(c - clip(c, mi1, ma1));
        let c2 = abs(c - clip(c, mi2, ma2));
        let c3 = abs(c - clip(c, mi3, ma3));
        let c4 = abs(c - clip(c, mi4, ma4));
        let mindiff = min(min(c1, c2), min(c3, c4));
        if (mindiff == c4) { return clip(c, mi4, ma4); }
        if (mindiff == c2) { return clip(c, mi2, ma2); }
        if (mindiff == c3) { return clip(c, mi3, ma3); }
        return clip(c, mi1, ma1);
    }
    if (mode >= 6 && mode <= 8) {
        let cli1 = clip(c, mi1, ma1);
        let cli2 = clip(c, mi2, ma2);
        let cli3 = clip(c, mi3, ma3);
        let cli4 = clip(c, mi4, ma4);
        var c1 = 0; var c2 = 0; var c3 = 0; var c4 = 0;
        if (mode == 6) {
            c1 = clip((abs(c - cli1) << 1u) + (ma1 - mi1), 0, 65535);
            c2 = clip((abs(c - cli2) << 1u) + (ma2 - mi2), 0, 65535);
            c3 = clip((abs(c - cli3) << 1u) + (ma3 - mi3), 0, 65535);
            c4 = clip((abs(c - cli4) << 1u) + (ma4 - mi4), 0, 65535);
        } else if (mode == 7) {
            c1 = abs(c - cli1) + (ma1 - mi1);
            c2 = abs(c - cli2) + (ma2 - mi2);
            c3 = abs(c - cli3) + (ma3 - mi3);
            c4 = abs(c - cli4) + (ma4 - mi4);
        } else {
            c1 = clip(abs(c - cli1) + ((ma1 - mi1) << 1u), 0, 65535);
            c2 = clip(abs(c - cli2) + ((ma2 - mi2) << 1u), 0, 65535);
            c3 = clip(abs(c - cli3) + ((ma3 - mi3) << 1u), 0, 65535);
            c4 = clip(abs(c - cli4) + ((ma4 - mi4) << 1u), 0, 65535);
        }
        let mindiff = min(min(c1, c2), min(c3, c4));
        if (mindiff == c4) { return cli4; }
        if (mindiff == c2) { return cli2; }
        if (mindiff == c3) { return cli3; }
        return cli1;
    }
    if (mode == 9) {
        let d1 = ma1 - mi1;
        let d2 = ma2 - mi2;
        let d3 = ma3 - mi3;
        let d4 = ma4 - mi4;
        let mindiff = min(min(d1, d2), min(d3, d4));
        if (mindiff == d4) { return clip(c, mi4, ma4); }
        if (mindiff == d2) { return clip(c, mi2, ma2); }
        if (mindiff == d3) { return clip(c, mi3, ma3); }
        return clip(c, mi1, ma1);
    }
    if (mode == 10) {
        let d1 = abs(c - a1); let d2 = abs(c - a2); let d3 = abs(c - a3); let d4 = abs(c - a4);
        let d5 = abs(c - a5); let d6 = abs(c - a6); let d7 = abs(c - a7); let d8 = abs(c - a8);
        let mindiff = min(min(min(d1, d2), min(d3, d4)), min(min(d5, d6), min(d7, d8)));
        if (mindiff == d7) { return a7; }
        if (mindiff == d8) { return a8; }
        if (mindiff == d6) { return a6; }
        if (mindiff == d2) { return a2; }
        if (mindiff == d3) { return a3; }
        if (mindiff == d1) { return a1; }
        if (mindiff == d5) { return a5; }
        return a4;
    }
    if (mode == 11 || mode == 12) {
        let sum = 4 * c + 2 * (a2 + a4 + a5 + a7) + a1 + a3 + a6 + a8;
        return (sum + 8) >> 4u;
    }
    if (mode == 13 || mode == 14) {
        let d1 = abs(a1 - a8);
        let d2 = abs(a2 - a7);
        let d3 = abs(a3 - a6);
        let mindiff = min(min(d1, d2), d3);
        if (mindiff == d2) { return (a2 + a7 + 1) >> 1u; }
        if (mindiff == d3) { return (a3 + a6 + 1) >> 1u; }
        return (a1 + a8 + 1) >> 1u;
    }
    if (mode == 15 || mode == 16) {
        let d1 = abs(a1 - a8);
        let d2 = abs(a2 - a7);
        let d3 = abs(a3 - a6);
        let mindiff = min(min(d1, d2), d3);
        let average = (2 * (a2 + a7) + a1 + a3 + a6 + a8 + 4) >> 3u;
        if (mindiff == d2) { return clip(average, min(a2, a7), max(a2, a7)); }
        if (mindiff == d3) { return clip(average, min(a3, a6), max(a3, a6)); }
        return clip(average, min(a1, a8), max(a1, a8));
    }
    if (mode == 17) {
        let l = max(max(mi1, mi2), max(mi3, mi4));
        let u = min(min(ma1, ma2), min(ma3, ma4));
        return clip(c, min(l, u), max(l, u));
    }
    if (mode == 18) {
        let d1 = max(abs(c - a1), abs(c - a8));
        let d2 = max(abs(c - a2), abs(c - a7));
        let d3 = max(abs(c - a3), abs(c - a6));
        let d4 = max(abs(c - a4), abs(c - a5));
        let mindiff = min(min(d1, d2), min(d3, d4));
        if (mindiff == d4) { return clip(c, min(a4, a5), max(a4, a5)); }
        if (mindiff == d2) { return clip(c, min(a2, a7), max(a2, a7)); }
        if (mindiff == d3) { return clip(c, min(a3, a6), max(a3, a6)); }
        return clip(c, min(a1, a8), max(a1, a8));
    }
    if (mode == 19) {
        return (a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + 4) >> 3u;
    }
    if (mode == 20) {
        return (a1 + a2 + a3 + a4 + c + a5 + a6 + a7 + a8 + 4) / 9;
    }
    if (mode == 21) {
        let l1l = (a1 + a8) >> 1u; let l2l = (a2 + a7) >> 1u;
        let l3l = (a3 + a6) >> 1u; let l4l = (a4 + a5) >> 1u;
        let l1h = (a1 + a8 + 1) >> 1u; let l2h = (a2 + a7 + 1) >> 1u;
        let l3h = (a3 + a6 + 1) >> 1u; let l4h = (a4 + a5 + 1) >> 1u;
        let mi = min(min(l1l, l2l), min(l3l, l4l));
        let ma = max(max(l1h, l2h), max(l3h, l4h));
        return clip(c, mi, ma);
    }
    if (mode == 22) {
        let l1 = (a1 + a8 + 1) >> 1u; let l2 = (a2 + a7 + 1) >> 1u;
        let l3 = (a3 + a6 + 1) >> 1u; let l4 = (a4 + a5 + 1) >> 1u;
        return clip(c, min(min(l1, l2), min(l3, l4)), max(max(l1, l2), max(l3, l4)));
    }
    if (mode == 23) {
        let ld1 = ma1 - mi1; let ld2 = ma2 - mi2; let ld3 = ma3 - mi3; let ld4 = ma4 - mi4;
        let u = max(max(max(min(c - ma1, ld1), min(c - ma2, ld2)), max(min(c - ma3, ld3), min(c - ma4, ld4))), 0);
        let d = max(max(max(min(mi1 - c, ld1), min(mi2 - c, ld2)), max(min(mi3 - c, ld3), min(mi4 - c, ld4))), 0);
        return c - u + d;
    }
    if (mode == 24) {
        let ld1 = ma1 - mi1; let ld2 = ma2 - mi2; let ld3 = ma3 - mi3; let ld4 = ma4 - mi4;
        let tu1 = c - ma1; let tu2 = c - ma2; let tu3 = c - ma3; let tu4 = c - ma4;
        let u = max(max(max(min(tu1, ld1 - tu1), min(tu2, ld2 - tu2)), max(min(tu3, ld3 - tu3), min(tu4, ld4 - tu4))), 0);
        let td1 = mi1 - c; let td2 = mi2 - c; let td3 = mi3 - c; let td4 = mi4 - c;
        let d = max(max(max(min(td1, ld1 - td1), min(td2, ld2 - td2)), max(min(td3, ld3 - td3), min(td4, ld4 - td4))), 0);
        return c - u + d;
    }
    return c;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let centre = textureLoad(src, p, 0);
    // the first / last row and column are copied; modes 13 and 15 skip odd rows, 14 and 16 even rows
    if (p.x < 1 || p.y < 1 || p.x >= size.x - 1 || p.y >= size.y - 1) {
        gpufx_write(id, centre);
        return;
    }
    let cv = vec3i(round(centre.rgb * 255.0));
    var nb: array<vec3i, 8>;
    for (var j = 0; j < 8; j++) {
        // 0..3 -> a1..a4, 4..7 -> a5..a8 (the centre is skipped)
        let k = select(j, j + 1, j >= 4);
        nb[j] = vec3i(round(textureLoad(src, p + vec2i(k % 3 - 1, k / 3 - 1), 0).rgb * 255.0));
    }
    var res = cv;
    for (var ch = 0; ch < 3; ch++) {
        let m = mode_of(ch);
        if ((m == 13 || m == 15) && (p.y & 1) == 1) { continue; }
        if ((m == 14 || m == 16) && (p.y & 1) == 0) { continue; }
        var a: array<i32, 8>;
        for (var j = 0; j < 8; j++) { a[j] = nb[j][ch]; }
        res[ch] = clamp(remove_grain(m, cv[ch], a), 0, 255);
    }
    gpufx_write(id, vec4f(vec3f(res) / 255.0, centre.a));
}
