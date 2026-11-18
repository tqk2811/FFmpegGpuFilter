// The box decoding of a Siamese tracker head (SiamBAN, NanoTrack): per score cell, the object probability
// (softmax of the two class channels, channel 1 the object), the box from the distances to its sides, the size
// and aspect penalty against the previous box, and the score with the cosine window mixed in. Writes 8 values
// per cell at `cell * 8` of dst: windowed score, probability times penalty, probability, 0, x1, y1, x2, y2
// (search crop pixels).

struct P {
    n: u32,
    cls_off: u32,
    loc_off: u32,
    stride: f32,
    center: f32,
    target_w: f32,
    target_h: f32,
    window_influence: f32,
    penalty_k: f32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> cls: array<f32>;
@group(0) @binding(2) var<storage, read> loc: array<f32>;
@group(0) @binding(3) var<storage, read_write> dst: array<f32>;

const PI: f32 = 3.14159265358979;

// A box's size with context, as the crop is sized.
fn context_size(w: f32, h: f32) -> f32 {
    let pad = (w + h) * 0.5;
    return sqrt((w + pad) * (h + pad));
}

fn hanning(i: u32) -> f32 {
    if (p.n < 2u) {
        return 1.0;
    }
    return 0.5 - 0.5 * cos(2.0 * PI * f32(i) / f32(p.n - 1u));
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
    let plane = p.n * p.n;
    let cell = id.x;
    if (cell >= plane) {
        return;
    }
    let gx = cell % p.n;
    let gy = cell / p.n;
    let a = cls[p.cls_off + cell];
    let b = cls[p.cls_off + plane + cell];
    let m = max(a, b);
    let prob = exp(b - m) / (exp(a - m) + exp(b - m));
    let half = f32(p.n / 2u);
    let px = (f32(gx) - half) * p.stride + p.center;
    let py = (f32(gy) - half) * p.stride + p.center;
    let x1 = px - loc[p.loc_off + cell];
    let y1 = py - loc[p.loc_off + plane + cell];
    let x2 = px + loc[p.loc_off + 2u * plane + cell];
    let y2 = py + loc[p.loc_off + 3u * plane + cell];
    let w = max(x2 - x1, 1e-3);
    let h = max(y2 - y1, 1e-3);
    var sc = context_size(w, h) / context_size(p.target_w, p.target_h);
    sc = max(sc, 1.0 / sc);
    var rc = (p.target_w / p.target_h) / (w / h);
    rc = max(rc, 1.0 / rc);
    let penalty = exp(-(rc * sc - 1.0) * p.penalty_k);
    let window = hanning(gx) * hanning(gy);
    let o = cell * 8u;
    dst[o] = penalty * prob * (1.0 - p.window_influence) + window * p.window_influence;
    dst[o + 1u] = penalty * prob;
    dst[o + 2u] = prob;
    dst[o + 3u] = 0.0;
    dst[o + 4u] = x1;
    dst[o + 5u] = y1;
    dst[o + 6u] = x2;
    dst[o + 7u] = y2;
}
