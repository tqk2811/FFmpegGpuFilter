// out[c][y*r+i][x*r+j] = in[c*r*r + i*r + j][y][x], one invocation per output element.

struct P {
    n: u32,
    oh: u32,
    ow: u32,
    r: u32,
    ih: u32,
    iw: u32,
    in_off: u32,
    out_off: u32,
}

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> src0: array<f32>;
@group(0) @binding(5) var<storage, read_write> dst: array<f32>;

@compute @workgroup_size(256)
fn main(@builtin(workgroup_id) wg: vec3u, @builtin(num_workgroups) nwg: vec3u, @builtin(local_invocation_index) li: u32) {
    let o = (wg.y * nwg.x + wg.x) * 256u + li;
    if (o >= p.n) {
        return;
    }
    let plane = p.oh * p.ow;
    let c = o / plane;
    let oy = (o % plane) / p.ow;
    let ox = o % p.ow;
    let ic = (c * p.r + oy % p.r) * p.r + ox % p.r;
    dst[p.out_off + o] = src0[p.in_off + (ic * p.ih + oy / p.r) * p.iw + ox / p.r];
}
