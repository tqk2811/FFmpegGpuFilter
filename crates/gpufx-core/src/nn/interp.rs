//! Frame interpolation driven by the `io.json` of a `frame_interp` package (RIFE v4): two RGBA frames and a
//! time in (0, 1) in, the frame in between out, all on the GPU.
//!
//! Per frame: each input texture becomes 3 channel planes of its model input (mapped to `range`, zero padded
//! right and bottom to `pad_multiple`), the timestep input is filled with `t`, the graph runs, and the output
//! tensor is cropped, clamped to `output_clamp` and written to an rgba8unorm storage texture. The frames are
//! texture views, so a caller holding GPU frames (FFmpeg hardware frames converted to RGBA) feeds them
//! directly; [`FrameInterp::interpolate`] uploads CPU images for tools and tests.

use std::sync::Arc;
use std::time::Instant;

use wgpu::util::DeviceExt;

use super::kernels::{compute_pipeline, storage_entry, uniform_entry, PARAM_SLOT};
use super::plan::read_buffer;
use super::{NnModel, NnPlan};
use crate::runtime::Image;
use crate::Error;

/// What `io.json` says about a `frame_interp` model.
#[derive(Debug, Clone)]
struct InterpIo {
    frame0: String,
    frame1: String,
    timestep: String,
    output: String,
    pad_multiple: u32,
    range: [f32; 2],
    clamp: [f32; 2],
}

