//! Super resolution driven by the `io.json` of a `super_resolution` package (Real-ESRGAN): an RGBA frame in, the
//! frame `scale` times larger out, all on the GPU.
//!
//! The frame runs in tiles of one size (one [`NnPlan`]), so that a 1080p or 4K frame fits the storage buffer
//! limits (a 64 channel tensor of a 1080p frame is ~530 MB). The result is the same as running the whole frame at
//! once (the CPU reference `gpufx-nnconv frames::upscale`: the frame padded by `tile_pad` with `pad_mode`) up to
//! float noise: a tile reads [`context`] input pixels around the part of the output it writes, at least as far
//! as any output pixel can see through the graph, so the zero padding of the convolutions at the tile border
//! never reaches what is kept. At the frame border a tile instead ends exactly where the padded frame ends,
//! `tile_pad` pixels out, as the whole frame run does.
//!
//! Per tile: the tile's pixels (padding outside the frame) become 3 channel planes of the model input mapped to
//! `range`, the graph runs, and the output pixels the tile owns are clamped to `output_clamp` and written to an
//! rgba8unorm storage texture. The frames are texture views as in [`super::FrameInterp`]; [`FrameUpscale::upscale`]
//! uploads CPU images for tools and tests.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;

use super::kernels::{compute_pipeline, storage_entry, uniform_entry, PARAM_SLOT};
use super::model::{OpKind, ResizeMode};
use super::plan::{infer_shapes, read_buffer};
use super::{NnModel, NnPlan, Precision};
use crate::runtime::Image;
use crate::Error;

/// Default bytes of the largest tensor of a tile when the device allows more: tiles of ~1M input pixels for the
/// 64 channel Real-ESRGAN models (the tensor buffers of a plan then take about 3 times this).
pub const DEFAULT_TENSOR_BYTES: u64 = 256 << 20;

/// How [`FrameUpscale`] tiles a frame, and the precision [`FrameUpscale::open`] loads the model with.
#[derive(Debug, Clone, Copy)]
pub struct UpscaleOptions {
    /// Largest tile side in input pixels, without the context around it; `None` picks the fewest tiles whose
    /// tensors fit the limits.
    pub tile: Option<u32>,
    /// Bytes one tensor of a tile may take; `None` is the device's storage buffer limits, at most
    /// [`DEFAULT_TENSOR_BYTES`].
    pub max_tensor_bytes: Option<u64>,
    /// [`Precision::Auto`] by default (f16 convolutions where the device has them); [`Precision::F32`] forces f32.
    pub precision: Precision,
}

impl Default for UpscaleOptions {
    fn default() -> Self {
        UpscaleOptions { tile: None, max_tensor_bytes: None, precision: Precision::Auto }
    }
}

/// What `io.json` says about a `super_resolution` model.
#[derive(Debug, Clone)]
struct SrIo {
    input: String,
    output: String,
    scale: u32,
    tile_pad: u32,
    replicate: bool,
    range: [f32; 2],
    clamp: [f32; 2],
}

