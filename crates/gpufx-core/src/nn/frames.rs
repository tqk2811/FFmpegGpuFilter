//! Frame interpolation on the frames of the GPU frame APIs (FFmpeg's Vulkan, D3D12, D3D11 and VideoToolbox
//! frames), through the same imports as an effect graph (`stage.rs`).
//!
//! Each call takes the next source frame and the frames to make between the previous source frame and it, at
//! the times given by [`InterpFrames::set_times`]. The source frame is converted to RGBA once and kept on the
//! GPU, so the next call interpolates from it: the caller holds no frame. With a scene threshold, a pair of
//! frames that differ too much (a cut) is not interpolated: each frame in between is the nearer source frame.

use std::sync::Arc;

use super::kernels::{compute_pipeline, storage_entry, uniform_entry, PARAM_SLOT};
use super::{FrameInterp, NnModel};
use crate::convert::{GpuOutputSlot, InputKey, InputSlot};
use crate::frame::GpuFrame;
use crate::runtime::{FrameInfo, GpuContext};
use crate::stage::{GpuStage, Interop};
use crate::Error;

/// Samples of the scene check: about this many per frame.
const SCENE_SAMPLES: u64 = 1 << 20;

const RGBA_USAGE: wgpu::TextureUsages = wgpu::TextureUsages::STORAGE_BINDING.union(wgpu::TextureUsages::TEXTURE_BINDING);

/// One source frame: its conversion pass and the RGBA texture it writes.
struct Source {
    slot: InputSlot,
    view: wgpu::TextureView,
}

/// One frame in between: the texture the model writes and the conversion into the output frame.
struct Between {
    texture: wgpu::Texture,
    view: wgpu::TextureView,
    slot: GpuOutputSlot,
}

struct Scene {
    layout: wgpu::BindGroupLayout,
    sad: wgpu::ComputePipeline,
    decide: wgpu::ComputePipeline,
    select: wgpu::ComputePipeline,
    state: wgpu::Buffer,
    /// One parameter slot per frame in between.
    params: Option<wgpu::Buffer>,
    /// Bound as the destination when there is no frame in between to write (the scoring runs without them).
    dummy: wgpu::TextureView,
    /// The next scene check is the first pair after a discontinuity: its previous difference starts from zero.
    fresh: bool,
}

/// Frame interpolation as a stage of the GPU frame APIs: input 0 is the next source frame, the outputs are the
/// frames in between.
pub struct InterpFrames {
    interp: FrameInterp,
    ctx: Arc<GpuContext>,
    interop: Interop,
    /// The two source frames, in turn: `sources[cur]` is the previous one once `have_prev`.
    sources: Vec<Source>,
    key: Option<InputKey>,
    cur: usize,
    have_prev: bool,
    between: Vec<Between>,
    times: Vec<f32>,
    threshold: f32,
    scene: Scene,
}

fn texture(device: &wgpu::Device, w: u32, h: u32, label: &str) -> wgpu::Texture {
    texture_with(device, w, h, label, RGBA_USAGE)
}

fn texture_with(device: &wgpu::Device, w: u32, h: u32, label: &str, usage: wgpu::TextureUsages) -> wgpu::Texture {
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
}

impl Scene {
    fn new(ctx: &GpuContext) -> Self {
        let device = &ctx.device;
        let tex = |binding| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::COMPUTE,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: false },
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        };
        let entries = [
            uniform_entry(0),
            tex(1),
            tex(2),
            storage_entry(3, false),
            wgpu::BindGroupLayoutEntry {
                binding: 4,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::StorageTexture {
                    access: wgpu::StorageTextureAccess::WriteOnly,
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    view_dimension: wgpu::TextureViewDimension::D2,
                },
                count: None,
            },
        ];
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("gpufx nn scene"), entries: &entries });
        let pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("gpufx nn scene"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let cache = ctx.shader_cache.as_deref();
        let common = include_str!("scene.wgsl");
        let pipeline = |label: &str, main: &str| compute_pipeline(device, cache, label, &pl, &entries, format!("{common}{main}"));
        Scene {
            sad: pipeline("gpufx nn scene sad", include_str!("scene_sad.wgsl")),
            decide: pipeline("gpufx nn scene decide", include_str!("scene_decide.wgsl")),
            select: pipeline("gpufx nn scene select", include_str!("scene_select.wgsl")),
            layout,
            state: device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("gpufx nn scene state"),
                size: 16,
                usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }),
            params: None,
            dummy: texture_with(device, 1, 1, "gpufx nn scene dummy", wgpu::TextureUsages::STORAGE_BINDING)
                .create_view(&Default::default()),
            fresh: true,
        }
    }
}

