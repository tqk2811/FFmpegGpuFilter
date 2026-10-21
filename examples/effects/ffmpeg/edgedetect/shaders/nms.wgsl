// Pass 2: Sobel gradient |gx| + |gy| of the blurred picture, then non-maximum suppression along the
// rounded gradient direction. Kept pixels hold min(magnitude, 255) / 255 (8-bit, as FFmpeg's buffer).
// The gradient is not stored in a texture: it is computed again for the two neighbours.
fn ld(p: vec2i, size: vec2i) -> vec3i {
    return vec3i(round(textureLoad(tmp, clamp(p, vec2i(0), size - 1), 0).rgb * 255.0));
}

fn grad_x(p: vec2i, size: vec2i) -> vec3i {
    return -ld(p + vec2i(-1, -1), size) + ld(p + vec2i(1, -1), size)
        - 2 * ld(p + vec2i(-1, 0), size) + 2 * ld(p + vec2i(1, 0), size)
        - ld(p + vec2i(-1, 1), size) + ld(p + vec2i(1, 1), size);
}

fn grad_y(p: vec2i, size: vec2i) -> vec3i {
    return -ld(p + vec2i(-1, -1), size) + ld(p + vec2i(-1, 1), size)
        - 2 * ld(p + vec2i(0, -1), size) + 2 * ld(p + vec2i(0, 1), size)
        - ld(p + vec2i(1, -1), size) + ld(p + vec2i(1, 1), size);
}

fn is_border(p: vec2i, size: vec2i) -> bool {
    return p.x < 1 || p.y < 1 || p.x >= size.x - 1 || p.y >= size.y - 1;
}

// |gx| + |gy| per channel; 0 on the border (FFmpeg leaves the gradient of the border at 0).
fn magnitude(p: vec2i, size: vec2i) -> vec3i {
    if (is_border(p, size)) { return vec3i(0); }
    return abs(grad_x(p, size)) + abs(grad_y(p, size));
}

// 0 = 45 up, 1 = 45 down, 2 = horizontal, 3 = vertical (get_rounded_direction)
fn direction(gx0: i32, gy0: i32) -> i32 {
    if (gx0 != 0) {
        var gx = gx0;
        var gy = gy0;
        if (gx < 0) {
            gx = -gx;
            gy = -gy;
        }
        let y = gy * 65536;
        let t1 = 27146 * gx;
        let t3 = 158218 * gx;
        if (y > -t3 && y < -t1) { return 0; }
        if (y > -t1 && y < t1) { return 2; }
        if (y > t1 && y < t3) { return 1; }
    }
    return 3;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(tmp));
    let p = vec2i(id.xy);
    if (is_border(p, size)) {
        gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0));
        return;
    }
    let gx = grad_x(p, size);
    let gy = grad_y(p, size);
    let mag = abs(gx) + abs(gy);
    var res = vec3f(0.0);
    for (var k = 0; k < 3; k++) {
        var da = vec2i(0);
        var db = vec2i(0);
        let d = direction(gx[k], gy[k]);
        if (d == 0) {
            da = vec2i(-1, 1);
            db = vec2i(1, -1);
        } else if (d == 1) {
            da = vec2i(-1, -1);
            db = vec2i(1, 1);
        } else if (d == 2) {
            da = vec2i(-1, 0);
            db = vec2i(1, 0);
        } else {
            da = vec2i(0, -1);
            db = vec2i(0, 1);
        }
        let ma = magnitude(p + da, size)[k];
        let mb = magnitude(p + db, size)[k];
        if (mag[k] > ma && mag[k] > mb) {
            res[k] = f32(min(mag[k], 255)) / 255.0;
        }
    }
    gpufx_write(id, vec4f(res, 1.0));
}