impl SrIo {
    fn parse(io: &serde_json::Value) -> Result<Self, Error> {
        let bad = |what: &str| Error::Package(format!("io.json: {what}"));
        if io["kind"] != "super_resolution" {
            return Err(bad("kind is not \"super_resolution\""));
        }
        if io.get("color").and_then(|c| c.as_str()).is_some_and(|c| c != "rgb") {
            return Err(bad("only color \"rgb\" is supported"));
        }
        let replicate = match io.get("pad_mode").and_then(|c| c.as_str()) {
            None => true,
            Some("reflect") => false,
            Some(m) => return Err(bad(&format!("pad_mode \"{m}\" is not supported (reflect, or none for the edge pixel)"))),
        };
        if io.get("pad_multiple").and_then(|v| v.as_u64()).is_some_and(|m| m > 1) {
            return Err(bad("pad_multiple above 1 is not supported for super_resolution"));
        }
        let pair = |k: &str, d: [f32; 2]| -> Result<[f32; 2], Error> {
            match io.get(k) {
                None | Some(serde_json::Value::Null) => Ok(d),
                Some(v) => match (v[0].as_f64(), v[1].as_f64()) {
                    (Some(a), Some(b)) if b > a => Ok([a as f32, b as f32]),
                    _ => Err(bad(&format!("{k} must be [low, high]"))),
                },
            }
        };
        let range = pair("range", [0.0, 1.0])?;
        let scale = io["scale"].as_u64().filter(|s| (1..=16).contains(s)).ok_or_else(|| bad("scale must be an integer in 1..=16"))?;
        Ok(SrIo {
            input: io["inputs"]["image"].as_str().map(String::from).ok_or_else(|| bad("no inputs.image"))?,
            output: io["output"].as_str().map(String::from).ok_or_else(|| bad("no output"))?,
            scale: scale as u32,
            tile_pad: io["tile_pad"].as_u64().unwrap_or(0).min(1024) as u32,
            replicate,
            range,
            clamp: pair("output_clamp", range)?,
        })
    }
}

/// Input pixels on each side that an output pixel of the graph can depend on (rounded up), and the scale of the
/// output relative to the input, and the smallest scale of any tensor on the way (below 1 after a strided
/// convolution or a downscale). Fails for graphs whose output is not a local function of the input at a fixed
/// scale (warps, resizes to a fixed size).
pub(crate) fn context(m: &NnModel, input: &str, output: &str) -> Result<(u32, f64, f64), Error> {
    let unsupported = |op: &str, why: &str| Error::Unsupported(format!("op {op}: {why}, the frame cannot be run in tiles"));
    // per tensor: scale relative to the input, radius in input pixels
    let mut t: HashMap<&str, (f64, f64)> = HashMap::new();
    t.insert(input, (1.0, 0.0));
    let mut min_scale = 1.0f64;
    for op in &m.model.ops {
        let ins: Vec<(f64, f64)> = op.inputs.iter().filter_map(|n| t.get(n.as_str()).copied()).collect();
        if ins.len() != op.inputs.len() || ins.is_empty() {
            // a tensor that does not come from the image (another model input)
            return Err(unsupported(&op.name, "an input does not come from the image"));
        }
        let s = ins[0].0;
        let r = ins.iter().map(|x| x.1).fold(0.0, f64::max);
        if ins.iter().any(|x| (x.0 - s).abs() > 1e-9) && !matches!(op.kind, OpKind::Warp) {
            return Err(unsupported(&op.name, "inputs at different scales"));
        }
        let out = match &op.kind {
            OpKind::Conv2d(c) => {
                let ext = (0..2)
                    .map(|a| {
                        let span = c.dilation[a] * (c.kernel[a] - 1);
                        (c.pad[a].max(span.saturating_sub(c.pad[a])) + c.stride[a] - 1) as f64
                    })
                    .fold(0.0, f64::max);
                let st = c.stride[0].min(c.stride[1]) as f64;
                (s / st, r + ext / s)
            }
            OpKind::Deconv2d(c) => {
                let ext = (0..2).map(|a| ((c.dilation[a] * (c.kernel[a] - 1) + c.pad[a]) / c.stride[a] + 1) as f64).fold(0.0, f64::max);
                (s * c.stride[0].max(c.stride[1]) as f64, r + ext / s)
            }
            OpKind::Resize { mode, scale, size, .. } => {
                let Some([sy, sx]) = scale.filter(|_| size.is_none()) else {
                    return Err(unsupported(&op.name, "resize to a fixed size"));
                };
                if sy != sx {
                    return Err(unsupported(&op.name, "resize with different scales per axis"));
                }
                let taps = match mode {
                    ResizeMode::Nearest => 1.0,
                    ResizeMode::Bilinear => 2.0,
                    ResizeMode::Bicubic => 3.0,
                };
                let so = s * sx as f64;
                (so, r + taps / s + 1.0 / so)
            }
            OpKind::PixelShuffle(f) => (s * *f as f64, r + 1.0 / s),
            OpKind::Warp => return Err(unsupported(&op.name, "warp")),
            _ => (s, r),
        };
        min_scale = min_scale.min(out.0);
        t.insert(&op.output, out);
    }
    let (s, r) = *t.get(output).ok_or_else(|| Error::Package(format!("output \"{output}\" does not come from the image")))?;
    Ok((r.ceil() as u32, s, min_scale))
}