impl InterpFrames {
    /// Loads the `frame_interp` package at `path` on `ctx`.
    pub fn open(ctx: Arc<GpuContext>, path: impl AsRef<std::path::Path>) -> Result<Self, Error> {
        let model = Arc::new(NnModel::load(ctx.clone(), path)?);
        Self::new(ctx, model)
    }

    /// Runs the already loaded `frame_interp` model on `ctx`.
    pub fn new(ctx: Arc<GpuContext>, model: Arc<NnModel>) -> Result<Self, Error> {
        let interp = FrameInterp::new(model)?;
        let scene = Scene::new(&ctx);
        Ok(InterpFrames {
            interp,
            ctx,
            interop: Interop::default(),
            sources: Vec::new(),
            key: None,
            cur: 0,
            have_prev: false,
            between: Vec::new(),
            times: Vec::new(),
            threshold: 0.0,
            scene,
        })
    }

    pub fn context(&self) -> &Arc<GpuContext> {
        &self.ctx
    }

    /// Encodes one call on frames already on the GPU (wgpu textures): `input` is the next source frame, `outs`
    /// the frames in between (one per time). For callers that hold no FFmpeg frames, and tests.
    pub fn encode_frames(&mut self, input: &GpuFrame, outs: &[GpuFrame], enc: &mut wgpu::CommandEncoder) -> Result<(), Error> {
        self.encode(input, outs, enc)
    }

    /// Times in (0, 1] of the frames the next call makes, one per output frame. 1 is the new source frame
    /// itself converted into the output frame, for callers that need every frame in frames of their own.
    pub fn set_times(&mut self, times: &[f32]) -> Result<(), Error> {
        if let Some(t) = times.iter().find(|t| !(t.is_finite() && **t > 0.0 && **t <= 1.0)) {
            return Err(Error::Param(format!("interpolation time {t} is not in (0, 1]")));
        }
        self.times = times.to_vec();
        Ok(())
    }

    /// Scene change threshold in percent (0 to 100) of the frame difference; 0 interpolates every pair.
    pub fn set_scene_threshold(&mut self, threshold: f32) -> Result<(), Error> {
        if !(0.0..=100.0).contains(&threshold) {
            return Err(Error::Param(format!("scene threshold {threshold} is not in [0, 100]")));
        }
        self.threshold = threshold;
        Ok(())
    }

    /// Forgets the previous source frame: the next call takes a frame and makes none.
    pub fn reset(&mut self) {
        self.have_prev = false;
        self.scene.fresh = true;
    }

    /// Whether a previous source frame is held (the next call may make frames).
    pub fn has_previous(&self) -> bool {
        self.have_prev
    }

    /// Runs on Vulkan frames (see [`crate::EffectGraph::process_vulkan`]): `input` is the next source frame,
    /// `outs` the frames in between.
    ///
    /// # Safety
    /// As for [`crate::EffectGraph::process_vulkan`].
    #[cfg(any(windows, all(unix, not(target_vendor = "apple"))))]
    pub unsafe fn process_vulkan(
        &mut self,
        input: &mut crate::vulkan::VulkanFrame,
        outs: &mut [crate::vulkan::VulkanFrame],
    ) -> Result<(), Error> {
        crate::vulkan::process_vulkan(self, std::slice::from_mut(input), outs, None)
    }

    /// Runs on D3D12 frames (see [`crate::EffectGraph::process_d3d12`]).
    ///
    /// # Safety
    /// As for [`crate::EffectGraph::process_d3d12`].
    #[cfg(windows)]
    pub unsafe fn process_d3d12(
        &mut self,
        input: &mut crate::d3d12::D3d12Frame,
        outs: &mut [crate::d3d12::D3d12Frame],
    ) -> Result<(), Error> {
        crate::d3d12::process_d3d12(self, std::slice::from_mut(input), outs, None)
    }

