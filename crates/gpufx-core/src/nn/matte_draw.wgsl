// Draws the matte (`mw x mh` alpha values) into a one-channel render target of any size: bilinear with
// half-pixel centres, clamped to the edge (`src = (dst + 0.5) * mw / dw - 0.5`). At the model size it is a copy.

struct P {
    mw: u32,
    mh: u32,
    dw: u32,
    dh: u32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> alpha: array<f32>;

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    // one triangle covering the target
    let uv = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4f(uv * 2.0 - 1.0, 0.0, 1.0);
}

fn at(x: u32, y: u32) -> f32 {
    return alpha[y * p.mw + x];
}

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    let sx = clamp(pos.x * f32(p.mw) / f32(p.dw) - 0.5, 0.0, f32(p.mw - 1u));
    let sy = clamp(pos.y * f32(p.mh) / f32(p.dh) - 0.5, 0.0, f32(p.mh - 1u));
    let x0 = u32(sx);
    let y0 = u32(sy);
    let x1 = min(x0 + 1u, p.mw - 1u);
    let y1 = min(y0 + 1u, p.mh - 1u);
    let fx = sx - f32(x0);
    let fy = sy - f32(y0);
    let top = mix(at(x0, y0), at(x1, y0), fx);
    let bot = mix(at(x0, y1), at(x1, y1), fx);
    return vec4f(mix(top, bot, fy), 0.0, 0.0, 1.0);
}