impl InterpIo {
    fn parse(io: &serde_json::Value) -> Result<Self, Error> {
        let bad = |what: &str| Error::Package(format!("io.json: {what}"));
        if io["kind"] != "frame_interp" {
            return Err(bad("kind is not \"frame_interp\""));
        }
        let name = |k: &str| io["inputs"][k].as_str().map(String::from).ok_or_else(|| bad(&format!("no inputs.{k}")));
        if io.get("color").and_then(|c| c.as_str()).is_some_and(|c| c != "rgb") {
            return Err(bad("only color \"rgb\" is supported"));
        }
        if io.get("pad_mode").and_then(|c| c.as_str()).is_some_and(|c| c != "zero") {
            return Err(bad("only pad_mode \"zero\" is supported"));
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
        Ok(InterpIo {
            frame0: name("frame0")?,
            frame1: name("frame1")?,
            timestep: name("timestep")?,
            output: io["output"].as_str().map(String::from).ok_or_else(|| bad("no output"))?,
            pad_multiple: io["pad_multiple"].as_u64().unwrap_or(1).clamp(1, 4096) as u32,
            range,
            clamp: pair("output_clamp", range)?,
        })
    }
}

/// The plan and per-size resources of one frame size.
struct Sized {
    w: u32,
    h: u32,
    plan: NnPlan,
    /// Slots: frame0 in, frame1 in, timestep fill, out.
    params: wgpu::Buffer,
    fill: wgpu::BindGroup,
    fill_groups: (u32, u32),
    /// Textures for [`FrameInterp::interpolate`] (made on first use).
    owned: Option<Owned>,
}

struct Owned {
    frames: [wgpu::Texture; 2],
    out: wgpu::Texture,
    readback: wgpu::Buffer,
    row_bytes: u32,
}

pub struct FrameInterp {
    model: Arc<NnModel>,
    io: InterpIo,
    in_layout: wgpu::BindGroupLayout,
    out_layout: wgpu::BindGroupLayout,
    in_pipeline: wgpu::ComputePipeline,
    out_pipeline: wgpu::ComputePipeline,
    sized: Option<Sized>,
}

fn words(v: &[u32]) -> Vec<u8> {
    v.iter().flat_map(|w| w.to_le_bytes()).collect()
}

impl FrameInterp {
    pub fn new(model: Arc<NnModel>) -> Result<Self, Error> {
        let io = InterpIo::parse(&model.io)?;
        for n in [&io.frame0, &io.frame1, &io.timestep] {
            if !model.inputs().contains(n) {
                return Err(Error::Package(format!("io.json names input \"{n}\" the model does not have")));
            }
        }
        if model.inputs().len() != 3 {
            return Err(Error::Package("a frame_interp model has exactly three inputs".into()));
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
        let in_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("gpufx nn frame in"), entries: &in_entries });
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
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("gpufx nn frame out"), entries: &out_entries });
        let cache = model.ctx.shader_cache.as_deref();
        let pl = |l: &wgpu::BindGroupLayout| {
            device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("gpufx nn frame"),
                bind_group_layouts: &[Some(l)],
                immediate_size: 0,
            })
        };
        let in_pipeline =
            compute_pipeline(device, cache, "gpufx nn frame in", &pl(&in_layout), &in_entries, include_str!("frame_in.wgsl").into());
        let out_pipeline =
            compute_pipeline(device, cache, "gpufx nn frame out", &pl(&out_layout), &out_entries, include_str!("frame_out.wgsl").into());
        Ok(FrameInterp { model, io, in_layout, out_layout, in_pipeline, out_pipeline, sized: None })
    }

    /// Lays the model out for `w x h` frames (done by the calls that take frames when the size changes).
    pub fn prepare(&mut self, w: u32, h: u32) -> Result<&NnPlan, Error> {
        if self.sized.as_ref().is_some_and(|s| s.w == w && s.h == h) {
            return Ok(&self.sized.as_ref().expect("checked").plan);
        }
        if w == 0 || h == 0 {
            return Err(Error::Frame("empty frame".into()));
        }
        self.sized = None;
        let m = self.io.pad_multiple;
        let (wp, hp) = (w.div_ceil(m) * m, h.div_ceil(m) * m);
        let plan = self.model.plan(&[(&self.io.frame0, [3, hp, wp]), (&self.io.frame1, [3, hp, wp]), (&self.io.timestep, [1, hp, wp])])?;
        let out = plan.tensor(&self.io.output).expect("model output");
        if out.c < 3 || out.h != hp || out.w != wp {
            return Err(Error::Package(format!("output is {}x{}x{}, expected 3x{hp}x{wp}", out.c, out.h, out.w)));
        }
        let device = &self.model.ctx.device;
        let params = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx nn frame params"),
            size: 4 * PARAM_SLOT,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let [lo, hi] = self.io.range;
        let queue = &self.model.ctx.queue;
        for (k, name) in [&self.io.frame0, &self.io.frame1].into_iter().enumerate() {
            let t = plan.tensor(name).expect("model input");
            queue.write_buffer(&params, k as u64 * PARAM_SLOT, &words(&[w, h, wp, hp, t.offset, lo.to_bits(), hi.to_bits()]));
        }
        let [clo, chi] = self.io.clamp;
        let out_words = [w, h, wp, hp, out.offset, clo.to_bits(), chi.to_bits()];
        queue.write_buffer(&params, 3 * PARAM_SLOT, &words(&out_words));
        // timestep: ew mode 14 (fill); the value is written per frame
        let ts = plan.tensor(&self.io.timestep).expect("model input");
        let mut fill = vec![0u32; 18];
        fill[0] = 14;
        fill[1] = ts.len();
        fill[2] = ts.offset;
        queue.write_buffer(&params, 2 * PARAM_SLOT, &words(&fill));
        let slot = |k: u64| {
            wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                buffer: &params,
                offset: k * PARAM_SLOT,
                size: wgpu::BufferSize::new(PARAM_SLOT),
            })
        };
        let tsb = plan.buffer(ts.slot);
        let fill_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("gpufx nn timestep"),
            layout: &self.model.kernels.layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: slot(2) },
                // src0/src1 are not read by a fill; any other buffer than the output works
                wgpu::BindGroupEntry { binding: 1, resource: self.model.weights.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: self.model.weights.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 3, resource: self.model.weights.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 4, resource: self.model.weights.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 5, resource: tsb.as_entire_binding() },
            ],
        });
        let g = ts.len().div_ceil(256);
        let gx = g.min(32768);
        self.sized = Some(Sized { w, h, plan, params, fill: fill_group, fill_groups: (gx, g.div_ceil(gx)), owned: None });
        Ok(&self.sized.as_ref().expect("just set").plan)
    }

    /// Records one interpolation at time `t` between `frame0` and `frame1` (`w x h` views of float-sampled RGBA
    /// textures, e.g. rgba8unorm) into `out`, a `w x h` rgba8unorm storage texture view. `t` is copied into the
    /// parameters inside `encoder`, so several encodes into one encoder each keep their own `t`.
    #[allow(clippy::too_many_arguments)]
    pub fn encode(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        frame0: &wgpu::TextureView,
        frame1: &wgpu::TextureView,
        out: &wgpu::TextureView,
        w: u32,
        h: u32,
        t: f32,
    ) -> Result<(), Error> {
        self.prepare(w, h)?;
        let s = self.sized.as_ref().expect("prepared");
        let device = &self.model.ctx.device;
        // `queue.write_buffer` lands at the next submit, so every encode before it would see the last `t`: copy
        // it in the encoder instead, ordered before this call's passes
        let t_src = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("gpufx nn timestep value"),
            contents: &t.to_le_bytes(),
            usage: wgpu::BufferUsages::COPY_SRC,
        });
        encoder.copy_buffer_to_buffer(&t_src, 0, &s.params, 2 * PARAM_SLOT + 15 * 4, 4);
        let slot = |k: u64| {
            wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                buffer: &s.params,
                offset: k * PARAM_SLOT,
                size: wgpu::BufferSize::new(PARAM_SLOT),
            })
        };
        let in_groups: Vec<wgpu::BindGroup> = [(frame0, &self.io.frame0), (frame1, &self.io.frame1)]
            .into_iter()
            .enumerate()
            .map(|(k, (view, name))| {
                let t = s.plan.tensor(name).expect("model input");
                device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("gpufx nn frame in"),
                    layout: &self.in_layout,
                    entries: &[
                        wgpu::BindGroupEntry { binding: 0, resource: slot(k as u64) },
                        wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(view) },
                        wgpu::BindGroupEntry { binding: 2, resource: s.plan.buffer(t.slot).as_entire_binding() },
                    ],
                })
            })
            .collect();
        let o = s.plan.tensor(&self.io.output).expect("model output");
        let out_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("gpufx nn frame out"),
            layout: &self.out_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: slot(3) },
                wgpu::BindGroupEntry { binding: 1, resource: s.plan.buffer(o.slot).as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(out) },
            ],
        });
        let m = self.io.pad_multiple;
        let (wp, hp) = (w.div_ceil(m) * m, h.div_ceil(m) * m);
        let mut cpass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("gpufx nn interp"), timestamp_writes: None });
        cpass.set_pipeline(&self.in_pipeline);
        for g in &in_groups {
            cpass.set_bind_group(0, g, &[]);
            cpass.dispatch_workgroups(wp.div_ceil(16), hp.div_ceil(16), 1);
        }
        cpass.set_pipeline(&self.model.kernels.get(&self.model.ctx.device, super::kernels::Kernel::Fixed(super::kernels::Fixed::Ew)));
        cpass.set_bind_group(0, &s.fill, &[]);
        cpass.dispatch_workgroups(s.fill_groups.0, s.fill_groups.1, 1);
        s.plan.encode(&mut cpass);
        cpass.set_pipeline(&self.out_pipeline);
        cpass.set_bind_group(0, &out_group, &[]);
        cpass.dispatch_workgroups(w.div_ceil(16), h.div_ceil(16), 1);
        Ok(())
    }

    fn owned(&mut self, w: u32, h: u32) -> Result<(), Error> {
        self.prepare(w, h)?;
        let device = self.model.ctx.device.clone();
        let s = self.sized.as_mut().expect("prepared");
        if s.owned.is_some() {
            return Ok(());
        }
        let tex = |usage, label| {
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
        let input = wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST;
        let row_bytes = (w * 4).div_ceil(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT) * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        s.owned = Some(Owned {
            frames: [tex(input, "gpufx nn frame0"), tex(input, "gpufx nn frame1")],
            out: tex(wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC, "gpufx nn out"),
            readback: device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("gpufx nn readback"),
                size: row_bytes as u64 * h as u64,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            }),
            row_bytes,
        });
        Ok(())
    }

    fn upload(&mut self, f0: &Image, f1: &Image) -> Result<(), Error> {
        if f0.width != f1.width || f0.height != f1.height {
            return Err(Error::Frame("frames differ in size".into()));
        }
        let (w, h) = (f0.width, f0.height);
        self.owned(w, h)?;
        let o = self.sized.as_ref().and_then(|s| s.owned.as_ref()).expect("made");
        for (img, tex) in [f0, f1].into_iter().zip(&o.frames) {
            if img.stride < w * 4 || img.data.len() < (img.stride as usize) * (h as usize - 1) + w as usize * 4 {
                return Err(Error::Frame("image buffer is too small".into()));
            }
            self.model.ctx.queue.write_texture(
                wgpu::TexelCopyTextureInfo { texture: tex, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
                img.data,
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(img.stride), rows_per_image: Some(h) },
                wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
            );
        }
        Ok(())
    }

    fn encode_owned(&mut self, encoder: &mut wgpu::CommandEncoder, t: f32) -> Result<(), Error> {
        let s = self.sized.as_ref().expect("prepared");
        let (w, h) = (s.w, s.h);
        let o = s.owned.as_ref().expect("made");
        let v = |t: &wgpu::Texture| t.create_view(&Default::default());
        let (a, b, out) = (v(&o.frames[0]), v(&o.frames[1]), v(&o.out));
        self.encode(encoder, &a, &b, &out, w, h, t)
    }

    /// Interpolates CPU RGBA8 images (alpha ignored); returns the `w x h` RGBA8 result (alpha 255), tightly
    /// packed.
    pub fn interpolate(&mut self, f0: &Image, f1: &Image, t: f32) -> Result<Vec<u8>, Error> {
        self.upload(f0, f1)?;
        let device = self.model.ctx.device.clone();
        let mut enc = device.create_command_encoder(&Default::default());
        self.encode_owned(&mut enc, t)?;
        let s = self.sized.as_ref().expect("prepared");
        let o = s.owned.as_ref().expect("made");
        let (w, h) = (s.w, s.h);
        enc.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo { texture: &o.out, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
            wgpu::TexelCopyBufferInfo {
                buffer: &o.readback,
                layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(o.row_bytes), rows_per_image: Some(h) },
            },
            wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        );
        self.model.ctx.queue.submit([enc.finish()]);
        let row = o.row_bytes as usize;
        read_buffer(&device, &o.readback, |b| {
            let mut out = Vec::with_capacity((w * h * 4) as usize);
            for y in 0..h as usize {
                out.extend_from_slice(&b[y * row..][..w as usize * 4]);
            }
            out
        })
    }

    /// Milliseconds per interpolation of the frames last given to [`FrameInterp::interpolate`]: `n` frames
    /// submitted one per command buffer, then waited for (GPU throughput, no upload or readback).
    pub fn bench(&mut self, n: u32, t: f32) -> Result<f64, Error> {
        if self.sized.as_ref().is_none_or(|s| s.owned.is_none()) {
            return Err(Error::Frame("bench needs a prior interpolate".into()));
        }
        let device = self.model.ctx.device.clone();
        let start = Instant::now();
        for _ in 0..n {
            let mut enc = device.create_command_encoder(&Default::default());
            self.encode_owned(&mut enc, t)?;
            self.model.ctx.queue.submit([enc.finish()]);
        }
        device.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| Error::Gpu(e.to_string()))?;
        Ok(start.elapsed().as_secs_f64() * 1e3 / n.max(1) as f64)
    }

    /// The plan of the current frame size, after a frame was given.
    pub fn plan(&self) -> Option<&NnPlan> {
        self.sized.as_ref().map(|s| &s.plan)
    }

    pub fn model(&self) -> &Arc<NnModel> {
        &self.model
    }
}
