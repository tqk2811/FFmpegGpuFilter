//! Background removal (portrait matting) driven by the `io.json` of a `matting` package (MODNet, PP-HumanSeg):
//! an RGBA frame in, its alpha matte out, all on the GPU.
//!
//! Per frame: the frame is resized (bilinear, half-pixel centres, no antialias) to the model size chosen by
//! `io.json` `size` and normalized with its `mean` / `std` ([`super::FrameMatte::encode`], `matte_in.wgsl`); the
//! graph runs; its output becomes one alpha value per model pixel by `io.json` `matte` (`matte_out.wgsl`), kept in
//! a buffer of the model size. [`FrameMatte::draw`] then renders that matte into a one-channel texture of any
//! size (bilinear, `matte_draw.wgsl`): the model size for the raw matte, the frame size to cut the frame out.
//! The CPU reference of the same steps is `gpufx-nnconv frames::matte`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use super::kernels::{compute_pipeline, storage_entry, uniform_entry, PARAM_SLOT};
use super::plan::read_buffer;
use super::{NnModel, NnPlan, Precision};
use crate::runtime::Image;
use crate::Error;

/// How a frame is sized for the model (`io.json` `size`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatteSize {
    /// The frame scaled so its short side is `short_side`, each side then rounded to the nearest multiple of
    /// `multiple` (at least one); the aspect ratio is kept up to that rounding (MODNet).
    ShortSide { short_side: u32, multiple: u32 },
    /// Always `height x width`, the frame stretched (PP-HumanSeg, whose graph has fixed sizes).
    Fixed { height: u32, width: u32 },
}

impl MatteSize {
    /// The model input size `(w, h)` for a `w x h` frame, each side at most `max_side`; a frame whose long side
    /// would pass it (an extreme aspect ratio) is an error.
    pub fn model_size(&self, w: u32, h: u32, max_side: u32) -> Result<(u32, u32), Error> {
        let (mw, mh) = match *self {
            MatteSize::Fixed { height, width } => (width as u64, height as u64),
            MatteSize::ShortSide { short_side, multiple } => {
                let s = short_side as f64 / w.min(h).max(1) as f64;
                let side = |v: u32| ((((v as f64 * s) / multiple as f64).round() as u64).max(1)) * multiple as u64;
                (side(w), side(h))
            }
        };
        if mw > max_side as u64 || mh > max_side as u64 {
            return Err(Error::Frame(format!("a {w}x{h} frame needs a {mw}x{mh} model input, above the {max_side} pixel limit")));
        }
        Ok((mw as u32, mh as u32))
    }
}

/// How the model output becomes alpha (`io.json` `matte`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatteType {
    /// Channel `channel` is the alpha already (the graph ends in a sigmoid), clamped to [0, 1].
    Alpha { channel: u32 },
    /// The sigmoid of channel `channel`.
    Sigmoid { channel: u32 },
    /// The softmax over the channels, taken at channel `channel` (the foreground class).
    Softmax { channel: u32 },
}

/// What `io.json` says about a `matting` model.
#[derive(Debug, Clone)]
pub struct MatteIo {
    pub input: String,
    pub output: String,
    pub mean: [f32; 3],
    pub std: [f32; 3],
    pub size: MatteSize,
    pub matte: MatteType,
}