/// One axis of the tile layout: the tile size `t` (input pixels, context included) and per tile its start in
/// frame pixels (negative in the padding) and the frame pixels `[lo, hi)` it writes.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Axis {
    t: u32,
    tiles: Vec<(i32, u32, u32)>,
}

/// `n` tiles over `w` pixels with `ctx` pixels of context, the frame padded by `pad`. A tile starts `ctx`
/// before the pixels it writes, moved inside the padded frame `[-pad, w + pad)`: there it ends with the
/// padded frame, as a whole frame run does.
fn axis(w: u32, n: u32, ctx: u32, pad: u32) -> Axis {
    let full = w + 2 * pad;
    if n <= 1 {
        return Axis { t: full, tiles: vec![(-(pad as i32), 0, w)] };
    }
    let t = (w.div_ceil(n) + 2 * ctx).min(full);
    let tiles = (0..n as u64)
        .map(|k| {
            let lo = (k * w as u64 / n as u64) as u32;
            let hi = ((k + 1) * w as u64 / n as u64) as u32;
            let start = (lo as i64 - ctx as i64).clamp(-(pad as i64), (w + pad) as i64 - t as i64);
            (start as i32, lo, hi)
        })
        .collect();
    Axis { t, tiles }
}

/// The tile counts `(columns, rows)` for a `w x h` frame: with `tile`, tiles of at most that side; otherwise
/// the fewest input pixels run (context included) with tiles of at most `max_px` pixels, fewer tiles on a tie.
fn tile_counts(w: u32, h: u32, ctx: u32, pad: u32, max_px: u64, tile: Option<u32>) -> Option<(u32, u32)> {
    // the tile size of `axis`, without laying the tiles out
    let size = |len: u32, n: u32| -> u64 {
        let full = (len + 2 * pad) as u64;
        if n <= 1 {
            full
        } else {
            (len.div_ceil(n) as u64 + 2 * ctx as u64).min(full)
        }
    };
    if let Some(t) = tile {
        let t = t.max(1);
        let (nx, ny) = (w.div_ceil(t), h.div_ceil(t));
        return (size(w, nx) * size(h, ny) <= max_px).then_some((nx, ny));
    }
    let mut best: Option<(u64, u32, u32)> = None;
    for nx in 1..=w {
        let tx = size(w, nx);
        if tx > max_px {
            continue;
        }
        // the fewest rows whose tiles fit (more rows only cost more once they fit)
        let max_ty = max_px / tx;
        let ny = if size(h, 1) <= max_ty {
            1
        } else if max_ty > 2 * ctx as u64 {
            (h as u64).div_ceil(max_ty - 2 * ctx as u64).max(2)
        } else {
            continue;
        };
        if ny > h as u64 {
            continue;
        }
        let ny = ny as u32;
        let ty = size(h, ny);
        debug_assert!(tx * ty <= max_px);
        let cost = (nx as u64 * ny as u64) * tx * ty;
        if best.is_none_or(|(c, bx, by)| cost < c || (cost == c && nx * ny < bx * by)) {
            best = Some((cost, nx, ny));
        }
        if tx == size(w, w) {
            // more columns no longer shrink the tile
            break;
        }
    }
    best.map(|(_, nx, ny)| (nx, ny))
}

/// The tiles of a frame: `cols x rows` tiles of `tile_w x tile_h` input pixels (context included).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TileLayout {
    pub cols: u32,
    pub rows: u32,
    pub tile_w: u32,
    pub tile_h: u32,
    /// Input pixels of context a tile reads around what it writes.
    pub context: u32,
}