    /// Runs on D3D11 frames (see [`crate::EffectGraph::process_d3d11`]).
    ///
    /// # Safety
    /// As for [`crate::EffectGraph::process_d3d11`].
    #[cfg(windows)]
    pub unsafe fn process_d3d11(&mut self, input: &crate::d3d12::D3d11Frame, outs: &[crate::d3d12::D3d11Frame]) -> Result<(), Error> {
        crate::d3d12::process_d3d11(self, std::slice::from_ref(input), outs, None)
    }

    /// Runs on VideoToolbox frames (see [`crate::EffectGraph::process_videotoolbox`]).
    ///
    /// # Safety
    /// As for [`crate::EffectGraph::process_videotoolbox`].
    #[cfg(target_vendor = "apple")]
    pub unsafe fn process_videotoolbox(
        &mut self,
        input: &crate::videotoolbox::VtFrame,
        outs: &[crate::videotoolbox::VtFrame],
    ) -> Result<(), Error> {
        crate::videotoolbox::process_videotoolbox(self, std::slice::from_ref(input), outs, None)
    }

    fn encode(&mut self, input: &GpuFrame, outs: &[GpuFrame], enc: &mut wgpu::CommandEncoder) -> Result<(), Error> {
        let ctx = self.ctx.clone();
        let (device, queue, conv) = (&ctx.device, &ctx.queue, &ctx.conv);
        input.check("input", false)?;
        let (w, h) = (input.width, input.height);
        if outs.len() != self.times.len() {
            return Err(Error::Frame(format!("{} output frames for {} interpolation times", outs.len(), self.times.len())));
        }
        for (k, out) in outs.iter().enumerate() {
            out.check(&format!("output {k}"), true)?;
            if (out.width, out.height) != (w, h) {
                return Err(Error::Frame(format!("output {k} is {}x{}, the input {w}x{h}", out.width, out.height)));
            }
        }
        let key = InputKey { format: input.format, width: w, height: h, direct: false, gpu: true };
        if self.key != Some(key) {
            // A new size or format: a new pair of source frames (another format of the same size could keep the
            // previous frame, but streams do not change format midway).
            self.sources = (0..2)
                .map(|_| {
                    let tex = texture(device, w, h, "gpufx nn source frame");
                    let view = tex.create_view(&Default::default());
                    Source { slot: InputSlot::new(device, conv, key, false, vec![tex], None), view }
                })
                .collect();
            self.between.clear();
            self.key = Some(key);
            self.have_prev = false;
            self.scene.fresh = true;
        }
        if !self.have_prev && self.times.iter().any(|&t| t < 1.0) {
            return Err(Error::Frame("frames in between need a previous source frame".into()));
        }
        let next = if self.have_prev { 1 - self.cur } else { self.cur };
        self.sources[next].slot.use_gpu_frame(device, queue, conv, &input.planes, &input.color);
        {
            let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("gpufx nn source"), timestamp_writes: None });
            self.sources[next].slot.encode(conv, &mut cpass);
        }
        let prev = self.cur;
        if !outs.is_empty() {
            while self.between.len() < outs.len() {
                let texture = texture(device, w, h, "gpufx nn frame in between");
                let view = texture.create_view(&Default::default());
                self.between.push(Between { texture, view, slot: GpuOutputSlot::new(device, input.format, w, h) });
            }
            let (prev_view, cur_view) = (&self.sources[prev].view, &self.sources[next].view);
            for (k, &t) in self.times.iter().enumerate().filter(|(_, t)| **t < 1.0) {
                self.interp.encode(enc, prev_view, cur_view, &self.between[k].view, w, h, t)?;
            }
            if self.have_prev && self.threshold > 0.0 {
                self.encode_scene(w, h, prev, next, enc);
            }
            for ((b, out), &t) in self.between.iter_mut().zip(outs).zip(&self.times) {
                // t = 1: the source frame itself, converted back into the output frame.
                let source = if t >= 1.0 { &self.sources[next].slot.texture } else { &b.texture };
                if b.slot.key != (out.format, w, h) {
                    b.slot = GpuOutputSlot::new(device, out.format, w, h);
                }
                b.slot.bind(device, queue, conv, source, &out.planes, &out.color)?;
            }
            let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("gpufx nn out"), timestamp_writes: None });
            for b in &self.between[..outs.len()] {
                b.slot.encode(conv, &mut cpass)?;
            }
        } else if self.have_prev && self.threshold > 0.0 {
            // Every pair with a previous frame is scored, with or without frames in between, so the previous
            // difference tracks consecutive pairs.
            self.encode_scene(w, h, prev, next, enc);
        }
        self.cur = next;
        self.have_prev = true;
        Ok(())
    }

    /// The scene check of the pair and, on a cut, the nearer source frame over every frame in between.
    fn encode_scene(&mut self, w: u32, h: u32, prev: usize, next: usize, enc: &mut wgpu::CommandEncoder) {
        let device = &self.ctx.device;
        let n = self.times.len();
        // One slot at least: the scoring runs without frames in between too.
        let slots = n.max(1);
        let step = ((w as u64 * h as u64).div_ceil(SCENE_SAMPLES) as f64).sqrt().ceil().max(1.0) as u32;
        let (nx, ny) = (w.div_ceil(step), h.div_ceil(step));
        let (prev, cur) = (&self.sources[prev].view, &self.sources[next].view);
        let s = &mut self.scene;
        let size = PARAM_SLOT * slots as u64;
        if s.params.as_ref().is_none_or(|p| p.size() < size) {
            s.params = Some(device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("gpufx nn scene params"),
                size,
                usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }));
        }
        let params = s.params.as_ref().expect("made");
        for k in 0..slots {
            let t = self.times.get(k).copied().unwrap_or(0.5);
            let words = [w, h, step, nx * ny, self.threshold.to_bits(), t.to_bits()];
            let bytes: Vec<u8> = words.iter().flat_map(|v| v.to_le_bytes()).collect();
            self.ctx.queue.write_buffer(params, k as u64 * PARAM_SLOT, &bytes);
        }
        let groups: Vec<wgpu::BindGroup> = (0..slots)
            .map(|k| {
                device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("gpufx nn scene"),
                    layout: &s.layout,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                                buffer: params,
                                offset: k as u64 * PARAM_SLOT,
                                size: wgpu::BufferSize::new(PARAM_SLOT),
                            }),
                        },
                        wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(prev) },
                        wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(cur) },
                        wgpu::BindGroupEntry { binding: 3, resource: s.state.as_entire_binding() },
                        wgpu::BindGroupEntry {
                            binding: 4,
                            resource: wgpu::BindingResource::TextureView(if k < n { &self.between[k].view } else { &s.dummy }),
                        },
                    ],
                })
            })
            .collect();
        // The sum restarts for every pair; the previous difference only after a discontinuity.
        enc.clear_buffer(&s.state, 0, if s.fresh { None } else { Some(4) });
        s.fresh = false;
        let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("gpufx nn scene"), timestamp_writes: None });
        cpass.set_bind_group(0, &groups[0], &[]);
        cpass.set_pipeline(&s.sad);
        cpass.dispatch_workgroups(nx.div_ceil(16), ny.div_ceil(16), 1);
        cpass.set_pipeline(&s.decide);
        cpass.dispatch_workgroups(1, 1, 1);
        cpass.set_pipeline(&s.select);
        // A t = 1 output is the source frame itself: never replaced.
        for (g, _) in groups.iter().zip(&self.times).filter(|(_, t)| **t < 1.0) {
            cpass.set_bind_group(0, g, &[]);
            cpass.dispatch_workgroups(w.div_ceil(16), h.div_ceil(16), 1);
        }
    }
}

impl GpuStage for InterpFrames {
    fn context(&self) -> &Arc<GpuContext> {
        &self.ctx
    }

    fn interop(&mut self) -> &mut Interop {
        &mut self.interop
    }

    fn encode_gpu(
        &mut self,
        inputs: &[GpuFrame],
        outs: &[GpuFrame],
        _info: Option<&FrameInfo>,
        enc: &mut wgpu::CommandEncoder,
    ) -> Result<(), Error> {
        match inputs {
            [input] => self.encode(input, outs, enc),
            _ => Err(Error::Frame(format!("frame interpolation takes one input frame, got {}", inputs.len()))),
        }
    }
}