impl MatteIo {
    pub fn parse(io: &serde_json::Value) -> Result<Self, Error> {
        let bad = |what: &str| Error::Package(format!("io.json: {what}"));
        if io["kind"] != "matting" {
            return Err(bad("kind is not \"matting\""));
        }
        if io.get("color").and_then(|c| c.as_str()).is_some_and(|c| c != "rgb") {
            return Err(bad("only color \"rgb\" is supported"));
        }
        let triple = |k: &str, d: f32| -> Result<[f32; 3], Error> {
            match io.get(k) {
                None | Some(serde_json::Value::Null) => Ok([d; 3]),
                Some(v) => {
                    let a: Vec<f32> =
                        v.as_array().map(|a| a.iter().filter_map(|x| x.as_f64()).map(|x| x as f32).collect()).unwrap_or_default();
                    a.try_into().map_err(|_| bad(&format!("{k} must be 3 numbers")))
                }
            }
        };
        let (mean, std) = (triple("mean", 0.0)?, triple("std", 1.0)?);
        if std.iter().any(|s| !(s.is_finite() && *s > 0.0)) || mean.iter().any(|m| !m.is_finite()) {
            return Err(bad("std must be positive and mean finite"));
        }
        let u = |v: &serde_json::Value, k: &str| -> Result<u32, Error> {
            v[k].as_u64().filter(|x| (1..=8192).contains(x)).map(|x| x as u32).ok_or_else(|| bad(&format!("size.{k} must be in 1..=8192")))
        };
        let s = &io["size"];
        let size = match s["mode"].as_str() {
            Some("short_side") => {
                let multiple = if s.get("multiple").is_some() { u(s, "multiple")? } else { 1 };
                MatteSize::ShortSide { short_side: u(s, "short_side")?, multiple }
            }
            Some("fixed") => MatteSize::Fixed { height: u(s, "height")?, width: u(s, "width")? },
            _ => return Err(bad("size.mode must be \"short_side\" or \"fixed\"")),
        };
        let m = &io["matte"];
        let channel = match m.get("channel") {
            None | Some(serde_json::Value::Null) => 0,
            Some(c) => c.as_u64().and_then(|c| u32::try_from(c).ok()).ok_or_else(|| bad("matte.channel must be a non-negative integer"))?,
        };
        let matte = match m["type"].as_str() {
            Some("alpha") => MatteType::Alpha { channel },
            Some("sigmoid") => MatteType::Sigmoid { channel },
            Some("softmax") => MatteType::Softmax { channel },
            _ => return Err(bad("matte.type must be \"alpha\", \"sigmoid\" or \"softmax\"")),
        };
        Ok(MatteIo {
            input: io["inputs"]["image"].as_str().map(String::from).ok_or_else(|| bad("no inputs.image"))?,
            output: io["output"].as_str().map(String::from).ok_or_else(|| bad("no output"))?,
            mean,
            std,
            size,
            matte,
        })
    }
}

struct Sized {
    /// frame size
    w: u32,
    h: u32,
    /// model size
    mw: u32,
    mh: u32,
    plan: NnPlan,
    /// parameter slots: input, output
    params: wgpu::Buffer,
    /// `mw * mh` alpha values
    alpha: wgpu::Buffer,
    out_group: wgpu::BindGroup,
    owned: Option<Owned>,
}

struct Owned {
    input: wgpu::Texture,
    readback: wgpu::Buffer,
}

/// A `matting` model run on frames.
pub struct FrameMatte {
    model: Arc<NnModel>,
    io: MatteIo,
    in_layout: wgpu::BindGroupLayout,
    out_layout: wgpu::BindGroupLayout,
    draw_layout: wgpu::BindGroupLayout,
    in_pipeline: wgpu::ComputePipeline,
    out_pipeline: wgpu::ComputePipeline,
    draw_module: wgpu::ShaderModule,
    draw_pipeline_layout: wgpu::PipelineLayout,
    draw_pipelines: Mutex<HashMap<wgpu::TextureFormat, wgpu::RenderPipeline>>,
    sized: Option<Sized>,
}

fn words(v: &[u32]) -> Vec<u8> {
    v.iter().flat_map(|w| w.to_le_bytes()).collect()
}

/// The largest side of a model input [`FrameMatte`] accepts.
pub const MAX_MODEL_SIDE: u32 = 8192;

/// The texture formats [`FrameMatte::draw`] renders into.
pub const MATTE_FORMATS: [wgpu::TextureFormat; 3] =
    [wgpu::TextureFormat::R8Unorm, wgpu::TextureFormat::R16Float, wgpu::TextureFormat::R32Float];