/// The plan and per-size resources of one frame size.
struct Sized {
    w: u32,
    h: u32,
    plan: NnPlan,
    layout: TileLayout,
    /// Two parameter slots per tile: input, output.
    params: wgpu::Buffer,
    tiles: usize,
    in_groups: (u32, u32),
    /// Per tile: output rectangle size in pixels.
    out_groups: Vec<(u32, u32)>,
    owned: Option<Owned>,
}

struct Owned {
    input: wgpu::Texture,
    out: wgpu::Texture,
    readback: wgpu::Buffer,
    row_bytes: u32,
}

/// A `super_resolution` model run on frames, in tiles.
pub struct FrameUpscale {
    model: Arc<NnModel>,
    io: SrIo,
    ctx: u32,
    /// Smallest scale of a tensor relative to the input (see [`context`]).
    min_scale: f64,
    options: UpscaleOptions,
    in_layout: wgpu::BindGroupLayout,
    out_layout: wgpu::BindGroupLayout,
    in_pipeline: wgpu::ComputePipeline,
    out_pipeline: wgpu::ComputePipeline,
    sized: Option<Sized>,
}

fn words(v: &[u32]) -> Vec<u8> {
    v.iter().flat_map(|w| w.to_le_bytes()).collect()
}

impl FrameUpscale {
    /// Loads the `super_resolution` package (or bundle variant) of `scale` at `path` on `ctx`.
    pub fn open(
        ctx: Arc<crate::GpuContext>,
        path: impl AsRef<std::path::Path>,
        scale: u32,
        options: UpscaleOptions,
    ) -> Result<Self, Error> {
        Self::new(Arc::new(NnModel::load_with(ctx, path, Some(scale), options.precision)?), options)
    }

