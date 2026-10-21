// Bindings (globals, params, src, smp, out_tex) and gpufx_* helpers come from the prelude.
// Waveform monitor (FFmpeg's `waveform`, lowpass filter). Every output pixel gathers: it walks the input column
// (mode column) or row (mode row) it stands for and counts the samples whose level lands in its row (or column).
// The walk takes at most `max_samples` samples, spread evenly, so the cost per pixel is bounded.

fn pick(c: vec4f, ch: i32) -> f32 {
    if (ch == 0) { return dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722)); }
    if (ch == 1) { return c.r; }
    if (ch == 2) { return c.g; }
    return c.b;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let base = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let W = i32(globals.size.x);
    let H = i32(globals.size.y);
    let x = i32(id.x);
    let y = i32(id.y);
    let column = params.mode == 0;
    let rgb_mode = params.components == 1;
    let parade = rgb_mode && params.display == 1;

    // along: the axis the level is drawn on (rows for column mode); across: the axis that picks the input line
    let along_size = select(W, H, column);
    let across_size = select(H, W, column);
    let along_px = select(x, y, column);
    var across_px = select(y, x, column);
    var panel = 0;
    if (parade) {
        // three panels side by side (column mode) or stacked (row mode), one per component
        let across_w = across_size / 3;
        panel = min(across_px / max(across_w, 1), 2);
        across_px = (across_px - panel * across_w) * 3 + 1;
    }
    let line = clamp(across_px, 0, across_size - 1);

    let walk = select(W, H, column);
    let n = clamp(min(params.max_samples, walk), 1, 4096);
    var count = vec3f(0.0);
    for (var j = 0; j < n; j++) {
        let kk = min(((2 * j + 1) * walk) / (2 * n), walk - 1);
        let p = select(vec2i(kk, line), vec2i(line, kk), column);
        let c = textureLoad(src, p, 0);
        if (!rgb_mode) {
            let v = clamp(pick(c, 0), 0.0, 1.0);
            // column mode: white at the top; row mode: white on the right
            let bin = select(i32(v * f32(along_size)), i32((1.0 - v) * f32(along_size)), column);
            if (bin == along_px || (bin >= along_size && along_px == along_size - 1)) { count.x += 1.0; }
        } else {
            for (var ch = 0; ch < 3; ch++) {
                if (parade && ch != panel) { continue; }
                let v = clamp(pick(c, ch + 1), 0.0, 1.0);
                let bin = select(i32(v * f32(along_size)), i32((1.0 - v) * f32(along_size)), column);
                if (bin == along_px || (bin >= along_size && along_px == along_size - 1)) { count[ch] += 1.0; }
            }
        }
    }
    // Same brightness as FFmpeg: every hit adds `intensity` on a 256-level scale, whatever the output size and walk length.
    let k = params.intensity * (f32(along_size) / 256.0) * (f32(walk) / f32(n));
    var trace = vec3f(min(count.x * k, 1.0));
    if (rgb_mode) {
        trace = min(count * k, vec3f(1.0));
        if (parade) {
            let m = max(trace[panel], 0.0);
            trace = vec3f(0.0);
            trace[panel] = m;
        }
    }
    gpufx_write(id, vec4f(mix(base.rgb, trace, params.opacity), mix(base.a, 1.0, params.opacity)));
}