impl FrameMatte {
    /// Loads the `matting` package at `path` on `ctx`.
    pub fn open(ctx: Arc<crate::GpuContext>, path: impl AsRef<std::path::Path>, precision: Precision) -> Result<Self, Error> {
        Self::new(Arc::new(NnModel::load_with(ctx, path, None, precision)?))
    }

    pub fn new(model: Arc<NnModel>) -> Result<Self, Error> {
        crate::used_for::check(model.name(), model.used_for(), crate::used_for::AI_MATTING)?;
        crate::used_for::check_kind(model.name(), &model.io, crate::used_for::AI_MATTING)?;
        let io = MatteIo::parse(&model.io)?;
        if model.inputs() != [io.input.clone()] {
            return Err(Error::Package(format!("a matting model has exactly one input, \"{}\"", io.input)));
        }
        if !model.outputs().contains(&io.output) {
            return Err(Error::Package(format!("io.json names output \"{}\" the model does not have", io.output)));
        }
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
        let out_entries = [uniform_entry(0), storage_entry(1, true), storage_entry(2, false)];
        let layout = |label, entries: &[wgpu::BindGroupLayoutEntry]| {
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some(label), entries })
        };
        let in_layout = layout("gpufx nn matte in", &in_entries);
        let out_layout = layout("gpufx nn matte out", &out_entries);
        let draw_entries = [
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None },
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Storage { read_only: true },
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
        ];
        let draw_layout = layout("gpufx nn matte draw", &draw_entries);
        let cache = model.ctx.shader_cache.as_deref();
        let pl = |l: &wgpu::BindGroupLayout| {
            device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("gpufx nn matte"),
                bind_group_layouts: &[Some(l)],
                immediate_size: 0,
            })
        };
        let in_pipeline =
            compute_pipeline(device, cache, "gpufx nn matte in", &pl(&in_layout), &in_entries, include_str!("matte_in.wgsl").into());
        let out_pipeline =
            compute_pipeline(device, cache, "gpufx nn matte out", &pl(&out_layout), &out_entries, include_str!("matte_out.wgsl").into());
        let draw_module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("gpufx nn matte draw"),
            source: wgpu::ShaderSource::Wgsl(include_str!("matte_draw.wgsl").into()),
        });
        let draw_pipeline_layout = pl(&draw_layout);
        Ok(FrameMatte {
            model,
            io,
            in_layout,
            out_layout,
            draw_layout,
            in_pipeline,
            out_pipeline,
            draw_module,
            draw_pipeline_layout,
            draw_pipelines: Mutex::new(HashMap::new()),
            sized: None,
        })
    }

    pub fn io(&self) -> &MatteIo {
        &self.io
    }

    pub fn model(&self) -> &Arc<NnModel> {
        &self.model
    }

    /// The model input size `(w, h)` for a `w x h` frame: at most [`MAX_MODEL_SIDE`] and the device's 2D texture
    /// limit per side, and its largest tensor within the storage buffer limits (checked when the plan is made).
    pub fn model_size(&self, w: u32, h: u32) -> Result<(u32, u32), Error> {
        let limit = self.model.ctx.device.limits().max_texture_dimension_2d.min(MAX_MODEL_SIDE);
        self.io.size.model_size(w, h, limit)
    }

    /// Lays the model out for `w x h` frames (done by [`FrameMatte::encode`] when the size changes); returns the
    /// model size.
    pub fn prepare(&mut self, w: u32, h: u32) -> Result<(u32, u32), Error> {
        if let Some(s) = self.sized.as_ref().filter(|s| s.w == w && s.h == h) {
            return Ok((s.mw, s.mh));
        }
        if w == 0 || h == 0 {
            return Err(Error::Frame("empty frame".into()));
        }
        let (mw, mh) = self.model_size(w, h)?;
        // the plan depends only on the model size: keep it when only the frame size changed
        let old = self.sized.take().filter(|s| s.mw == mw && s.mh == mh);
        let (plan, alpha) = match old {
            Some(s) => (s.plan, s.alpha),
            None => {
                let plan = self.model.plan(&[(&self.io.input, [3, mh, mw])])?;
                let out = plan.tensor(&self.io.output).expect("model output");
                if out.w != mw || out.h != mh {
                    return Err(Error::Package(format!("output is {}x{}, the matte must be the model size {mw}x{mh}", out.w, out.h)));
                }
                let ch = match self.io.matte {
                    MatteType::Alpha { channel } | MatteType::Sigmoid { channel } | MatteType::Softmax { channel } => channel,
                };
                if ch >= out.c {
                    return Err(Error::Package(format!("io.json matte channel {ch} of an output of {} channels", out.c)));
                }
                let alpha = self.model.ctx.device.create_buffer(&wgpu::BufferDescriptor {
                    label: Some("gpufx nn matte"),
                    size: (mw as u64 * mh as u64 * 4).max(16),
                    usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
                    mapped_at_creation: false,
                });
                (plan, alpha)
            }
        };
        let device = &self.model.ctx.device;
        let input = plan.tensor(&self.io.input).expect("model input");
        let out = plan.tensor(&self.io.output).expect("model output");
        let params = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx nn matte params"),
            size: 2 * PARAM_SLOT,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let (m, s) = (self.io.mean, self.io.std);
        let f = |v: f32| v.to_bits();
        let tin = [w, h, mw, mh, input.offset, 0, 0, 0, f(m[0]), f(m[1]), f(m[2]), 0, f(1.0 / s[0]), f(1.0 / s[1]), f(1.0 / s[2]), 0];
        let (mode, fg) = match self.io.matte {
            MatteType::Alpha { channel } => (0, channel),
            MatteType::Sigmoid { channel } => (1, channel),
            MatteType::Softmax { channel } => (2, channel),
        };
        let tout = [mw * mh, out.c, out.offset, mode, fg];
        let mut bytes = vec![0u8; 2 * PARAM_SLOT as usize];
        bytes[..tin.len() * 4].copy_from_slice(&words(&tin));
        bytes[PARAM_SLOT as usize..][..tout.len() * 4].copy_from_slice(&words(&tout));
        self.model.ctx.queue.write_buffer(&params, 0, &bytes);
        let out_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("gpufx nn matte out"),
            layout: &self.out_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &params,
                        offset: PARAM_SLOT,
                        size: wgpu::BufferSize::new(PARAM_SLOT),
                    }),
                },
                wgpu::BindGroupEntry { binding: 1, resource: plan.buffer(out.slot).as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: alpha.as_entire_binding() },
            ],
        });
        self.sized = Some(Sized { w, h, mw, mh, plan, params, alpha, out_group, owned: None });
        Ok((mw, mh))
    }

    /// Records the matte of `input` (a `w x h` view of a float-sampled RGBA texture, e.g. rgba8unorm): resize and
    /// normalize, the graph, the alpha of every model pixel. [`FrameMatte::draw`] then renders it.
    pub fn encode(&mut self, encoder: &mut wgpu::CommandEncoder, input: &wgpu::TextureView, w: u32, h: u32) -> Result<(), Error> {
        let t = input.texture();
        if (t.width(), t.height()) != (w, h) {
            return Err(Error::Frame(format!("the input is {}x{}, not {w}x{h}", t.width(), t.height())));
        }
        self.prepare(w, h)?;
        let device = self.model.ctx.device.clone();
        let io_input = self.io.input.clone();
        let s = self.sized.as_mut().expect("prepared");
        let in_tensor = s.plan.tensor(&io_input).expect("model input");
        let gin = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("gpufx nn matte in"),
            layout: &self.in_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &s.params,
                        offset: 0,
                        size: wgpu::BufferSize::new(PARAM_SLOT),
                    }),
                },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(input) },
                wgpu::BindGroupEntry { binding: 2, resource: s.plan.buffer(in_tensor.slot).as_entire_binding() },
            ],
        });
        let mut cpass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("gpufx nn matte"), timestamp_writes: None });
        cpass.set_pipeline(&self.in_pipeline);
        cpass.set_bind_group(0, &gin, &[]);
        cpass.dispatch_workgroups(s.mw.div_ceil(16), s.mh.div_ceil(16), 1);
        s.plan.encode(&mut cpass);
        cpass.set_pipeline(&self.out_pipeline);
        cpass.set_bind_group(0, &s.out_group, &[]);
        let n = (s.mw * s.mh).div_ceil(256);
        let gx = n.min(32768);
        cpass.dispatch_workgroups(gx, n.div_ceil(gx), 1);
        Ok(())
    }

    fn draw_pipeline(&self, format: wgpu::TextureFormat) -> Result<wgpu::RenderPipeline, Error> {
        if !MATTE_FORMATS.contains(&format) {
            return Err(Error::Frame(format!("the matte is drawn into r8unorm, r16float or r32float, not {format:?}")));
        }
        let mut map = self.draw_pipelines.lock().unwrap_or_else(|e| e.into_inner());
        let p = map.entry(format).or_insert_with(|| {
            self.model.ctx.device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("gpufx nn matte draw"),
                layout: Some(&self.draw_pipeline_layout),
                vertex: wgpu::VertexState {
                    module: &self.draw_module,
                    entry_point: Some("vs"),
                    compilation_options: Default::default(),
                    buffers: &[],
                },
                fragment: Some(wgpu::FragmentState {
                    module: &self.draw_module,
                    entry_point: Some("fs"),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState { format, blend: None, write_mask: wgpu::ColorWrites::ALL })],
                }),
                primitive: Default::default(),
                depth_stencil: None,
                multisample: Default::default(),
                multiview_mask: None,
                cache: None,
            })
        });
        Ok(p.clone())
    }

    /// Records the drawing of the last encoded matte into `out`, a one-channel texture view (r8unorm, r16float or
    /// r32float, render attachment) of any size: the model size gives the matte as computed, the frame size (or
    /// any other) a bilinear resize of it.
    pub fn draw(&self, encoder: &mut wgpu::CommandEncoder, out: &wgpu::TextureView) -> Result<(), Error> {
        let s = self.sized.as_ref().ok_or_else(|| Error::Frame("draw needs an encoded frame".into()))?;
        let t = out.texture();
        if !t.usage().contains(wgpu::TextureUsages::RENDER_ATTACHMENT) {
            return Err(Error::Frame("the matte output needs render attachment usage".into()));
        }
        let pipeline = self.draw_pipeline(t.format())?;
        let device = &self.model.ctx.device;
        let (dw, dh) = (t.width(), t.height());
        let params = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx nn matte draw"),
            size: 16,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        self.model.ctx.queue.write_buffer(&params, 0, &words(&[s.mw, s.mh, dw, dh]));
        let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("gpufx nn matte draw"),
            layout: &self.draw_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: params.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: s.alpha.as_entire_binding() },
            ],
        });
        let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("gpufx nn matte draw"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: out,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
        rpass.set_pipeline(&pipeline);
        rpass.set_bind_group(0, &group, &[]);
        rpass.draw(0..3, 0..1);
        Ok(())
    }

    fn owned(&mut self, w: u32, h: u32) -> Result<(), Error> {
        self.prepare(w, h)?;
        let device = self.model.ctx.device.clone();
        let s = self.sized.as_mut().expect("prepared");
        if s.owned.is_some() {
            return Ok(());
        }
        let input = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("gpufx nn matte in"),
            size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let readback = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx nn matte readback"),
            size: s.alpha.size(),
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        s.owned = Some(Owned { input, readback });
        Ok(())
    }

    fn encode_owned(&mut self, encoder: &mut wgpu::CommandEncoder) -> Result<(), Error> {
        let s = self.sized.as_ref().expect("prepared");
        let (w, h) = (s.w, s.h);
        let view = s.owned.as_ref().expect("made").input.create_view(&Default::default());
        self.encode(encoder, &view, w, h)
    }

    /// The matte of a CPU RGBA8 image (alpha ignored) at the model size: `(mw, mh, mw * mh alpha values)`.
    pub fn matte(&mut self, img: &Image) -> Result<(u32, u32, Vec<f32>), Error> {
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
        enc.copy_buffer_to_buffer(&s.alpha, 0, &o.readback, 0, s.alpha.size());
        self.model.ctx.queue.submit([enc.finish()]);
        let n = (s.mw * s.mh) as usize;
        let data = read_buffer(&device, &o.readback, |b| b.as_chunks::<4>().0[..n].iter().map(|c| f32::from_le_bytes(*c)).collect())?;
        Ok((s.mw, s.mh, data))
    }

    /// Milliseconds per frame for the image last given to [`FrameMatte::matte`]: `n` frames submitted one per
    /// command buffer, then waited for (GPU throughput: resize, graph and alpha; no upload, draw or readback).
    pub fn bench(&mut self, n: u32) -> Result<f64, Error> {
        if self.sized.as_ref().is_none_or(|s| s.owned.is_none()) {
            return Err(Error::Frame("bench needs a prior matte".into()));
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

    /// The plan of the current model size, after a frame was given.
    pub fn plan(&self) -> Option<&NnPlan> {
        self.sized.as_ref().map(|s| &s.plan)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_sizes() {
        let s = MatteSize::ShortSide { short_side: 512, multiple: 32 };
        assert_eq!(s.model_size(1920, 1080, 8192).unwrap(), (896, 512));
        assert_eq!(s.model_size(1080, 1920, 8192).unwrap(), (512, 896));
        assert_eq!(s.model_size(640, 480, 8192).unwrap(), (672, 512));
        assert_eq!(s.model_size(512, 512, 8192).unwrap(), (512, 512));
        assert_eq!(MatteSize::Fixed { height: 144, width: 256 }.model_size(1920, 1080, 8192).unwrap(), (256, 144));
        // an extreme aspect ratio: 8192x16 would need a 262144 pixel side
        assert!(s.model_size(8192, 16, 8192).is_err());
        assert!(s.model_size(u32::MAX, 1, 8192).is_err());
    }

    #[test]
    fn parses_io_json() {
        let io = serde_json::json!({"kind": "matting", "inputs": {"image": "in0"}, "output": "out0", "color": "rgb",
            "mean": [0.5, 0.5, 0.5], "std": [0.5, 0.5, 0.5],
            "size": {"mode": "short_side", "short_side": 512, "multiple": 32}, "matte": {"type": "alpha"}});
        let m = MatteIo::parse(&io).unwrap();
        assert_eq!((m.size, m.matte), (MatteSize::ShortSide { short_side: 512, multiple: 32 }, MatteType::Alpha { channel: 0 }));
        let mut io2 = io.clone();
        io2["size"] = serde_json::json!({"mode": "fixed", "height": 144, "width": 256});
        io2["matte"] = serde_json::json!({"type": "softmax", "channel": 1});
        let m = MatteIo::parse(&io2).unwrap();
        assert_eq!((m.size, m.matte), (MatteSize::Fixed { height: 144, width: 256 }, MatteType::Softmax { channel: 1 }));
        let mut bad = io.clone();
        bad["std"] = serde_json::json!([0.5, 0, 0.5]);
        assert!(MatteIo::parse(&bad).is_err());
        let mut bad = io.clone();
        bad["kind"] = serde_json::json!("super_resolution");
        assert!(MatteIo::parse(&bad).is_err());
        let mut bad = io.clone();
        bad["matte"] = serde_json::json!({"type": "argmax"});
        assert!(MatteIo::parse(&bad).is_err());
        for ch in [serde_json::json!(-1), serde_json::json!(1.5), serde_json::json!("1")] {
            let mut bad = io.clone();
            bad["matte"] = serde_json::json!({"type": "softmax", "channel": ch});
            assert!(MatteIo::parse(&bad).is_err(), "{ch}");
        }
    }
}