    /// Runs `model`, whose precision was chosen when it was loaded (`options.precision` is not used).
    pub fn new(model: Arc<NnModel>, options: UpscaleOptions) -> Result<Self, Error> {
        crate::used_for::check(model.name(), model.used_for(), crate::used_for::AI_UPSCALE)?;
        crate::used_for::check_kind(model.name(), &model.io, crate::used_for::AI_UPSCALE)?;
        let io = SrIo::parse(&model.io)?;

        if model.inputs() != [io.input.clone()] {
            return Err(Error::Package(format!("a super_resolution model has exactly one input, \"{}\"", io.input)));
        }
        if !model.outputs().contains(&io.output) {
            return Err(Error::Package(format!("io.json names output \"{}\" the model does not have", io.output)));
        }
        let (radius, s, min_scale) = context(&model, &io.input, &io.output)?;
        if (s - io.scale as f64).abs() > 1e-6 {
            return Err(Error::Package(format!("io.json scale is {}, the graph scales by {s}", io.scale)));
        }
        let ctx = radius.max(io.tile_pad);
        let device = &model.ctx.device;
        let in_entries = [
            uniform_entry(0),
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: false },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            storage_entry(2, false),
        ];
        let in_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("gpufx nn tile in"), entries: &in_entries });
        let out_entries = [
            uniform_entry(0),
            storage_entry(1, true),
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::StorageTexture {
                    access: wgpu::StorageTextureAccess::WriteOnly,
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    view_dimension: wgpu::TextureViewDimension::D2,
                },
                count: None,
            },
        ];
        let out_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("gpufx nn tile out"), entries: &out_entries });
        let cache = model.ctx.shader_cache.as_deref();
        let pl = |l: &wgpu::BindGroupLayout| {
            device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("gpufx nn tile"),
                bind_group_layouts: &[Some(l)],
                immediate_size: 0,
            })
        };
        let in_pipeline =
            compute_pipeline(device, cache, "gpufx nn tile in", &pl(&in_layout), &in_entries, include_str!("upscale_in.wgsl").into());
        let out_pipeline =
            compute_pipeline(device, cache, "gpufx nn tile out", &pl(&out_layout), &out_entries, include_str!("upscale_out.wgsl").into());
        Ok(FrameUpscale { model, io, ctx, min_scale, options, in_layout, out_layout, in_pipeline, out_pipeline, sized: None })
    }

    /// The output is `scale` times the input on each axis.
    pub fn scale(&self) -> u32 {
        self.io.scale
    }

    /// Input pixels of context a tile reads around what it writes.
    pub fn context(&self) -> u32 {
        self.ctx
    }

    /// Bytes of the largest tensor per input pixel of a tile.
    fn bytes_per_pixel(&self) -> Result<f64, Error> {
        let probe = 2 * self.ctx + 32;
        let shapes = infer_shapes(&self.model, &[(&self.io.input, [3, probe, probe])])?;
        let most = shapes.values().map(|s| s[0] as u64 * s[1] as u64 * s[2] as u64).max().unwrap_or(1);
        Ok(most as f64 * 4.0 / (probe as f64 * probe as f64))
    }

    /// The tile layout of a `w x h` frame from the options and the device limits, without making the plan.
    pub fn layout_for(&self, w: u32, h: u32) -> Result<TileLayout, Error> {
        let limits = self.model.ctx.device.limits();
        let cap = limits.max_storage_buffer_binding_size.min(limits.max_buffer_size);
        let max_bytes = self.options.max_tensor_bytes.unwrap_or(DEFAULT_TENSOR_BYTES).min(cap);
        let max_px = (max_bytes as f64 / self.bytes_per_pixel()?) as u64;
        let (cols, rows) =
            tile_counts(w, h, self.ctx, self.io.tile_pad, max_px, self.options.tile).ok_or_else(|| match self.options.tile {
                Some(t) => {
                    Error::Gpu(format!("tiles of {t} pixels (plus {} of context) do not fit {max_bytes} bytes per tensor", self.ctx))
                }
                None => Error::Gpu(format!("no tile of a {w}x{h} frame fits {max_bytes} bytes per tensor")),
            })?;
        if cols * rows > 1 && self.min_scale < 1.0 - 1e-9 {
            // a tile start must then fall on the coarser grid of the downscaled tensors
            return Err(Error::Unsupported(format!(
                "the graph downscales (a tensor at {} of the input size) before it upscales: a {w}x{h} frame needs \
                 {cols}x{rows} tiles, and such a graph cannot be run in tiles",
                self.min_scale
            )));
        }
        let (ax, ay) = (axis(w, cols, self.ctx, self.io.tile_pad), axis(h, rows, self.ctx, self.io.tile_pad));
        Ok(TileLayout { cols, rows, tile_w: ax.t, tile_h: ay.t, context: self.ctx })
    }

    /// Lays the model out for `w x h` frames (done by the calls that take frames when the size changes).
    pub fn prepare(&mut self, w: u32, h: u32) -> Result<TileLayout, Error> {
        if let Some(s) = self.sized.as_ref().filter(|s| s.w == w && s.h == h) {
            return Ok(s.layout);
        }
        if w == 0 || h == 0 {
            return Err(Error::Frame("empty frame".into()));
        }
        self.sized = None;
        let layout = self.layout_for(w, h)?;
        let (ax, ay) = (axis(w, layout.cols, self.ctx, self.io.tile_pad), axis(h, layout.rows, self.ctx, self.io.tile_pad));
        let (tw, th) = (ax.t, ay.t);
        let plan = self.model.plan(&[(&self.io.input, [3, th, tw])])?;
        let sc = self.io.scale;
        let out = plan.tensor(&self.io.output).expect("model output");
        if out.c < 3 || out.w != tw * sc || out.h != th * sc {
            return Err(Error::Package(format!("output is {}x{}x{}, expected 3x{}x{}", out.c, out.h, out.w, th * sc, tw * sc)));
        }
        let input = plan.tensor(&self.io.input).expect("model input");
        let tiles = (layout.cols * layout.rows) as usize;
        let device = &self.model.ctx.device;
        let params = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx nn tile params"),
            size: 2 * tiles as u64 * PARAM_SLOT,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let [lo, hi] = self.io.range;
        let [clo, chi] = self.io.clamp;
        let mut bytes = vec![0u8; 2 * tiles * PARAM_SLOT as usize];
        let mut out_groups = Vec::with_capacity(tiles);
        let mut k = 0;
        for &(sy, ylo, yhi) in &ay.tiles {
            for &(sx, xlo, xhi) in &ax.tiles {
                let tin = [w, h, sx as u32, sy as u32, tw, th, input.offset, lo.to_bits(), hi.to_bits(), self.io.replicate as u32];
                bytes[2 * k * PARAM_SLOT as usize..][..tin.len() * 4].copy_from_slice(&words(&tin));
                let (rw, rh) = ((xhi - xlo) * sc, (yhi - ylo) * sc);
                let (dx, dy) = (sx * sc as i32, sy * sc as i32);
                let tout = [out.w, out.h, out.offset, xlo * sc, ylo * sc, rw, rh, dx as u32, dy as u32, clo.to_bits(), chi.to_bits()];
                bytes[(2 * k + 1) * PARAM_SLOT as usize..][..tout.len() * 4].copy_from_slice(&words(&tout));
                out_groups.push((rw.div_ceil(16), rh.div_ceil(16)));
                k += 1;
            }
        }
        self.model.ctx.queue.write_buffer(&params, 0, &bytes);
        self.sized =
            Some(Sized { w, h, plan, layout, params, tiles, in_groups: (tw.div_ceil(16), th.div_ceil(16)), out_groups, owned: None });
        Ok(layout)
    }

    /// Records the upscale of `input` (a `w x h` view of a float-sampled RGBA texture, e.g. rgba8unorm) into
    /// `out`, a `scale * w x scale * h` rgba8unorm storage texture view.
    pub fn encode(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        input: &wgpu::TextureView,
        out: &wgpu::TextureView,
        w: u32,
        h: u32,
    ) -> Result<(), Error> {
        let (ow, oh) = (w as u64 * self.io.scale as u64, h as u64 * self.io.scale as u64);
        let t = out.texture();
        if (t.width() as u64, t.height() as u64) != (ow, oh) {
            return Err(Error::Frame(format!("the output is {}x{}, a {w}x{h} frame upscales to {ow}x{oh}", t.width(), t.height())));
        }
        if t.format() != wgpu::TextureFormat::Rgba8Unorm || !t.usage().contains(wgpu::TextureUsages::STORAGE_BINDING) {
            return Err(Error::Frame("the output must be an rgba8unorm texture with storage binding usage".into()));
        }
        self.prepare(w, h)?;
        let s = self.sized.as_ref().expect("prepared");
        let device = &self.model.ctx.device;
        let slot = |k: usize| {
            wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                buffer: &s.params,
                offset: k as u64 * PARAM_SLOT,
                size: wgpu::BufferSize::new(PARAM_SLOT),
            })
        };
        let t_in = s.plan.tensor(&self.io.input).expect("model input");
        let t_out = s.plan.tensor(&self.io.output).expect("model output");
        let groups: Vec<(wgpu::BindGroup, wgpu::BindGroup)> = (0..s.tiles)
            .map(|k| {
                let gin = device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("gpufx nn tile in"),
                    layout: &self.in_layout,
                    entries: &[
                        wgpu::BindGroupEntry { binding: 0, resource: slot(2 * k) },
                        wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(input) },
                        wgpu::BindGroupEntry { binding: 2, resource: s.plan.buffer(t_in.slot).as_entire_binding() },
                    ],
                });
                let gout = device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("gpufx nn tile out"),
                    layout: &self.out_layout,
                    entries: &[
                        wgpu::BindGroupEntry { binding: 0, resource: slot(2 * k + 1) },
                        wgpu::BindGroupEntry { binding: 1, resource: s.plan.buffer(t_out.slot).as_entire_binding() },
                        wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(out) },
                    ],
                });
                (gin, gout)
            })
            .collect();
        let mut cpass =
            encoder.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("gpufx nn upscale"), timestamp_writes: None });
        for (k, (gin, gout)) in groups.iter().enumerate() {
            cpass.set_pipeline(&self.in_pipeline);
            cpass.set_bind_group(0, gin, &[]);
            cpass.dispatch_workgroups(s.in_groups.0, s.in_groups.1, 1);
            s.plan.encode(&mut cpass);
            cpass.set_pipeline(&self.out_pipeline);
            cpass.set_bind_group(0, gout, &[]);
            cpass.dispatch_workgroups(s.out_groups[k].0, s.out_groups[k].1, 1);
        }
        Ok(())
    }

    fn owned(&mut self, w: u32, h: u32) -> Result<(), Error> {
        self.prepare(w, h)?;
        let device = self.model.ctx.device.clone();
        let sc = self.io.scale;
        let s = self.sized.as_mut().expect("prepared");
        if s.owned.is_some() {
            return Ok(());
        }
        let tex = |w, h, usage, label| {
            device.create_texture(&wgpu::TextureDescriptor {
                label: Some(label),
                size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba8Unorm,
                usage,
                view_formats: &[],
            })
        };
        let (ow, oh) = (w as u64 * sc as u64, h as u64 * sc as u64);
        let limits = device.limits();
        let max_side = limits.max_texture_dimension_2d as u64;
        if w as u64 > max_side || h as u64 > max_side || ow > max_side || oh > max_side {
            return Err(Error::Frame(format!("a {w}x{h} frame upscaled to {ow}x{oh} exceeds the {max_side} pixel texture limit")));
        }
        let (ow, oh) = (ow as u32, oh as u32);
        let row_bytes = (ow * 4).div_ceil(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT) * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        if row_bytes as u64 * oh as u64 > limits.max_buffer_size {
            return Err(Error::Frame(format!(
                "the {ow}x{oh} readback takes {} bytes, above the {} byte buffer limit",
                row_bytes as u64 * oh as u64,
                limits.max_buffer_size
            )));
        }
        s.owned = Some(Owned {
            input: tex(w, h, wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST, "gpufx nn upscale in"),
            out: tex(ow, oh, wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC, "gpufx nn upscale out"),
            readback: device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("gpufx nn readback"),
                size: row_bytes as u64 * oh as u64,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            }),
            row_bytes,
        });
        Ok(())
    }

    fn encode_owned(&mut self, encoder: &mut wgpu::CommandEncoder) -> Result<(), Error> {
        let s = self.sized.as_ref().expect("prepared");
        let (w, h) = (s.w, s.h);
        let o = s.owned.as_ref().expect("made");
        let (a, b) = (o.input.create_view(&Default::default()), o.out.create_view(&Default::default()));
        self.encode(encoder, &a, &b, w, h)
    }

    /// Upscales a CPU RGBA8 image (alpha ignored); returns the `scale * w x scale * h` RGBA8 result (alpha 255),
    /// tightly packed.
    pub fn upscale(&mut self, img: &Image) -> Result<Vec<u8>, Error> {
        let (w, h) = (img.width, img.height);
        if w == 0 || h == 0 || img.stride < w * 4 || img.data.len() < (img.stride as usize) * (h as usize - 1) + w as usize * 4 {
            return Err(Error::Frame("image buffer is too small".into()));
        }
        self.owned(w, h)?;
        let s = self.sized.as_ref().expect("prepared");
        let o = s.owned.as_ref().expect("made");
        self.model.ctx.queue.write_texture(
            wgpu::TexelCopyTextureInfo { texture: &o.input, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
            img.data,
            wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(img.stride), rows_per_image: Some(h) },
            wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        );
        let device = self.model.ctx.device.clone();
        let mut enc = device.create_command_encoder(&Default::default());
        self.encode_owned(&mut enc)?;
        let s = self.sized.as_ref().expect("prepared");
        let o = s.owned.as_ref().expect("made");
        let (ow, oh) = (w * self.io.scale, h * self.io.scale);
        enc.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo { texture: &o.out, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
            wgpu::TexelCopyBufferInfo {
                buffer: &o.readback,
                layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(o.row_bytes), rows_per_image: Some(oh) },
            },
            wgpu::Extent3d { width: ow, height: oh, depth_or_array_layers: 1 },
        );
        self.model.ctx.queue.submit([enc.finish()]);
        let row = o.row_bytes as usize;
        read_buffer(&device, &o.readback, |b| {
            let mut out = Vec::with_capacity((ow * oh * 4) as usize);
            for y in 0..oh as usize {
                out.extend_from_slice(&b[y * row..][..ow as usize * 4]);
            }
            out
        })
    }

    /// Milliseconds per frame for the image last given to [`FrameUpscale::upscale`]: `n` frames submitted one
    /// per command buffer, then waited for (GPU throughput, no upload or readback).
    pub fn bench(&mut self, n: u32) -> Result<f64, Error> {
        if self.sized.as_ref().is_none_or(|s| s.owned.is_none()) {
            return Err(Error::Frame("bench needs a prior upscale".into()));
        }
        let device = self.model.ctx.device.clone();
        let start = Instant::now();
        for _ in 0..n {
            let mut enc = device.create_command_encoder(&Default::default());
            self.encode_owned(&mut enc)?;
            self.model.ctx.queue.submit([enc.finish()]);
        }
        device.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| Error::Gpu(e.to_string()))?;
        Ok(start.elapsed().as_secs_f64() * 1e3 / n.max(1) as f64)
    }

    /// The plan of the current frame size (one tile), after a frame was given.
    pub fn plan(&self) -> Option<&NnPlan> {
        self.sized.as_ref().map(|s| &s.plan)
    }

    pub fn model(&self) -> &Arc<NnModel> {
        &self.model
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every frame pixel is written by exactly one tile, and a tile has `ctx` pixels of context on each side
    /// it writes, or starts / ends with the padded frame.
    #[test]
    fn tiles_cover_the_frame_with_context() {
        for w in [1u32, 5, 7, 37, 100, 1920] {
            for n in 1..=w.min(9) {
                for (ctx, pad) in [(0, 0), (3, 3), (20, 10), (10, 20), (35, 10)] {
                    let a = axis(w, n, ctx, pad);
                    let mut next = 0;
                    for &(start, lo, hi) in &a.tiles {
                        assert_eq!(lo, next, "w={w} n={n}");
                        assert!(hi > lo || w < n);
                        next = hi;
                        let end = start as i64 + a.t as i64;
                        assert!(start >= -(pad as i32) && end <= (w + pad) as i64, "inside the padded frame");
                        assert!(start == -(pad as i32) || start as i64 <= lo as i64 - ctx as i64, "left context w={w} n={n}");
                        assert!(end == (w + pad) as i64 || end >= (hi + ctx) as i64, "right context w={w} n={n}");
                    }
                    assert_eq!(next, w);
                }
            }
        }
    }

    #[test]
    fn tile_counts_fit_and_prefer_few_tiles() {
        // the whole frame fits: one tile
        assert_eq!(tile_counts(100, 50, 20, 10, u64::MAX, None), Some((1, 1)));
        // 1080p within ~1M pixels of tile
        let (nx, ny) = tile_counts(1920, 1080, 20, 10, 1 << 20, None).unwrap();
        let (tx, ty) = (axis(1920, nx, 20, 10).t as u64, axis(1080, ny, 20, 10).t as u64);
        assert!(tx * ty <= 1 << 20 && nx * ny <= 3, "{nx}x{ny}");
        assert_eq!(tile_counts(1920, 1080, 20, 10, 1 << 20, Some(512)), Some((4, 3)));
        assert_eq!(tile_counts(10, 10, 20, 10, 100, None), None);
        // a forced tile is held to the budget too
        assert_eq!(tile_counts(1920, 1080, 20, 10, 1 << 20, Some(2048)), None);
        // more than 64 tiles per axis when that is what fits
        assert_eq!(tile_counts(1000, 1, 0, 0, 10, None), Some((100, 1)));
        assert_eq!(tile_counts(1, 1000, 0, 0, 10, None), Some((1, 100)));
    }
}
