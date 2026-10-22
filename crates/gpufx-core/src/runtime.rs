//! GPU execution of an effect package with wgpu (Vulkan, DirectX 12, Metal).

use std::collections::HashMap;
use std::sync::Arc;

use crate::convert::Converter;
use crate::frame::{Frame, FrameMut};
use crate::graph::{run, FrameIo, Topology};
use crate::manifest::{PassDef, PixelLayout, Plane, ShaderLanguage};
use crate::mips::MipGen;
use crate::package::Package;
use crate::params::ParamBlock;
use crate::shader_cache::{PipelineDesc, ShaderCache, ShaderCacheStats};
use crate::Error;

/// Graphics API to run on. `Auto` lets wgpu pick the best one for the platform.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Backend {
    #[default]
    Auto,
    Vulkan,
    Dx12,
    Metal,
}

impl std::str::FromStr for Backend {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Error> {
        Ok(match s.to_ascii_lowercase().as_str() {
            "" | "auto" => Backend::Auto,
            "vulkan" | "vk" => Backend::Vulkan,
            "dx12" | "d3d12" | "directx" => Backend::Dx12,
            "metal" | "mtl" => Backend::Metal,
            _ => return Err(Error::Gpu(format!("unknown backend `{s}`"))),
        })
    }
}

impl Backend {
    fn wgpu(self) -> wgpu::Backends {
        match self {
            Backend::Auto => wgpu::Backends::all(),
            Backend::Vulkan => wgpu::Backends::VULKAN,
            Backend::Dx12 => wgpu::Backends::DX12,
            Backend::Metal => wgpu::Backends::METAL,
        }
    }
}

/// Optional features a device asks for when the adapter has them.
pub(crate) const GPU_FEATURES: wgpu::Features = wgpu::Features::PIPELINE_CACHE
    .union(wgpu::Features::SHADER_F16)
    .union(wgpu::Features::TEXTURE_FORMAT_16BIT_NORM)
    .union(wgpu::Features::TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES)
    // Tensor cores through WGSL `enable wgpu_cooperative_matrix;` (Vulkan only in wgpu 30).
    .union(wgpu::Features::EXPERIMENTAL_COOPERATIVE_MATRIX);

/// Whether `adapter` lists the 16x16x16 cooperative matrix with f16 A/B and an f32 accumulator.
pub(crate) fn coop_f16(adapter: &wgpu::Adapter) -> bool {
    use wgpu::CooperativeScalarType as T;
    adapter.features().contains(wgpu::Features::EXPERIMENTAL_COOPERATIVE_MATRIX)
        && adapter
            .cooperative_matrix_properties()
            .iter()
            .any(|p| (p.m_size, p.n_size, p.k_size) == (16, 16, 16) && p.ab_type == T::F16 && p.cr_type == T::F32)
}

/// The high-performance adapter of `backend`, else its software fallback.
/// Whether the planes of a `pixel_layout` other than `rgba` can be 16-bit floats: the
/// storage of `r16float`/`rg16float` is an adapter specific format feature.
fn plane_f16(adapter: &wgpu::Adapter, device: &wgpu::Device) -> bool {
    device.features().contains(wgpu::Features::TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES)
        && [wgpu::TextureFormat::R16Float, wgpu::TextureFormat::Rg16Float]
            .iter()
            .all(|&f| adapter.get_texture_format_features(f).allowed_usages.contains(wgpu::TextureUsages::STORAGE_BINDING))
}

/// The texture format of `plane` of a pass texture: `deep` picks `rgba16float` over
/// `rgba8unorm` for `rgba`; `f16` (see [`GpuContext::plane_f16`]) 16-bit planes over 32-bit ones.
pub(crate) fn plane_format(plane: Plane, deep: bool, f16: bool) -> wgpu::TextureFormat {
    use wgpu::TextureFormat as F;
    match (plane.channels(), f16) {
        (4, _) => {
            if deep {
                F::Rgba16Float
            } else {
                F::Rgba8Unorm
            }
        }
        (2, true) => F::Rg16Float,
        (2, false) => F::Rg32Float,
        (_, true) => F::R16Float,
        (_, false) => F::R32Float,
    }
}

/// The WGSL name of a storage texture format of [`plane_format`].
pub(crate) fn wgsl_format(f: wgpu::TextureFormat) -> &'static str {
    use wgpu::TextureFormat as F;
    match f {
        F::Rgba16Float => "rgba16float",
        F::Rgba8Unorm => "rgba8unorm",
        F::Rg16Float => "rg16float",
        F::Rg32Float => "rg32float",
        F::R16Float => "r16float",
        _ => "r32float",
    }
}

pub(crate) fn request_adapter(backend: Backend) -> Result<wgpu::Adapter, Error> {
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: backend.wgpu(),
        // Honours WGPU_DX12_COMPILER (fxc, dxc) and the other backend variables.
        backend_options: wgpu::BackendOptions::from_env_or_default(),
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    });
    let request = |force_fallback_adapter| {
        pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            force_fallback_adapter,
            compatible_surface: None,
            ..Default::default()
        }))
    };
    // Machines without a GPU (CI runners, servers) may still have a software adapter
    // such as WARP on Windows; try it before giving up.
    request(false).or_else(|first| {
        request(true)
            .map_err(|fallback| Error::Gpu(format!("no GPU adapter for backend {backend:?}: {first}; software fallback: {fallback}")))
    })
}

/// A device on `adapter` with the features and limits gpufx uses (see [`device_limits`])
/// plus `extra` when the adapter has them.
fn open_device(adapter: &wgpu::Adapter, label: &str, extra: wgpu::Features) -> Result<(wgpu::Device, wgpu::Queue), Error> {
    pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some(label),
        required_limits: device_limits(&adapter.limits()),
        // PIPELINE_CACHE: only Vulkan has it in wgpu 30; it costs nothing until a cache
        // is created. The format features let GPU frames have 16-bit and r8/rg8
        // storage planes (see GpuFrame).
        required_features: adapter.features() & (crate::profile::features() | extra),
        // SAFETY: it only unlocks EXPERIMENTAL_COOPERATIVE_MATRIX, which only shaders that
        // `enable wgpu_cooperative_matrix;` use.
        experimental_features: unsafe { wgpu::ExperimentalFeatures::enabled() },
        ..Default::default()
    }))
    .map_err(|e| Error::Gpu(e.to_string()))
}

/// Limits a device asks for, from what the adapter supports. Output planes are encoded into
/// storage buffers: allow what the adapter allows, an 8K RGBA64 frame is above the 128 MiB default.
/// `max_buffer_size` stays within `u32::MAX`: wgpu-core asserts it when it creates a device, and a
/// raw Vulkan adapter (`expose_adapter`) reports the driver's `maxBufferSize` unclamped (NVIDIA: above 4 GiB).
pub(crate) fn device_limits(supported: &wgpu::Limits) -> wgpu::Limits {
    let max_buffer_size = supported.max_buffer_size.min(u32::MAX as u64);
    wgpu::Limits {
        max_storage_buffer_binding_size: supported.max_storage_buffer_binding_size.min(max_buffer_size),
        max_buffer_size,
        ..Default::default()
    }
}

/// A GPU device. One context can be shared by many effects.
pub struct GpuContext {
    /// The D3D12 device shared with the caller (see `d3d12.rs`), `None` otherwise. First, so
    /// its D3D12 objects are released before `device`, whose drop may unload d3d12.dll
    /// (D3D11 frames also pin it, see `from_d3d11`, as graphs hold D3D12 objects too).
    #[cfg(windows)]
    pub(crate) d3d12: Option<crate::d3d12::Shared>,
    pub(crate) device: wgpu::Device,
    pub(crate) queue: wgpu::Queue,
    pub(crate) info: wgpu::AdapterInfo,
    pub(crate) conv: Converter,
    pub(crate) mips: MipGen,
    /// Per-frame textures and buffers shared by every graph on this device (see `pool.rs`).
    pub(crate) pool: crate::pool::Pool,
    pub(crate) shader_cache: Option<Arc<ShaderCache>>,
    /// Queue family of a shared Vulkan device (see `vulkan.rs`), `None` for devices
    /// gpufx made itself.
    #[cfg_attr(not(any(windows, all(unix, not(target_vendor = "apple")))), allow(dead_code))]
    pub(crate) vulkan_queue_family: Option<u32>,
    /// The adapter lists 16x16x16 cooperative matrices with f16 A/B and an f32 accumulator,
    /// the shape of the tensor core convolutions (see `nn::kernels::coop_available`).
    pub(crate) coop_f16: bool,
    /// The adapter can write `r16float` and `rg16float` storage textures: planes of a
    /// `pixel_layout` other than `rgba` use them (else `r32float`/`rg32float`).
    pub(crate) plane_f16: bool,
    /// Held while Vulkan frames stage their semaphores and submit; true once a submission
    /// failed (the device is then no longer used for Vulkan frames).
    #[cfg_attr(not(any(windows, all(unix, not(target_vendor = "apple")))), allow(dead_code))]
    pub(crate) vulkan_submit: std::sync::Mutex<bool>,
    /// What a context for VideoToolbox frames knows of its Metal device (see `videotoolbox.rs`).
    #[cfg(target_vendor = "apple")]
    pub(crate) videotoolbox: Option<crate::videotoolbox::Shared>,
}

impl GpuContext {
    /// A device on `backend`; `GPUFX_SHADER_CACHE` names the on-disk shader cache.
    pub fn new(backend: Backend) -> Result<Arc<Self>, Error> {
        Self::with_shader_cache(backend, None)
    }

    /// [`GpuContext::new`] with the shader cache in `cache_dir` (falls back to
    /// `GPUFX_SHADER_CACHE` when `None`).
    pub fn with_shader_cache(backend: Backend, cache_dir: Option<&std::path::Path>) -> Result<Arc<Self>, Error> {
        Self::open_adapter(&request_adapter(backend)?, "gpufx", cache_dir)
    }

    /// A D3D12 device whose shader cache records the DXIL of package pipelines (see
    /// [`crate::precompile`]).
    #[cfg(windows)]
    pub(crate) fn for_precompile() -> Result<Arc<Self>, Error> {
        let adapter = request_adapter(Backend::Dx12)?;
        if !adapter.features().contains(wgpu::Features::PASSTHROUGH_SHADERS) {
            return Err(Error::Gpu(format!("{} has no passthrough shaders", adapter.get_info().name)));
        }
        let (device, queue) = open_device(&adapter, "gpufx precompile", wgpu::Features::PASSTHROUGH_SHADERS)?;
        let info = adapter.get_info();
        let cache = ShaderCache::recorder(&device, &info)?;
        Ok(Self::assemble(device, queue, info, Some(Arc::new(cache))))
    }

    /// A device that runs nothing (wgpu's noop backend), to open effects before the device
    /// they run on is known: their shaders are compiled and checked, no GPU memory is used.
    pub fn noop() -> Result<Arc<Self>, Error> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::NOOP,
            backend_options: wgpu::BackendOptions {
                // It reports no format features: without the adapter's own, the WebGPU
                // defaults apply, which cover what effects use.
                noop: wgpu::NoopBackendOptions {
                    enable: true,
                    features: Some(
                        GPU_FEATURES
                            - wgpu::Features::TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES
                            - wgpu::Features::EXPERIMENTAL_COOPERATIVE_MATRIX,
                    ),
                    ..Default::default()
                },
                ..Default::default()
            },
            ..wgpu::InstanceDescriptor::new_without_display_handle()
        });
        let adapter = pollster::block_on(instance.request_adapter(&Default::default())).map_err(|e| Error::Gpu(e.to_string()))?;
        Self::open_adapter(&adapter, "gpufx noop", None)
    }

    /// A device on `adapter` with the features and limits gpufx uses (see [`device_limits`]).
    pub(crate) fn open_adapter(adapter: &wgpu::Adapter, label: &str, cache_dir: Option<&std::path::Path>) -> Result<Arc<Self>, Error> {
        let mut extra = wgpu::Features::empty();
        if adapter.get_info().backend == wgpu::Backend::Dx12 && crate::shader_cache::configured(cache_dir) {
            // The DXIL shader cache (dxil.rs) loads its shaders as passthrough shaders.
            extra |= wgpu::Features::PASSTHROUGH_SHADERS;
        }
        let (device, queue) = open_device(adapter, label, extra)?;
        let mut ctx = Self::from_device(device, queue, adapter.get_info(), cache_dir);
        let c = Arc::get_mut(&mut ctx).expect("new");
        c.coop_f16 = coop_f16(adapter);
        c.plane_f16 = plane_f16(adapter, &c.device);
        Ok(ctx)
    }

    pub(crate) fn from_device(
        device: wgpu::Device,
        queue: wgpu::Queue,
        info: wgpu::AdapterInfo,
        cache_dir: Option<&std::path::Path>,
    ) -> Arc<Self> {
        let shader_cache = ShaderCache::new(cache_dir.map(|d| d.to_path_buf()), &device, &info).map(Arc::new);
        Self::assemble(device, queue, info, shader_cache)
    }

    fn assemble(device: wgpu::Device, queue: wgpu::Queue, info: wgpu::AdapterInfo, shader_cache: Option<Arc<ShaderCache>>) -> Arc<Self> {
        let conv = Converter::new(&device, shader_cache.clone());
        Arc::new(GpuContext {
            device,
            queue,
            info,
            conv,
            mips: MipGen::default(),
            pool: Default::default(),
            shader_cache,
            vulkan_queue_family: None,
            coop_f16: false,
            plane_f16: false,
            vulkan_submit: std::sync::Mutex::new(false),
            #[cfg(target_vendor = "apple")]
            videotoolbox: None,
            #[cfg(windows)]
            d3d12: None,
        })
    }

    /// The shader cache, for [`crate::precompile`].
    #[cfg(windows)]
    pub(crate) fn shader_cache(&self) -> Option<&ShaderCache> {
        self.shader_cache.as_deref()
    }

    /// The wgpu device, to make textures for [`crate::GpuFrame`]s and command encoders
    /// for [`crate::EffectGraph::encode_gpu`].
    pub fn device(&self) -> &wgpu::Device {
        &self.device
    }

    pub fn queue(&self) -> &wgpu::Queue {
        &self.queue
    }

    /// Counters of the on-disk shader cache, `None` when it is off or the backend has none.
    pub fn shader_cache_stats(&self) -> Option<ShaderCacheStats> {
        self.shader_cache.as_ref().map(|c| c.stats())
    }

    /// What the frame resource pool shared by the graphs of this device holds, for tests
    /// and diagnostics.
    pub fn pool_stats(&self) -> crate::PoolStats {
        self.pool.stats()
    }

    /// e.g. `"NVIDIA GeForce RTX 4070 (Vulkan)"`.
    pub fn description(&self) -> String {
        format!("{} ({:?})", self.info.name, self.info.backend)
    }

    /// What the `requires` of manifest pass groups are matched against.
    pub fn target(&self) -> crate::requires::Target {
        crate::requires::Target {
            os: crate::requires::Target::current_os(),
            backend: self.info.backend,
            vendor: self.info.vendor,
            name: self.info.name.clone(),
            features: self.device.features(),
            coop_f16: self.coop_f16,
            is_noop: self.info.backend == wgpu::Backend::Noop,
        }
    }

    /// The adapter lists 16x16x16 cooperative matrices with f16 A/B and an f32 accumulator.
    /// Metal exposes cooperative matrices too, but only 8x8.
    pub fn has_coop_f16(&self) -> bool {
        self.coop_f16
    }
}

/// A tightly or loosely packed RGBA8 image in CPU memory. [`Frame`] takes other formats.
#[derive(Debug, Clone, Copy)]
pub struct Image<'a> {
    pub data: &'a [u8],
    pub width: u32,
    pub height: u32,
    /// Bytes per row; at least `width * 4`.
    pub stride: u32,
}

/// Where an effect writes its RGBA8 result.
#[derive(Debug)]
pub struct ImageMut<'a> {
    pub data: &'a mut [u8],
    pub width: u32,
    pub height: u32,
    /// Bytes per row; at least `width * 4`.
    pub stride: u32,
}

/// Per-frame values exposed to shaders through `globals`.
#[derive(Debug, Clone, Copy)]
pub struct FrameInfo {
    /// Presentation time in seconds.
    pub time: f64,
    /// Index of the frame.
    pub frame: u64,
    /// Width of a pixel divided by its height (sample aspect ratio), 1 for square pixels.
    pub pixel_aspect: f64,
}

impl FrameInfo {
    pub fn new(time: f64, frame: u64) -> Self {
        FrameInfo { time, frame, pixel_aspect: 1.0 }
    }
}

/// Size of the `GpufxGlobals` uniform struct.
const GLOBALS_SIZE: u64 = 32;

/// `GpufxGlobals` as the shaders see it: see `prelude`.
fn globals_bytes(size: (u32, u32), info: &FrameInfo) -> [u8; GLOBALS_SIZE as usize] {
    // f32 time loses precision as the clip goes on (a 1 day timestamp moves by about
    // 0.008 s steps), so whole seconds and the fraction are also given apart.
    // Beyond the i32 range (68 years) the time saturates.
    let t = if info.time.is_finite() { info.time.clamp(i32::MIN as f64, i32::MAX as f64) } else { 0.0 };
    let whole = t.floor();
    let mut frac = (t - whole) as f32;
    let mut whole = whole as i32;
    if frac >= 1.0 {
        // t just below an integer rounds up in f32.
        frac = 0.0;
        whole = whole.saturating_add(1);
    }
    let pixel_aspect = if info.pixel_aspect.is_finite() && info.pixel_aspect > 0.0 { info.pixel_aspect } else { 1.0 };
    let mut g = [0u8; GLOBALS_SIZE as usize];
    g[0..4].copy_from_slice(&(size.0 as f32).to_le_bytes());
    g[4..8].copy_from_slice(&(size.1 as f32).to_le_bytes());
    g[8..12].copy_from_slice(&(t as f32).to_le_bytes());
    g[12..16].copy_from_slice(&(info.frame as u32).to_le_bytes());
    g[16..20].copy_from_slice(&whole.to_le_bytes());
    g[20..24].copy_from_slice(&frac.to_le_bytes());
    g[24..28].copy_from_slice(&(pixel_aspect as f32).to_le_bytes());
    g
}

pub(crate) const WORKGROUP: u32 = 8;
const FIRST_TEXTURE_BINDING: u32 = 4;

pub(crate) struct Pass {
    pipeline: wgpu::ComputePipeline,
    layout: wgpu::BindGroupLayout,
    pub(crate) inputs: Vec<String>,
    /// The textures it writes: the main one at binding 2, then the extra ones bound after
    /// the inputs (see [`extra_output_binding`]).
    pub(crate) outputs: Vec<String>,
    /// The keys of the textures bound to `inputs` and `outputs`, in binding order: the names
    /// themselves, except for the planes of a `pixel_layout` other than `rgba`
    /// (see [`PixelLayout::plane_key`]).
    pub(crate) input_keys: Vec<String>,
    pub(crate) output_keys: Vec<String>,
    /// The effect output whose size the pass runs at (see [`crate::Manifest::pass_size`]).
    pub(crate) size_of: usize,
    /// The shader defines a function named `gpufx_output_size`.
    pub(crate) sizes_output: bool,
}

/// Binding of extra output `k` (1-based: `out_tex{k}`) of a pass reading `n_inputs` textures.
fn extra_output_binding(n_inputs: usize, k: usize) -> u32 {
    FIRST_TEXTURE_BINDING + n_inputs as u32 + (k - 1) as u32
}

/// Pass outputs and bind groups of one effect, for one set of input textures.
#[derive(Clone)]
pub(crate) struct Bound {
    /// The input textures, to bind again when the pipelines change.
    inputs: Vec<wgpu::Texture>,
    /// The size of each effect output; a pass runs at the size of one of them.
    sizes: Vec<(u32, u32)>,
    /// Pass outputs are `rgba16float` (else `rgba8unorm`).
    deep: bool,
    outputs: HashMap<String, wgpu::Texture>,
    /// One per pass, `None` for a pass that does not run (see [`Effect::set_used_outputs`]).
    bind_groups: Vec<Option<wgpu::BindGroup>>,
}

/// The immutable, compiled part of an effect: package, pipelines, textures and sampler.
/// One program can back many [`Effect`]s on the same device, so a package used by
/// several filters is read and compiled once.
pub struct Program {
    pub(crate) ctx: Arc<GpuContext>,
    pub(crate) package: Package,
    /// Pipelines writing `rgba8unorm`, for chains of 8-bit frames.
    passes: Vec<Pass>,
    /// Pipelines writing `rgba16float`, compiled the first time a deeper frame comes.
    deep_passes: std::sync::OnceLock<Result<Vec<Pass>, String>>,
    sampler: wgpu::Sampler,
    /// Texts of the `expr` parameter defaults the pipelines were built with.
    pub(crate) default_exprs: Vec<String>,
    /// Package textures, viewed with their dimension and every mip level.
    textures: HashMap<String, wgpu::TextureView>,
    /// For each output, the pipeline running the `gpufx_output_size` of the pass writing
    /// it, when that shader has one (else the output has the size of the first input).
    size_passes: Vec<Option<Arc<SizePass>>>,
}

/// A one-thread pipeline calling `gpufx_output_size(out_index)` of a pass shader.
pub(crate) struct SizePass {
    pipeline: wgpu::ComputePipeline,
    layout: wgpu::BindGroupLayout,
    /// The parameters it reads: they must keep their values once the size is known.
    reads: Vec<String>,
}

/// Binding of the buffer a size pipeline reads the input sizes from and writes its result to.
const SIZE_BINDING: u32 = 64;

impl Program {
    /// The package is compiled with the first pass group matching the device,
    /// which becomes the passes of [`Program::package`]. On the noop device (see
    /// [`GpuContext::noop`]) every group of this OS is compiled, to check its shaders, and
    /// the first one kept; a group needing features the noop device lacks is left out, its
    /// shaders could not be checked there. A package already resolved to one group is compiled
    /// as is.
    pub fn new(ctx: Arc<GpuContext>, package: Package) -> Result<Arc<Self>, Error> {
        // Already resolved to one group, e.g. the package of another program.
        if package.manifest.groups.is_empty() {
            return Self::compile(ctx, package);
        }
        let target = ctx.target();
        let mut found = package.manifest.matching_groups(&target)?;
        if target.is_noop {
            let mut missing = Vec::new();
            found.retain(|&g| {
                let m = package.manifest.groups[g].requires.features_missing(&target);
                missing.extend(m.iter().map(|f| f.to_string()));
                m.is_empty()
            });
            if found.is_empty() {
                missing.sort();
                missing.dedup();
                return Err(Error::Unsupported(format!(
                    "effect `{}`: every group needs features the device is not known to have yet ({})",
                    package.manifest.name,
                    missing.join(", ")
                )));
            }
            for &g in &found[1..] {
                Self::compile(ctx.clone(), package.with_group(g))?;
            }
        }
        Self::compile(ctx, package.with_group(found[0]))
    }

    /// [`Program::new`] for a package resolved to one group.
    fn compile(ctx: Arc<GpuContext>, package: Package) -> Result<Arc<Self>, Error> {
        debug_assert!(package.manifest.groups.is_empty(), "only a package resolved to one group is compiled (see Program::new)");
        // Only the layout of the block matters for compiling; values live in each Effect.
        let params = ParamBlock::new(&package.manifest.params)?;
        let device = &ctx.device;
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("gpufx sampler"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            // Only textures with mips see this: one-level textures sample as before.
            mipmap_filter: wgpu::MipmapFilterMode::Linear,
            ..Default::default()
        });

        let limits = device.limits();
        let mut textures = HashMap::new();
        for t in &package.manifest.textures {
            let texels = crate::texture::load(&package, t)?;
            let (w, h, layers) = (texels.width, texels.height, texels.layers);
            // Checked here, not left to wgpu: its errors go to the device error handler,
            // which panics by default and would take the host process down.
            if w > limits.max_texture_dimension_2d || h > limits.max_texture_dimension_2d {
                return Err(Error::Gpu(format!(
                    "texture `{}` is {w}x{h}, this device allows {} a side",
                    t.name, limits.max_texture_dimension_2d
                )));
            }
            if layers > limits.max_texture_array_layers {
                return Err(Error::Gpu(format!(
                    "texture `{}` has {layers} layers, this device allows {}",
                    t.name, limits.max_texture_array_layers
                )));
            }
            // Package images stay 8-bit: they are only read.
            let tex = device.create_texture(&wgpu::TextureDescriptor {
                label: Some(&t.name),
                size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: layers },
                mip_level_count: texels.levels.len() as u32,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba8Unorm,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            });
            for (level, data) in texels.levels.iter().enumerate() {
                let (lw, lh) = ((w >> level).max(1), (h >> level).max(1));
                ctx.queue.write_texture(
                    wgpu::TexelCopyTextureInfo { mip_level: level as u32, ..tex.as_image_copy() },
                    data,
                    wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(lw * 4), rows_per_image: Some(lh) },
                    wgpu::Extent3d { width: lw, height: lh, depth_or_array_layers: layers },
                );
            }
            let dimension = if texels.array { wgpu::TextureViewDimension::D2Array } else { wgpu::TextureViewDimension::D2 };
            let view = tex.create_view(&wgpu::TextureViewDescriptor { dimension: Some(dimension), ..Default::default() });
            textures.insert(t.name.clone(), view);
        }

        let mut passes = Vec::new();
        for (i, def) in package.manifest.passes.iter().enumerate() {
            passes.push(compile_pass(&ctx, &package, &params, i, def, false)?);
        }
        let default_exprs = params.expr_key().into_iter().map(String::from).collect();
        let mut size_passes: Vec<Option<Arc<SizePass>>> = vec![None; package.manifest.outputs.len()];
        for (i, def) in package.manifest.passes.iter().enumerate() {
            if !passes[i].sizes_output {
                continue;
            }
            let sp = Arc::new(compile_size_pass(&ctx, &package, &params, i, def)?);
            for (o, out) in package.manifest.outputs.iter().enumerate() {
                if def.outputs.contains(&out.name) {
                    size_passes[o] = Some(sp.clone());
                }
            }
        }
        Ok(Arc::new(Program { ctx, package, passes, deep_passes: Default::default(), sampler, default_exprs, textures, size_passes }))
    }

    /// The pipelines for one work format; the shaders were validated in `new`.
    pub(crate) fn passes(&self, deep: bool) -> Result<&[Pass], Error> {
        if !deep {
            return Ok(&self.passes);
        }
        let compiled = self.deep_passes.get_or_init(|| {
            let params = ParamBlock::new(&self.package.manifest.params).map_err(|e| e.to_string())?;
            let defs = self.package.manifest.passes.iter().enumerate();
            defs.map(|(i, def)| compile_pass(&self.ctx, &self.package, &params, i, def, true).map_err(|e| e.to_string())).collect()
        });
        // Compiled when the first frame above 8 bits comes: name the package in errors.
        compiled.as_deref().map_err(|e| Error::Shader(format!("{} (rgba16float variant): {e}", self.package.manifest.name)))
    }

    pub fn context(&self) -> &Arc<GpuContext> {
        &self.ctx
    }

    pub fn package(&self) -> &Package {
        &self.package
    }

    /// Some pass shader gives an output its size (`gpufx_output_size`).
    pub fn has_size_functions(&self) -> bool {
        self.size_passes.iter().any(Option::is_some)
    }
}

/// Output sizes from `gpufx_output_size`, fixed when first computed.
struct FixedSizes {
    /// The input sizes they were computed for.
    ins: Vec<(u32, u32)>,
    /// (output, parameter, value) of each parameter a size function read.
    reads: Vec<(usize, String, crate::params::Value)>,
    sizes: Vec<(u32, u32)>,
}

/// An instance of a [`Program`] with its own parameter values and frame buffers.
pub struct Effect {
    pub(crate) program: Arc<Program>,
    pub(crate) params: ParamBlock,
    /// `globals` of the passes running at the size of each output.
    globals: Vec<wgpu::Buffer>,
    params_buf: wgpu::Buffer,
    pub(crate) bound: Option<Bound>,
    /// The passes that run: those writing the outputs in use and what they read. Empty
    /// when all run.
    active: Vec<bool>,
    /// Upload and readback buffers of [`Effect::process`]; a graph has its own.
    io: Option<FrameIo>,
    /// Pipelines built for this effect's own `expr` values, when they differ from the
    /// package defaults the program was compiled with.
    own: Option<OwnPasses>,
    /// Output sizes from `gpufx_output_size`, computed once (again only for other input sizes).
    sizes: std::sync::Mutex<Option<FixedSizes>>,
    /// How many size pipelines ran, for tests.
    size_dispatches: std::sync::atomic::AtomicUsize,
    /// Bindings of recent frame textures made by [`Effect::rebind`], until the next `bind`.
    rebinds: crate::lru::Lru<(Vec<wgpu::Texture>, Vec<Option<wgpu::Texture>>), Bound>,
}

/// Pipelines of an effect whose `expr` parameters were changed.
struct OwnPasses {
    key: Vec<String>,
    passes: Vec<Pass>,
    deep_passes: std::sync::OnceLock<Result<Vec<Pass>, String>>,
}

impl Effect {
    /// Loads and compiles `package` for this effect alone.
    pub fn new(ctx: Arc<GpuContext>, package: Package) -> Result<Self, Error> {
        Self::from_program(Program::new(ctx, package)?)
    }

    /// Creates an effect that shares the compiled `program` with other effects.
    pub fn from_program(program: Arc<Program>) -> Result<Self, Error> {
        let params = ParamBlock::new(&program.package.manifest.params)?;
        let device = &program.ctx.device;
        let globals = (0..program.package.manifest.outputs.len())
            .map(|_| {
                device.create_buffer(&wgpu::BufferDescriptor {
                    label: Some("gpufx globals"),
                    size: GLOBALS_SIZE,
                    usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                    mapped_at_creation: false,
                })
            })
            .collect();
        let params_buf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx params"),
            size: params.size() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        Ok(Effect {
            program,
            params,
            globals,
            params_buf,
            bound: None,
            active: Vec::new(),
            io: None,
            own: None,
            sizes: Default::default(),
            size_dispatches: Default::default(),
            rebinds: Default::default(),
        })
    }

    pub fn program(&self) -> &Arc<Program> {
        &self.program
    }

    pub fn package(&self) -> &Package {
        &self.program.package
    }

    pub fn params(&self) -> &ParamBlock {
        &self.params
    }

    pub fn params_mut(&mut self) -> &mut ParamBlock {
        &mut self.params
    }

    pub fn input_count(&self) -> usize {
        self.program.package.manifest.inputs.len()
    }

    pub fn output_count(&self) -> usize {
        self.program.package.manifest.outputs.len()
    }

    /// Runs only the passes that the outputs in `used` (one flag per output) need: the
    /// passes writing them and, back to front, those writing what these read. The textures
    /// of the others are not made. All run by default.
    pub(crate) fn set_used_outputs(&mut self, used: &[bool]) {
        let m = &self.program.package.manifest;
        let mut needed: Vec<&str> = m.outputs.iter().zip(used).filter(|(_, &u)| u).map(|(o, _)| o.name.as_str()).collect();
        let mut active = vec![false; m.passes.len()];
        for (i, pass) in m.passes.iter().enumerate().rev() {
            if pass.outputs.iter().any(|o| needed.contains(&o.as_str())) {
                active[i] = true;
                // A pass without `inputs` reads every input and texture, none of the passes.
                needed.extend(pass.inputs.iter().flatten().map(String::as_str));
            }
        }
        let active = if active.iter().all(|&a| a) { Vec::new() } else { active };
        if active != self.active {
            self.active = active;
            self.bound = None;
            self.rebinds.clear();
        }
    }

    /// The size of every output for inputs of these sizes: what the `gpufx_output_size` of
    /// the pass writing it gives, else the size of the first input. The sizes are computed
    /// once, on the GPU, and kept: asking again compares the parameters the size functions
    /// read with the values they were computed from (no GPU work), and fails when one
    /// changed. Other input sizes compute them again. Fails when a size is 0, when one pass
    /// would write two sizes, or on the noop device.
    pub fn output_sizes(&self, ins: &[(u32, u32)]) -> Result<Vec<(u32, u32)>, Error> {
        let program = &self.program;
        let m = &program.package.manifest;
        let first = ins.first().copied().unwrap_or((0, 0));
        if !program.has_size_functions() {
            return Ok(vec![first; m.outputs.len()]);
        }
        let what = |o: usize| {
            if m.outputs.len() == 1 {
                format!("output of `{}`", m.name)
            } else {
                format!("output `{}` of `{}`", m.outputs[o].name, m.name)
            }
        };
        let mut fixed = self.sizes.lock().expect("not poisoned");
        if let Some(f) = fixed.as_ref() {
            for o in 0..m.outputs.len() {
                let changed: Vec<String> = f
                    .reads
                    .iter()
                    .filter(|(ro, name, v)| *ro == o && self.params.get(name) != Some(*v))
                    .map(|(_, name, _)| format!("`{name}`"))
                    .collect();
                if !changed.is_empty() {
                    let (noun, verb) = if changed.len() == 1 { ("parameter", "sets") } else { ("parameters", "set") };
                    return Err(Error::Unsupported(format!(
                        "{noun} {} {verb} the size of the {} and must not change while the stream runs",
                        changed.join(", "),
                        what(o)
                    )));
                }
            }
            if f.ins == ins {
                return Ok(f.sizes.clone());
            }
        }
        let ctx = &program.ctx;
        if ctx.info.backend == wgpu::Backend::Noop {
            return Err(Error::Unsupported(format!(
                "`{}` sizes an output in its shader (gpufx_output_size): that needs a GPU, not the noop device",
                m.name
            )));
        }
        let (device, queue) = (&ctx.device, &ctx.queue);
        let params = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx size params"),
            size: self.params.size() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        queue.write_buffer(&params, 0, &self.params.bytes());
        let words: u64 = 8 * (1 + ins.len() as u64);
        let mut sizes = vec![first; m.outputs.len()];
        for (o, sp) in program.size_passes.iter().enumerate() {
            let Some(sp) = sp else { continue };
            self.size_dispatches.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let io = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("gpufx size io"),
                size: words,
                usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            let read = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("gpufx size readback"),
                size: 8,
                usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            let mut data: Vec<u32> = vec![ins.len() as u32, m.size_index(o) as u32];
            data.extend(ins.iter().flat_map(|&(w, h)| [w, h]));
            queue.write_buffer(&io, 0, &data.iter().flat_map(|v| v.to_le_bytes()).collect::<Vec<u8>>());
            let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("gpufx size"),
                layout: &sp.layout,
                entries: &[
                    wgpu::BindGroupEntry { binding: 1, resource: params.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: SIZE_BINDING, resource: io.as_entire_binding() },
                ],
            });
            let mut enc = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("gpufx size") });
            {
                let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("gpufx size"), timestamp_writes: None });
                cpass.set_pipeline(&sp.pipeline);
                cpass.set_bind_group(0, &group, &[]);
                cpass.dispatch_workgroups(1, 1, 1);
            }
            enc.copy_buffer_to_buffer(&io, 0, &read, 0, 8);
            queue.submit([enc.finish()]);
            let (tx, rx) = std::sync::mpsc::channel();
            read.slice(..).map_async(wgpu::MapMode::Read, move |r| {
                let _ = tx.send(r);
            });
            device.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| Error::Gpu(e.to_string()))?;
            rx.recv().map_err(|e| Error::Gpu(e.to_string()))?.map_err(|e| Error::Gpu(e.to_string()))?;
            let bytes = read.slice(..).get_mapped_range().map_err(|e| Error::Gpu(e.to_string()))?.to_vec();
            let word = |i: usize| u32::from_le_bytes(bytes[i * 4..i * 4 + 4].try_into().expect("4 bytes"));
            sizes[o] = (word(0), word(1));
        }
        for (o, &(w, h)) in sizes.iter().enumerate() {
            if w == 0 || h == 0 {
                return Err(Error::Unsupported(format!("{}: gpufx_output_size gives {w}x{h}", what(o))));
            }
        }
        // One pass writes one size, and a texture several passes write keeps one.
        let mut texture: HashMap<&str, (u32, u32)> = HashMap::new();
        for (i, pass) in m.passes.iter().enumerate() {
            let size = sizes[m.pass_size(pass)];
            for (o, out) in m.outputs.iter().enumerate() {
                if pass.outputs.contains(&out.name) && sizes[o] != size {
                    let (a, b) = (&m.outputs[m.pass_size(pass)].name, &out.name);
                    return Err(Error::Unsupported(format!(
                        "pass {i} of `{}` writes `{a}` ({}x{}) and `{b}` ({}x{}): the outputs of one pass have one size",
                        m.name, size.0, size.1, sizes[o].0, sizes[o].1
                    )));
                }
            }
            // An output switched off is a 1x1 stand-in, not at the size of the pass.
            for out in pass.outputs.iter().filter(|n| !m.off_outputs.contains(n)) {
                if let Some(&had) = texture.get(out.as_str()) {
                    if had != size {
                        return Err(Error::Unsupported(format!(
                            "pass {i} of `{}` writes `{out}` at another size than an earlier pass",
                            m.name
                        )));
                    }
                }
                texture.insert(out, size);
            }
        }
        let mut reads = Vec::new();
        for (o, sp) in program.size_passes.iter().enumerate() {
            for name in sp.iter().flat_map(|sp| &sp.reads) {
                if let Some(v) = self.params.get(name) {
                    reads.push((o, name.clone(), v));
                }
            }
        }
        *fixed = Some(FixedSizes { ins: ins.to_vec(), reads, sizes: sizes.clone() });
        Ok(sizes)
    }

    /// How many times a size pipeline (`gpufx_output_size`) ran. For tests.
    #[doc(hidden)]
    pub fn size_dispatches(&self) -> usize {
        self.size_dispatches.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Whether pass `i` runs (see [`Effect::set_used_outputs`]).
    pub(crate) fn runs(&self, i: usize) -> bool {
        self.active.get(i).copied().unwrap_or(true)
    }

    /// The pipelines for one work format: the program's, or this effect's own.
    pub(crate) fn passes(&self, deep: bool) -> Result<&[Pass], Error> {
        let Some(own) = &self.own else { return self.program.passes(deep) };
        if !deep {
            return Ok(&own.passes);
        }
        let program = &self.program;
        let compiled = own.deep_passes.get_or_init(|| {
            let defs = program.package.manifest.passes.iter().enumerate();
            defs.map(|(i, def)| compile_pass(&program.ctx, &program.package, &self.params, i, def, true).map_err(|e| e.to_string()))
                .collect()
        });
        compiled.as_deref().map_err(|e| Error::Shader(format!("{} (rgba16float variant): {e}", program.package.manifest.name)))
    }

    /// Rebuilds the pipelines when an `expr` parameter changed since they were built
    /// (a few milliseconds: change expressions now and then, not every frame), and binds
    /// them to the current textures. On failure the expressions go back to those of the
    /// current pipelines, so the effect keeps running and the failure is not retried.
    pub(crate) fn sync_exprs(&mut self) -> Result<(), Error> {
        let res = self.try_sync_exprs();
        if res.is_err() {
            let good = self.own.as_ref().map_or(&self.program.default_exprs, |own| &own.key).clone();
            self.params.restore_exprs(&good);
        }
        res
    }

    fn try_sync_exprs(&mut self) -> Result<(), Error> {
        let key = self.params.expr_key();
        let current = self.own.as_ref().map_or(&self.program.default_exprs, |own| &own.key);
        if key == *current {
            return Ok(());
        }
        let key: Vec<String> = key.into_iter().map(String::from).collect();
        if key == self.program.default_exprs {
            // Back to the defaults: the program's pipelines.
            self.own = None;
        } else {
            let program = &self.program;
            let defs = program.package.manifest.passes.iter().enumerate();
            let passes = defs
                .map(|(i, def)| compile_pass(&program.ctx, &program.package, &self.params, i, def, false))
                .collect::<Result<Vec<_>, _>>()?;
            let own = OwnPasses { key, passes, deep_passes: Default::default() };
            let previous = self.own.replace(own);
            // Bound to deep frames: build that variant now, so binding cannot fail.
            if self.bound.as_ref().is_some_and(|b| b.deep) {
                if let Err(e) = self.passes(true).map(|_| ()) {
                    self.own = previous;
                    return Err(e);
                }
            }
        }
        if let Some(bound) = self.bound.take() {
            let inputs = bound.inputs.clone();
            self.bind(&inputs.iter().collect::<Vec<_>>(), bound.outputs, &bound.sizes, bound.deep)?;
        }
        Ok(())
    }

    /// Runs every pass on `inputs` (one per manifest input) and writes the RGBA result
    /// into `out`, which must have the output size (the size of `inputs[0]`
    /// unless the manifest output `size` stacks the inputs).
    /// Fails with [`Error::Unsupported`] when the input sizes break the manifest rules.
    pub fn process(&mut self, inputs: &[Image], out: ImageMut, info: &FrameInfo) -> Result<(), Error> {
        let frames: Vec<Frame> = inputs.iter().map(|&i| i.into()).collect();
        self.process_frames(&frames, out.into(), info)
    }

    /// [`Effect::process`] for frames in any [`PixelFormat`]: they are converted to and
    /// from RGBA on the GPU.
    pub fn process_frames(&mut self, inputs: &[Frame], out: FrameMut, info: &FrameInfo) -> Result<(), Error> {
        if self.output_count() != 1 {
            return Err(Error::Unsupported(format!(
                "effect `{}` has {} outputs; run it in an EffectGraph",
                self.package().manifest.name,
                self.output_count()
            )));
        }
        let mut io = self.io.take().unwrap_or_default();
        let topo = Topology::single(self.input_count());
        let res = run(std::slice::from_mut(self), &topo, &mut io, inputs, &mut [out], Some(info));
        self.io = Some(io);
        res
    }

    /// Creates the bind groups for `inputs` (one texture per manifest input) and the
    /// pass `outputs` handed out by `allocate`. Called again whenever they change.
    pub(crate) fn bind(
        &mut self,
        inputs: &[&wgpu::Texture],
        outputs: HashMap<String, wgpu::Texture>,
        sizes: &[(u32, u32)],
        deep: bool,
    ) -> Result<(), Error> {
        self.rebinds.clear();
        self.bound = Some(self.make_bound(inputs, outputs, sizes, deep)?);
        Ok(())
    }

    fn make_bound(
        &self,
        inputs: &[&wgpu::Texture],
        outputs: HashMap<String, wgpu::Texture>,
        sizes: &[(u32, u32)],
        deep: bool,
    ) -> Result<Bound, Error> {
        let program = &self.program;
        let device = &program.ctx.device;
        let passes = self.passes(deep)?;
        let manifest = &program.package.manifest;
        // Frame textures are seen at level 0 only, unless the input asks for its mips.
        let level0 = |t: &wgpu::Texture| t.create_view(&wgpu::TextureViewDescriptor { mip_level_count: Some(1), ..Default::default() });
        // One texture per input, or one per plane of an input with planes (see `input_keys`).
        let input_keys = manifest.input_keys();
        let lookup = |name: &str| -> wgpu::TextureView {
            if let Some(i) = input_keys.iter().position(|k| k == name) {
                if manifest.inputs.iter().any(|d| d.name == name && d.mipmaps) {
                    inputs[i].create_view(&Default::default())
                } else {
                    level0(inputs[i])
                }
            } else if let Some(t) = program.textures.get(name) {
                t.clone()
            } else {
                level0(&outputs[name])
            }
        };
        // Optional outputs switched off: one 1x1 stand-in takes their writes.
        let off = (!manifest.off_outputs.is_empty()).then(|| {
            let format = if deep { wgpu::TextureFormat::Rgba16Float } else { wgpu::TextureFormat::Rgba8Unorm };
            crate::convert::texture_2d(device, "gpufx off output", 1, 1, format, wgpu::TextureUsages::STORAGE_BINDING)
        });
        let f16 = program.ctx.plane_f16;
        let written = |key: &str| {
            let (name, plane) = key.split_once('.').unwrap_or((key, ""));
            match &off {
                // A plane of an output switched off: a 1x1 stand-in of its format.
                Some(_) if !plane.is_empty() && manifest.off_outputs.iter().any(|n| n == name) => {
                    let plane = manifest.layout_of(name).planes().iter().copied().find(|p| p.suffix() == plane).unwrap_or(Plane::Y);
                    let format = plane_format(plane, deep, f16);
                    level0(&crate::convert::texture_2d(device, "gpufx off output", 1, 1, format, wgpu::TextureUsages::STORAGE_BINDING))
                }
                Some(t) if manifest.off_outputs.iter().any(|n| n == name) => level0(t),
                _ => level0(&outputs[key]),
            }
        };
        let bind_groups = passes
            .iter()
            .enumerate()
            .map(|(i, pass)| {
                if !self.runs(i) {
                    return None;
                }
                let views: Vec<wgpu::TextureView> = pass.input_keys.iter().map(|n| lookup(n)).collect();
                let out_view = written(&pass.output_keys[0]);
                let extra_views: Vec<wgpu::TextureView> = pass.output_keys[1..].iter().map(|n| written(n)).collect();
                let mut entries = vec![
                    wgpu::BindGroupEntry { binding: 0, resource: self.globals[pass.size_of].as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 1, resource: self.params_buf.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&out_view) },
                    wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&program.sampler) },
                ];
                for (i, v) in views.iter().enumerate() {
                    entries.push(wgpu::BindGroupEntry {
                        binding: FIRST_TEXTURE_BINDING + i as u32,
                        resource: wgpu::BindingResource::TextureView(v),
                    });
                }
                for (k, v) in extra_views.iter().enumerate() {
                    entries.push(wgpu::BindGroupEntry {
                        binding: extra_output_binding(views.len(), k + 1),
                        resource: wgpu::BindingResource::TextureView(v),
                    });
                }
                Some(device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("gpufx pass"),
                    layout: &pass.layout,
                    entries: &entries,
                }))
            })
            .collect();
        let inputs = inputs.iter().map(|&t| t.clone()).collect();
        Ok(Bound { inputs, sizes: sizes.to_vec(), deep, outputs, bind_groups })
    }

    /// Binds the effect again on `inputs`, keeping its pass textures, with the texture of
    /// output `o` replaced by `outputs[o]` when given (a frame written in place). The
    /// bindings of recent textures are reused (the frames of a pool come back in turn);
    /// returns whether new ones were made.
    pub(crate) fn rebind(&mut self, inputs: &[&wgpu::Texture], outputs: &[Option<&wgpu::Texture>]) -> Result<bool, Error> {
        let bound = self.bound.as_ref().ok_or_else(|| Error::Gpu("the effect is not bound".into()))?;
        let mut textures = bound.outputs.clone();
        for (def, t) in self.program.package.manifest.outputs.iter().zip(outputs) {
            if let Some(t) = t {
                textures.insert(def.name.clone(), (*t).clone());
            }
        }
        let (sizes, deep) = (bound.sizes.clone(), bound.deep);
        let key = (inputs.iter().map(|&t| t.clone()).collect(), outputs.iter().map(|t| t.cloned()).collect());
        let mut rebinds = std::mem::take(&mut self.rebinds);
        let made = rebinds.get_or_make(key, |_| self.make_bound(inputs, textures, &sizes, deep)).map(|(bound, made)| {
            self.bound = Some(bound.clone());
            made
        });
        self.rebinds = rebinds;
        made
    }

    /// The texture of output `o`. Only valid after `bind`, for an output in use.
    pub(crate) fn output(&self, o: usize) -> &wgpu::Texture {
        let bound = self.bound.as_ref().expect("bound before use");
        &bound.outputs[&self.program.package.manifest.outputs[o].name]
    }

    /// The textures of output `o`, one per plane of its `pixel_layout` (the one texture of
    /// an `rgba` output). Only valid after `bind`, for an output in use.
    pub(crate) fn output_planes(&self, o: usize) -> Vec<wgpu::Texture> {
        let bound = self.bound.as_ref().expect("bound before use");
        let def = &self.program.package.manifest.outputs[o];
        def.pixel_layout.planes().iter().map(|&p| bound.outputs[&def.pixel_layout.plane_key(&def.name, p)].clone()).collect()
    }

    pub(crate) fn encode(&self, cpass: &mut wgpu::ComputePass, info: &FrameInfo) {
        let bound = self.bound.as_ref().expect("bound before use");
        let queue = &self.program.ctx.queue;
        let passes = self.passes(bound.deep).expect("compiled in bind");
        for (o, globals) in self.globals.iter().enumerate() {
            if passes.iter().enumerate().any(|(i, p)| p.size_of == o && self.runs(i)) {
                queue.write_buffer(globals, 0, &globals_bytes(bound.sizes[o], info));
            }
        }
        queue.write_buffer(&self.params_buf, 0, &self.params.bytes());
        for (pass, bg) in passes.iter().zip(&bound.bind_groups) {
            let Some(bg) = bg else { continue };
            let (w, h) = bound.sizes[pass.size_of];
            cpass.set_pipeline(&pass.pipeline);
            cpass.set_bind_group(0, bg, &[]);
            cpass.dispatch_workgroups(w.div_ceil(WORKGROUP), h.div_ceil(WORKGROUP), 1);
        }
    }
}

/// Where the copies of the repeated output sit among the outputs of pass `def`: (index of
/// the first, count), or `None` for a pass writing none. The copies are the last outputs
/// of the effect and expand in place in a pass list, so they are contiguous there.
fn pass_copies(pkg: &Package, def: &PassDef) -> Option<(usize, usize)> {
    let n = pkg.output_copies() as usize;
    let outs = &pkg.manifest.outputs;
    let names = &outs[outs.len() - n..];
    let first = def.outputs.iter().position(|o| names.iter().any(|c| c.name == *o))?;
    Some((first, n))
}

/// `gpufx_output_enabled(i)` for a pass writing an optional output (empty for others, so their
/// source and shader cache key stay as they were): whether its output `i` (0 is `out_tex`, k is
/// `out_tex{k}`) is on. A pass output that is off is bound to a 1x1 stand-in: writing it does
/// nothing useful, and the shader may skip the work for it.
fn output_enabled(pkg: &Package, def: &PassDef, glsl: bool) -> String {
    if !pkg.manifest.writes_optional(def) {
        return String::new();
    }
    let off: Vec<String> =
        def.outputs.iter().enumerate().filter(|(_, n)| pkg.manifest.off_outputs.contains(n)).map(|(i, _)| format!("i != {i}u")).collect();
    let test = if off.is_empty() { "true".to_string() } else { off.join(" && ") };
    if glsl {
        format!("bool gpufx_output_enabled(uint i) {{ return {test}; }}\n")
    } else {
        format!("fn gpufx_output_enabled(i: u32) -> bool {{ return {test}; }}\n")
    }
}

/// WGSL declarations prepended to every pass shader. `copies` (see [`pass_copies`]) adds the
/// indexed write helpers, only to a pass writing a repeated output.
fn prelude(
    params: &ParamBlock,
    inputs: &[String],
    arrays: &[bool],
    extra_outputs: usize,
    copies: Option<(usize, usize)>,
    deep: bool,
    planes: Option<&PassPlanes>,
) -> String {
    if let Some(planes) = planes {
        return plane_prelude(params, inputs, arrays, copies, deep, planes);
    }
    let mut s = String::from(
        "// ---- generated by gpufx ----\n\
         struct GpufxGlobals {\n    size: vec2f,\n    time: f32,\n    frame: u32,\n    \
         time_int: i32,\n    time_frac: f32,\n    pixel_aspect: f32,\n    gpufx_reserved: f32,\n};\n",
    );
    s.push_str(&params.wgsl_struct());
    s.push_str(&params.expr_functions(false));
    s.push_str(
        "@group(0) @binding(0) var<uniform> globals: GpufxGlobals;\n\
         @group(0) @binding(1) var<uniform> params: GpufxParams;\n\
         @group(0) @binding(2) var out_tex: texture_storage_2d<",
    );
    s.push_str(if deep { "rgba16float" } else { "rgba8unorm" });
    s.push_str(
        ", write>;\n\
         @group(0) @binding(3) var smp: sampler;\n",
    );
    for (i, name) in inputs.iter().enumerate() {
        let ty = if arrays[i] { "texture_2d_array" } else { "texture_2d" };
        s.push_str(&format!("@group(0) @binding({}) var {name}: {ty}<f32>;\n", FIRST_TEXTURE_BINDING + i as u32));
    }
    let format = if deep { "rgba16float" } else { "rgba8unorm" };
    for k in 1..=extra_outputs {
        s.push_str(&format!(
            "@group(0) @binding({}) var out_tex{k}: texture_storage_2d<{format}, write>;\n\
             fn gpufx_write{k}(id: vec3u, c: vec4f) {{ textureStore(out_tex{k}, vec2i(id.xy), clamp(c, vec4f(0.0), vec4f(1.0))); }}\n",
            extra_output_binding(inputs.len(), k)
        ));
    }
    // Only a pass writing a repeated output gets the indexed helpers, so the prelude (and
    // the shader cache key) of every other pass stays as it was.
    if let Some((first, count)) = copies {
        // The outputs of the pass by index: 0 is `out_tex`, k is `out_tex{k}`; other indices
        // are skipped.
        s.push_str(&format!("fn gpufx_output_count() -> u32 {{ return {}u; }}\nfn gpufx_write_at(i: u32, id: vec3u, c: vec4f) {{\n    switch i {{\n        case 0u: {{ gpufx_write(id, c); }}\n", extra_outputs + 1));
        for k in 1..=extra_outputs {
            s.push_str(&format!("        case {k}u: {{ gpufx_write{k}(id, c); }}\n"));
        }
        s.push_str("        default: {}\n    }\n}\n");
        // The copies only: copy j is pass output `first + j`, whatever the pass writes before.
        s.push_str(&format!(
            "fn gpufx_copy_count() -> u32 {{ return {count}u; }}\n\
             fn gpufx_write_copy(j: u32, id: vec3u, c: vec4f) {{ if (j < {count}u) {{ gpufx_write_at({first}u + j, id, c); }} }}\n"
        ));
    }
    s.push_str(
        "fn gpufx_in_bounds(id: vec3u) -> bool { return f32(id.x) < globals.size.x && f32(id.y) < globals.size.y; }\n\
         fn gpufx_uv(id: vec3u) -> vec2f { return (vec2f(id.xy) + 0.5) / globals.size; }\n\
         fn gpufx_write(id: vec3u, c: vec4f) { textureStore(out_tex, vec2i(id.xy), clamp(c, vec4f(0.0), vec4f(1.0))); }\n\
         // ---- end of gpufx prelude ----\n",
    );
    s
}

/// The `pixel_layout` of each texture a pass binds, for a pass with planes (see
/// [`crate::Manifest::pass_has_planes`]); other passes get none, so their prelude and
/// shader cache key are as before planes existed.
pub(crate) struct PassPlanes {
    /// One per pass input (package textures are `rgba`).
    pub(crate) inputs: Vec<PixelLayout>,
    /// One per pass output.
    pub(crate) outputs: Vec<PixelLayout>,
    /// Planes are 16-bit floats (see [`GpuContext::plane_f16`]).
    pub(crate) f16: bool,
}

impl PassPlanes {
    fn of(ctx: &GpuContext, pkg: &Package, inputs: &[String], def: &PassDef) -> Option<Self> {
        let m = &pkg.manifest;
        m.pass_has_planes(def).then(|| PassPlanes {
            inputs: inputs.iter().map(|n| m.layout_of(n)).collect(),
            outputs: def.outputs.iter().map(|n| m.layout_of(n)).collect(),
            f16: ctx.plane_f16,
        })
    }

    /// The sampled textures, in binding order: (key, input index, plane).
    fn textures(&self, inputs: &[String]) -> Vec<(String, usize, Plane)> {
        inputs
            .iter()
            .zip(&self.inputs)
            .enumerate()
            .flat_map(|(i, (n, l))| l.planes().iter().map(move |&p| (l.plane_key(n, p), i, p)))
            .collect()
    }

    /// The storage textures, in binding order (the first at binding 2): (key, output index, plane).
    fn storage(&self, outputs: &[String]) -> Vec<(String, usize, Plane)> {
        outputs
            .iter()
            .zip(&self.outputs)
            .enumerate()
            .flat_map(|(k, (n, l))| l.planes().iter().map(move |&p| (l.plane_key(n, p), k, p)))
            .collect()
    }
}

/// The prelude of a pass with planes: an `rgba` input is bound as `<name>` and an `rgba`
/// output written with `gpufx_write{k}` as in [`prelude`]; a planar input is bound as
/// `in_<name>_y`/`_uv`/`_a`, a planar output written with `gpufx_write{k}_y`/`_uv`/`_a(p, v)`
/// (`p` is the texel of that plane) and `gpufx_chroma_scale{k}()` gives the luma pixels one
/// UV texel spans. Bindings: the storage textures in order, the first at 2, the others after
/// the sampled ones (see [`extra_output_binding`]).
fn plane_prelude(
    params: &ParamBlock,
    inputs: &[String],
    arrays: &[bool],
    copies: Option<(usize, usize)>,
    deep: bool,
    planes: &PassPlanes,
) -> String {
    let mut s = String::from(
        "// ---- generated by gpufx (planes) ----\n\
         struct GpufxGlobals {\n    size: vec2f,\n    time: f32,\n    frame: u32,\n    \
         time_int: i32,\n    time_frac: f32,\n    pixel_aspect: f32,\n    gpufx_reserved: f32,\n};\n",
    );
    s.push_str(&params.wgsl_struct());
    s.push_str(&params.expr_functions(false));
    s.push_str(
        "@group(0) @binding(0) var<uniform> globals: GpufxGlobals;\n\
         @group(0) @binding(1) var<uniform> params: GpufxParams;\n\
         @group(0) @binding(3) var smp: sampler;\n",
    );
    let textures = planes.textures(inputs);
    for (b, (_, i, plane)) in textures.iter().enumerate() {
        let name = &inputs[*i];
        let ty = if arrays[*i] { "texture_2d_array" } else { "texture_2d" };
        let var = if *plane == Plane::Rgba { name.clone() } else { format!("in_{name}_{}", plane.suffix()) };
        s.push_str(&format!("@group(0) @binding({}) var {var}: {ty}<f32>;\n", FIRST_TEXTURE_BINDING + b as u32));
    }
    let outputs: Vec<String> = (0..planes.outputs.len()).map(|k| k.to_string()).collect();
    for (j, (_, k, plane)) in planes.storage(&outputs).iter().enumerate() {
        let binding = if j == 0 { 2 } else { extra_output_binding(textures.len(), j) };
        let ks = if *k == 0 { String::new() } else { k.to_string() };
        let format = wgsl_format(plane_format(*plane, deep, planes.f16));
        if *plane == Plane::Rgba {
            s.push_str(&format!(
                "@group(0) @binding({binding}) var out_tex{ks}: texture_storage_2d<{format}, write>;\n\
                 fn gpufx_write{ks}(id: vec3u, c: vec4f) {{ textureStore(out_tex{ks}, vec2i(id.xy), clamp(c, vec4f(0.0), vec4f(1.0))); }}\n"
            ));
            continue;
        }
        let suf = plane.suffix();
        let (ty, texel) = if *plane == Plane::Uv { ("vec2f", "vec4f(v, 0.0, 1.0)") } else { ("f32", "vec4f(v, 0.0, 0.0, 1.0)") };
        s.push_str(&format!(
            "@group(0) @binding({binding}) var out_tex{ks}_{suf}: texture_storage_2d<{format}, write>;\n\
             fn gpufx_write{ks}_{suf}(p: vec2u, v: {ty}) {{ textureStore(out_tex{ks}_{suf}, vec2i(p), clamp({texel}, vec4f(0.0), vec4f(1.0))); }}\n"
        ));
        if *plane == Plane::Uv {
            let (sx, sy) = planes.outputs[*k].chroma_scale();
            s.push_str(&format!("fn gpufx_chroma_scale{ks}() -> vec2u {{ return vec2u({sx}u, {sy}u); }}\n"));
        }
    }
    if let Some((first, count)) = copies {
        // As in `prelude`; only the `rgba` outputs have a `gpufx_write{k}` (a repeated output is `rgba`).
        s.push_str(&format!(
            "fn gpufx_output_count() -> u32 {{ return {}u; }}\nfn gpufx_write_at(i: u32, id: vec3u, c: vec4f) {{\n    switch i {{\n",
            planes.outputs.len()
        ));
        for (k, _) in planes.outputs.iter().enumerate().filter(|(_, l)| **l == PixelLayout::Rgba) {
            let ks = if k == 0 { String::new() } else { k.to_string() };
            s.push_str(&format!("        case {k}u: {{ gpufx_write{ks}(id, c); }}\n"));
        }
        s.push_str("        default: {}\n    }\n}\n");
        s.push_str(&format!(
            "fn gpufx_copy_count() -> u32 {{ return {count}u; }}\n\
             fn gpufx_write_copy(j: u32, id: vec3u, c: vec4f) {{ if (j < {count}u) {{ gpufx_write_at({first}u + j, id, c); }} }}\n"
        ));
    }
    s.push_str(
        "fn gpufx_in_bounds(id: vec3u) -> bool { return f32(id.x) < globals.size.x && f32(id.y) < globals.size.y; }\n\
         fn gpufx_uv(id: vec3u) -> vec2f { return (vec2f(id.xy) + 0.5) / globals.size; }\n\
         // ---- end of gpufx prelude ----\n",
    );
    s
}

/// Inserts the GLSL prelude after the author's `#version` line (adding `#version 450`
/// when there is none), so their line numbers stay readable in errors.
fn glsl_with_prelude(
    params: &ParamBlock,
    inputs: &[String],
    pkg: &Package,
    def: &PassDef,
    user: &str,
    deep: bool,
    size_entry: bool,
) -> String {
    let extra_outputs = def.outputs.len() - 1;
    let (version, body) = match user.trim_start().strip_prefix("#version") {
        Some(rest) => {
            let rest_at = user.len() - rest.len();
            let eol = user[rest_at..].find('\n').map_or(user.len(), |i| rest_at + i + 1);
            (&user[..eol], &user[eol..])
        }
        None => ("#version 450\n", user),
    };
    let arrays: Vec<bool> = inputs.iter().map(|n| pkg.manifest.textures.iter().any(|t| t.name == *n && t.is_array())).collect();
    let effect_inputs: Vec<&str> = pkg.manifest.inputs.iter().map(|i| i.name.as_str()).collect();
    let mut s = String::from(version);
    s.push_str(&format!(
        "// ---- generated by gpufx ----\n\
         layout(set = 0, binding = 0) uniform GpufxGlobals {{ vec2 size; float time; uint frame; \
         int time_int; float time_frac; float pixel_aspect; float gpufx_reserved; }} globals;\n\
         layout(set = 0, binding = 1) uniform GpufxParams {{\n{}}} params;\n\
         layout(set = 0, binding = 2, {}) uniform writeonly image2D out_tex;\n\
         layout(set = 0, binding = 3) uniform sampler smp;\n",
        params.glsl_members(),
        if deep { "rgba16f" } else { "rgba8" }
    ));
    s.push_str(&params.expr_functions(true));
    for (i, name) in inputs.iter().enumerate() {
        let ty = if arrays[i] { "texture2DArray" } else { "texture2D" };
        s.push_str(&format!("layout(set = 0, binding = {}) uniform {ty} {name};\n", FIRST_TEXTURE_BINDING + i as u32));
    }
    let format = if deep { "rgba16f" } else { "rgba8" };
    for k in 1..=extra_outputs {
        s.push_str(&format!(
            "layout(set = 0, binding = {}, {format}) uniform writeonly image2D out_tex{k};\n\
             void gpufx_write{k}(uvec3 id, vec4 c) {{ imageStore(out_tex{k}, ivec2(id.xy), clamp(c, vec4(0.0), vec4(1.0))); }}\n",
            extra_output_binding(inputs.len(), k)
        ));
    }
    s.push_str(&output_enabled(pkg, def, true));
    s.push_str(
        "bool gpufx_in_bounds(uvec3 id) { return float(id.x) < globals.size.x && float(id.y) < globals.size.y; }\n\
         vec2 gpufx_uv(uvec3 id) { return (vec2(id.xy) + 0.5) / globals.size; }\n\
         void gpufx_write(uvec3 id, vec4 c) { imageStore(out_tex, ivec2(id.xy), clamp(c, vec4(0.0), vec4(1.0))); }\n\
         // ---- end of gpufx prelude ----\n",
    );
    if size_entry {
        // The size pipeline: the input sizes come in a buffer, and its `main` calls
        // `gpufx_output_size` (the author's `main` is renamed out of the way).
        s.push_str(&format!(
            "layout(set = 0, binding = {SIZE_BINDING}, std430) buffer GpufxSizeIo {{ uvec2 gpufx_size_io[]; }};\n\
             uint gpufx_input_count() {{ return gpufx_size_io[0].x; }}\n\
             uvec2 gpufx_input_size(uint i) {{ if (i < gpufx_size_io[0].x) {{ return gpufx_size_io[1u + i]; }} return uvec2(0u); }}\n\
             #define main gpufx_author_main\n"
        ));
        s.push_str(body);
        s.push_str("\n#undef main\nvoid main() { gpufx_size_io[0] = gpufx_output_size(gpufx_size_io[0].y); }\n");
        return s;
    }
    // Indices are those of the effect inputs (package textures not counted); an input
    // the pass does not bind reads 0x0 here.
    s.push_str(&format!("uint gpufx_input_count() {{ return {}u; }}\nuvec2 gpufx_input_size(uint i) {{\n", effect_inputs.len()));
    for (k, n) in effect_inputs.iter().enumerate() {
        if inputs.iter().any(|b| b == n) {
            s.push_str(&format!("    if (i == {k}u) {{ return uvec2(textureSize(sampler2D({n}, smp), 0)); }}\n"));
        }
    }
    s.push_str("    return uvec2(0u);\n}\n");
    s.push_str(body);
    s
}

/// WGSL helpers over the effect inputs (in manifest order, package textures not counted):
/// `gpufx_input_count()` and `gpufx_input_size(i)`, and for a package with a repeated input
/// `gpufx_input_load(i, p)` (level 0 texel), so a shader loops over however many there are.
/// An input the pass does not bind reads 0 (its size too, except in the size pipeline,
/// which is given every input size).
fn input_helpers(pkg: &Package, bound: &[String], sizes_from_buffer: bool) -> String {
    let names: Vec<&str> = pkg.manifest.inputs.iter().map(|i| i.name.as_str()).collect();
    let is_bound = |n: &str| bound.iter().any(|b| b == n);
    let mut s = String::from("// ---- gpufx input helpers ----\n");
    if sizes_from_buffer {
        s.push_str(&format!(
            "@group(0) @binding({SIZE_BINDING}) var<storage, read_write> gpufx_size_io: array<vec2u>;\n\
             fn gpufx_input_count() -> u32 {{ return gpufx_size_io[0].x; }}\n\
             fn gpufx_input_size(i: u32) -> vec2u {{ if (i < gpufx_size_io[0].x) {{ return gpufx_size_io[1u + i]; }} return vec2u(0u); }}\n"
        ));
    } else {
        s.push_str(&format!("fn gpufx_input_count() -> u32 {{ return {}u; }}\n", names.len()));
        s.push_str("fn gpufx_input_size(i: u32) -> vec2u {\n    switch i {\n");
        for (k, n) in names.iter().enumerate().filter(|(_, n)| is_bound(n)) {
            // An input with planes has the size of its Y plane.
            let tex = if pkg.manifest.layout_of(n) == PixelLayout::Rgba { n.to_string() } else { format!("in_{n}_y") };
            s.push_str(&format!("        case {k}u: {{ return textureDimensions({tex}); }}\n"));
        }
        s.push_str("        default: { return vec2u(0u); }\n    }\n}\n");
    }
    if pkg.has_repeated_input() {
        s.push_str("fn gpufx_input_load(i: u32, p: vec2i) -> vec4f {\n    switch i {\n");
        for (k, n) in names.iter().enumerate().filter(|(_, n)| is_bound(n)) {
            s.push_str(&format!("        case {k}u: {{ return textureLoad({n}, p, 0); }}\n"));
        }
        s.push_str("        default: { return vec4f(0.0); }\n    }\n}\n");
    }
    s
}

fn compile_pass(ctx: &GpuContext, pkg: &Package, params: &ParamBlock, index: usize, def: &PassDef, deep: bool) -> Result<Pass, Error> {
    let inputs: Vec<String> = match &def.inputs {
        Some(v) => v.clone(),
        None => pkg.manifest.inputs.iter().map(|i| i.name.clone()).chain(pkg.manifest.textures.iter().map(|t| t.name.clone())).collect(),
    };
    let arrays: Vec<bool> = inputs.iter().map(|n| pkg.manifest.textures.iter().any(|t| t.name == *n && t.is_array())).collect();
    let extra = def.outputs.len() - 1;
    let planes = PassPlanes::of(ctx, pkg, &inputs, def);
    let (module, source) = match def.language() {
        ShaderLanguage::Wgsl => {
            let user = pkg.text(&def.shader)?;
            let source = format!(
                "{}{}",
                prelude(params, &inputs, &arrays, extra, pass_copies(pkg, def), deep, planes.as_ref())
                    + &output_enabled(pkg, def, false)
                    + &input_helpers(pkg, &inputs, false),
                user
            );
            let module = naga::front::wgsl::parse_str(&source)
                .map_err(|e| Error::Shader(format!("{}: {}", def.shader, e.emit_to_string(&source))))?;
            (module, source)
        }
        ShaderLanguage::Glsl => {
            let source = glsl_with_prelude(params, &inputs, pkg, def, pkg.text(&def.shader)?, deep, false);
            let module = naga::front::glsl::Frontend::default()
                .parse(&naga::front::glsl::Options::from(naga::ShaderStage::Compute), &source)
                .map_err(|e| Error::Shader(format!("{}: {}", def.shader, e.emit_to_string(&source))))?;
            (module, source)
        }
    };
    let entry = match def.language() {
        ShaderLanguage::Wgsl => def.entry.as_str(),
        ShaderLanguage::Glsl => "main",
    };

    // Validate here: wgpu would otherwise only report shader errors through the device
    // error callback, which cannot be returned to the caller.
    naga::valid::Validator::new(naga::valid::ValidationFlags::all(), naga::valid::Capabilities::empty())
        .validate(&module)
        .map_err(|e| Error::Shader(format!("{}: {}", def.shader, e.emit_to_string(&source))))?;
    if !module.entry_points.iter().any(|ep| ep.name == entry && ep.stage == naga::ShaderStage::Compute) {
        return Err(Error::Shader(format!("{}: no compute entry point `{entry}`", def.shader)));
    }
    let sizes_output = module.functions.iter().any(|(_, f)| f.name.as_deref() == Some("gpufx_output_size"));

    let device = &ctx.device;
    // The bound textures, in binding order: (key, input index, plane), (key, plane).
    let (textures, storage) = match &planes {
        Some(p) => (p.textures(&inputs), p.storage(&def.outputs).into_iter().map(|(k, _, p)| (k, p)).collect()),
        None => (
            inputs.iter().enumerate().map(|(i, n)| (n.clone(), i, Plane::Rgba)).collect::<Vec<_>>(),
            def.outputs.iter().map(|n| (n.clone(), Plane::Rgba)).collect::<Vec<_>>(),
        ),
    };
    let f16 = planes.as_ref().is_some_and(|p| p.f16);
    let storage_entry = |binding: u32, plane: Plane| wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::StorageTexture {
            access: wgpu::StorageTextureAccess::WriteOnly,
            format: plane_format(plane, deep, f16),
            view_dimension: wgpu::TextureViewDimension::D2,
        },
        count: None,
    };

    let mut entries = vec![
        uniform_entry(0),
        uniform_entry(1),
        storage_entry(2, storage[0].1),
        wgpu::BindGroupLayoutEntry {
            binding: 3,
            visibility: wgpu::ShaderStages::COMPUTE,
            ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
            count: None,
        },
    ];
    for (b, (_, i, plane)) in textures.iter().enumerate() {
        entries.push(wgpu::BindGroupLayoutEntry {
            binding: FIRST_TEXTURE_BINDING + b as u32,
            visibility: wgpu::ShaderStages::COMPUTE,
            ty: wgpu::BindingType::Texture {
                // 32-bit float planes cannot be filtered (no FLOAT32_FILTERABLE): textureLoad only.
                sample_type: wgpu::TextureSampleType::Float { filterable: *plane == Plane::Rgba || f16 },
                view_dimension: if arrays[*i] { wgpu::TextureViewDimension::D2Array } else { wgpu::TextureViewDimension::D2 },
                multisampled: false,
            },
            count: None,
        });
    }
    for (j, (_, plane)) in storage.iter().enumerate().skip(1) {
        entries.push(storage_entry(extra_output_binding(textures.len(), j), *plane));
    }
    let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("gpufx pass"), entries: &entries });
    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("gpufx pass"),
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let language = match def.language() {
        ShaderLanguage::Wgsl => "wgsl",
        ShaderLanguage::Glsl => "glsl",
    };
    let format = if deep { "rgba16float" } else { "rgba8unorm" };
    let pipeline = ShaderCache::compute_pipeline(
        ctx.shader_cache.as_deref(),
        device,
        &PipelineDesc { label: &format!("gpufx pass {index} ({})", def.shader), layout: &pipeline_layout, entries: &entries, entry },
        module,
        &[language, entry, format, &source],
        Some(pkg),
    );
    let input_keys = textures.into_iter().map(|(k, _, _)| k).collect();
    let output_keys = storage.into_iter().map(|(k, _)| k).collect();
    Ok(Pass {
        pipeline,
        layout,
        inputs,
        outputs: def.outputs.clone(),
        input_keys,
        output_keys,
        size_of: pkg.manifest.pass_size(def),
        sizes_output,
    })
}

/// The size pipeline of pass `def`: its shader with an entry point calling
/// `gpufx_output_size`, which may read `params` and the input sizes only.
fn compile_size_pass(ctx: &GpuContext, pkg: &Package, params: &ParamBlock, index: usize, def: &PassDef) -> Result<SizePass, Error> {
    let inputs: Vec<String> = match &def.inputs {
        Some(v) => v.clone(),
        None => pkg.manifest.inputs.iter().map(|i| i.name.clone()).chain(pkg.manifest.textures.iter().map(|t| t.name.clone())).collect(),
    };
    let arrays: Vec<bool> = inputs.iter().map(|n| pkg.manifest.textures.iter().any(|t| t.name == *n && t.is_array())).collect();
    let extra = def.outputs.len() - 1;
    let planes = PassPlanes::of(ctx, pkg, &inputs, def);
    let user = pkg.text(&def.shader)?;
    let shader_err = |e: String| Error::Shader(format!("{} (gpufx_output_size): {e}", def.shader));
    let (module, source, entry) = match def.language() {
        ShaderLanguage::Wgsl => {
            let source = format!(
                "{}{}\n@compute @workgroup_size(1) fn gpufx_size_main() {{ gpufx_size_io[0] = gpufx_output_size(gpufx_size_io[0].y); }}\n",
                prelude(params, &inputs, &arrays, extra, pass_copies(pkg, def), false, planes.as_ref())
                    + &output_enabled(pkg, def, false)
                    + &input_helpers(pkg, &inputs, true),
                user
            );
            let module = naga::front::wgsl::parse_str(&source).map_err(|e| shader_err(e.emit_to_string(&source)))?;
            (module, source, "gpufx_size_main")
        }
        ShaderLanguage::Glsl => {
            let source = glsl_with_prelude(params, &inputs, pkg, def, user, false, true);
            let module = naga::front::glsl::Frontend::default()
                .parse(&naga::front::glsl::Options::from(naga::ShaderStage::Compute), &source)
                .map_err(|e| shader_err(e.emit_to_string(&source)))?;
            (module, source, "main")
        }
    };
    let info = naga::valid::Validator::new(naga::valid::ValidationFlags::all(), naga::valid::Capabilities::empty())
        .validate(&module)
        .map_err(|e| shader_err(e.emit_to_string(&source)))?;
    let Some(ep) = module.entry_points.iter().position(|ep| ep.name == entry) else {
        return Err(shader_err("no size entry point".into()));
    };
    // Only `params` and the input sizes exist when the size is asked for.
    let reads = params_read(&module, ep);
    let uses = info.get_entry_point(ep);
    for (h, var) in module.global_variables.iter() {
        // Globals without a binding (GLSL built-ins, private variables) need no bind group.
        let allowed = var.binding.as_ref().is_none_or(|b| b.binding == 1 || b.binding == SIZE_BINDING);
        if !uses[h].is_empty() && !allowed {
            return Err(shader_err(format!(
                "gpufx_output_size may read only `params`, gpufx_input_count() and gpufx_input_size(), not `{}`",
                var.name.as_deref().unwrap_or("?")
            )));
        }
    }
    let device = &ctx.device;
    let entries = [
        uniform_entry(1),
        wgpu::BindGroupLayoutEntry {
            binding: SIZE_BINDING,
            visibility: wgpu::ShaderStages::COMPUTE,
            ty: wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Storage { read_only: false },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        },
    ];
    let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("gpufx size"), entries: &entries });
    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("gpufx size"),
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let language = match def.language() {
        ShaderLanguage::Wgsl => "wgsl",
        ShaderLanguage::Glsl => "glsl",
    };
    let pipeline = ShaderCache::compute_pipeline(
        ctx.shader_cache.as_deref(),
        device,
        &PipelineDesc { label: &format!("gpufx size {index} ({})", def.shader), layout: &pipeline_layout, entries: &entries, entry },
        module,
        &[language, entry, "size", &source],
        Some(pkg),
    );
    Ok(SizePass { pipeline, layout, reads })
}

/// Names of the `params` fields that entry point `ep`, and the functions it calls, read.
/// A read of the whole block counts as reading every field.
fn params_read(module: &naga::Module, ep: usize) -> Vec<String> {
    let found = module.global_variables.iter().find(|(_, v)| v.binding.as_ref().is_some_and(|b| b.group == 0 && b.binding == 1));
    let Some((block, var)) = found else { return Vec::new() };
    let members: Vec<String> = match &module.types[var.ty].inner {
        naga::TypeInner::Struct { members, .. } => members.iter().map(|m| m.name.clone().unwrap_or_default()).collect(),
        _ => Vec::new(),
    };
    let mut read = vec![false; members.len()];
    let mut todo = vec![&module.entry_points[ep].function];
    let mut seen = std::collections::HashSet::new();
    while let Some(f) = todo.pop() {
        let mut calls = Vec::new();
        called(&f.body, &mut calls);
        for h in calls {
            if seen.insert(h) {
                todo.push(&module.functions[h]);
            }
        }
        let refs: Vec<_> =
            f.expressions.iter().filter(|(_, e)| matches!(e, naga::Expression::GlobalVariable(g) if *g == block)).map(|(h, _)| h).collect();
        for (_, e) in f.expressions.iter() {
            match *e {
                naga::Expression::AccessIndex { base, index } if refs.contains(&base) => {
                    if let Some(r) = read.get_mut(index as usize) {
                        *r = true;
                    }
                }
                naga::Expression::Load { pointer: base } | naga::Expression::Access { base, .. } if refs.contains(&base) => {
                    read.iter_mut().for_each(|r| *r = true);
                }
                _ => {}
            }
        }
    }
    members.into_iter().zip(read).filter(|(n, r)| *r && n != "_unused").map(|(n, _)| n).collect()
}

/// Functions called in `block`, nested blocks included.
fn called(block: &naga::Block, out: &mut Vec<naga::Handle<naga::Function>>) {
    for st in block.iter() {
        match st {
            naga::Statement::Call { function, .. } => out.push(*function),
            naga::Statement::Block(b) => called(b, out),
            naga::Statement::If { accept, reject, .. } => {
                called(accept, out);
                called(reject, out);
            }
            naga::Statement::Switch { cases, .. } => cases.iter().for_each(|c| called(&c.body, out)),
            naga::Statement::Loop { body, continuing, .. } => {
                called(body, out);
                called(continuing, out);
            }
            _ => {}
        }
    }
}

fn uniform_entry(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None },
        count: None,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Arc;

    use super::{device_limits, plane_format, prelude, Backend, Effect, FrameInfo, GpuContext, PassPlanes};
    use crate::manifest::{PixelLayout, Plane};
    use crate::package::Package;
    use crate::params::ParamBlock;

    #[test]
    fn only_a_pass_writing_a_repeated_output_gets_the_indexed_write_helpers() {
        let params = ParamBlock::new(&[]).unwrap();
        let inputs = ["src".to_string()];
        // Any other pass: its prelude, and so its shader cache key, is as before the helpers.
        let plain = prelude(&params, &inputs, &[false], 1, None, false, None);
        assert!(!plain.contains("gpufx_output_count") && !plain.contains("gpufx_write_at") && !plain.contains("gpufx_copy_count"));
        // A pass `["mask", "part"]` with two copies: copy j is pass output 1 + j.
        let copies = prelude(&params, &inputs, &[false], 2, Some((1, 2)), false, None);
        assert!(copies.contains("fn gpufx_output_count() -> u32 { return 3u; }"), "{copies}");
        assert!(copies.contains("fn gpufx_copy_count() -> u32 { return 2u; }"), "{copies}");
        assert!(copies.contains("if (j < 2u) { gpufx_write_at(1u + j, id, c); }"), "{copies}");
    }

    fn planes(inputs: &[PixelLayout], outputs: &[PixelLayout], f16: bool) -> PassPlanes {
        PassPlanes { inputs: inputs.to_vec(), outputs: outputs.to_vec(), f16 }
    }

    #[test]
    fn a_pass_with_planes_binds_each_plane_and_gets_plane_write_helpers() {
        let params = ParamBlock::new(&[]).unwrap();
        let inputs = ["src".to_string(), "bg".to_string()];
        let p = planes(&[PixelLayout::Yuv420, PixelLayout::Rgba], &[PixelLayout::Yuva420, PixelLayout::Y], false);
        let s = prelude(&params, &inputs, &[false, false], 1, None, false, Some(&p));
        // Sampled: Y and UV of `src`, then `bg` as is.
        assert!(s.contains("@group(0) @binding(4) var in_src_y: texture_2d<f32>;"), "{s}");
        assert!(s.contains("@group(0) @binding(5) var in_src_uv: texture_2d<f32>;"), "{s}");
        assert!(s.contains("@group(0) @binding(6) var bg: texture_2d<f32>;"), "{s}");
        // Storage: Y of output 0 at 2, the other planes after the 3 sampled textures.
        assert!(s.contains("@group(0) @binding(2) var out_tex_y: texture_storage_2d<r32float, write>;"), "{s}");
        assert!(s.contains("@group(0) @binding(7) var out_tex_uv: texture_storage_2d<rg32float, write>;"), "{s}");
        assert!(s.contains("@group(0) @binding(8) var out_tex_a: texture_storage_2d<r32float, write>;"), "{s}");
        assert!(s.contains("@group(0) @binding(9) var out_tex1_y: texture_storage_2d<r32float, write>;"), "{s}");
        assert!(s.contains("fn gpufx_write_uv(p: vec2u, v: vec2f)"), "{s}");
        assert!(s.contains("fn gpufx_write1_y(p: vec2u, v: f32)"), "{s}");
        assert!(s.contains("fn gpufx_chroma_scale() -> vec2u { return vec2u(2u, 2u); }"), "{s}");
        // No `out_tex` / `gpufx_write`: output 0 is planar.
        assert!(!s.contains("var out_tex:") && !s.contains("fn gpufx_write("), "{s}");
        let s16 =
            prelude(&params, &inputs, &[false, false], 1, None, false, Some(&planes(&[PixelLayout::Yuv422], &[PixelLayout::Yuv422], true)));
        assert!(s16.contains("texture_storage_2d<r16float, write>") && s16.contains("texture_storage_2d<rg16float, write>"), "{s16}");
        assert!(s16.contains("return vec2u(2u, 1u);"), "{s16}");
        // A pass without planes keeps the prelude it had (and so its shader cache key).
        let plain = prelude(&params, &inputs, &[false, false], 0, None, false, None);
        assert!(!plain.contains("planes") && plain.contains("var out_tex: texture_storage_2d<rgba8unorm, write>;"));
    }

    fn f16_bits(v: f32) -> u16 {
        if v == 0.0 {
            return 0;
        }
        let b = v.to_bits();
        ((((b >> 23) & 0xff) as i32 - 127 + 15) as u16) << 10 | ((b >> 13) & 0x3ff) as u16
    }

    fn f16_value(h: u16) -> f32 {
        if h & 0x7fff == 0 {
            return 0.0;
        }
        f32::from_bits((((h >> 10) & 0x1f) as u32 + 127 - 15) << 23 | ((h & 0x3ff) as u32) << 13)
    }

    /// A 5x3 `yuv420` effect (UV 3x2, rounded up) inverting Y and swapping U and V, fed and
    /// read plane by plane, with 32-bit planes and, where the adapter has them, 16-bit ones.
    #[test]
    fn a_yuv420_effect_reads_and_writes_its_planes() {
        let Ok(mut ctx) = GpuContext::new(Backend::Auto) else { return };
        let modes: Vec<bool> = if ctx.plane_f16 { vec![false, true] } else { vec![false] };
        let manifest = br#"{"id":"t.yuv","name":"Yuv","used_for":["gpufx"],
            "inputs":[{"name":"src","pixel_layout":"yuv420"}],
            "outputs":[{"name":"out","pixel_layout":"yuv420"}],
            "groups":[{"passes":[{"shader":"a.wgsl"}]}]}"#;
        let shader = b"@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) {
            if (!gpufx_in_bounds(id)) { return; }
            let p = id.xy;
            gpufx_write_y(p, 1.0 - textureLoad(in_src_y, p, 0).r);
            let s = gpufx_chroma_scale();
            if (all(p % s == vec2u(0u))) { gpufx_write_uv(p / s, textureLoad(in_src_uv, p / s, 0).gr); }
        }";
        let files = HashMap::from([("manifest.json".to_string(), manifest.to_vec()), ("a.wgsl".to_string(), shader.to_vec())]);
        let layout = PixelLayout::Yuv420;
        let (w, h) = (5, 3);
        let quarters = [0.0f32, 0.25, 0.5, 0.75, 1.0];
        let y: Vec<f32> = (0..w * h).map(|i| quarters[i as usize % 5]).collect();
        let (cw, ch) = layout.plane_size(Plane::Uv, (w, h));
        assert_eq!((cw, ch), (3, 2));
        let uv: Vec<f32> = (0..cw * ch * 2).map(|i| quarters[(i as usize * 3) % 5]).collect();
        for f16 in modes {
            Arc::get_mut(&mut ctx).expect("only owner").plane_f16 = f16;
            let pkg = Package::from_files(files.clone()).unwrap();
            let mut fx = Effect::new(ctx.clone(), pkg).unwrap();
            let device = &ctx.device;
            let tex = |plane: Plane, size: (u32, u32), usage: wgpu::TextureUsages| {
                device.create_texture(&wgpu::TextureDescriptor {
                    label: None,
                    size: wgpu::Extent3d { width: size.0, height: size.1, depth_or_array_layers: 1 },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: plane_format(plane, false, f16),
                    usage,
                    view_formats: &[],
                })
            };
            let encode = |v: &[f32]| -> Vec<u8> {
                if f16 {
                    v.iter().flat_map(|&x| f16_bits(x).to_le_bytes()).collect()
                } else {
                    v.iter().flat_map(|&x| x.to_le_bytes()).collect()
                }
            };
            let texel = if f16 { 2 } else { 4 };
            let upload = |t: &wgpu::Texture, v: &[f32], channels: u32| {
                ctx.queue.write_texture(
                    t.as_image_copy(),
                    &encode(v),
                    wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(t.width() * channels * texel), rows_per_image: None },
                    t.size(),
                );
            };
            let read = wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST;
            let write = wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC;
            let (in_y, in_uv) = (tex(Plane::Y, (w, h), read), tex(Plane::Uv, (cw, ch), read));
            upload(&in_y, &y, 1);
            upload(&in_uv, &uv, 2);
            let (out_y, out_uv) = (tex(Plane::Y, (w, h), write), tex(Plane::Uv, (cw, ch), write));
            let outputs = HashMap::from([("out.y".to_string(), out_y.clone()), ("out.uv".to_string(), out_uv.clone())]);
            fx.bind(&[&in_y, &in_uv], outputs, &[(w, h)], false).unwrap();
            let mut enc = device.create_command_encoder(&Default::default());
            {
                let mut cpass = enc.begin_compute_pass(&Default::default());
                fx.encode(&mut cpass, &FrameInfo::new(0.0, 0));
            }
            let readback = |enc: &mut wgpu::CommandEncoder, t: &wgpu::Texture, channels: u32| {
                let row = (t.width() * channels * texel).next_multiple_of(256);
                let buf = device.create_buffer(&wgpu::BufferDescriptor {
                    label: None,
                    size: (row * t.height()) as u64,
                    usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                    mapped_at_creation: false,
                });
                enc.copy_texture_to_buffer(
                    t.as_image_copy(),
                    wgpu::TexelCopyBufferInfo {
                        buffer: &buf,
                        layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(row), rows_per_image: None },
                    },
                    t.size(),
                );
                (buf, row)
            };
            let (buf_y, row_y) = readback(&mut enc, &out_y, 1);
            let (buf_uv, row_uv) = readback(&mut enc, &out_uv, 2);
            ctx.queue.submit([enc.finish()]);
            let values = |buf: &wgpu::Buffer, row: u32, t: &wgpu::Texture, channels: u32| -> Vec<f32> {
                buf.slice(..).map_async(wgpu::MapMode::Read, |r| r.unwrap());
                device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
                let data = buf.slice(..).get_mapped_range().unwrap();
                let n = (t.width() * channels) as usize;
                (0..t.height() as usize)
                    .flat_map(|r| {
                        let line = &data[r * row as usize..];
                        (0..n)
                            .map(|i| {
                                if f16 {
                                    f16_value(u16::from_le_bytes([line[i * 2], line[i * 2 + 1]]))
                                } else {
                                    f32::from_le_bytes(line[i * 4..i * 4 + 4].try_into().unwrap())
                                }
                            })
                            .collect::<Vec<_>>()
                    })
                    .collect()
            };
            let got_y = values(&buf_y, row_y, &out_y, 1);
            let got_uv = values(&buf_uv, row_uv, &out_uv, 2);
            assert_eq!(got_y, y.iter().map(|v| 1.0 - v).collect::<Vec<_>>(), "Y, f16 {f16}");
            let swapped: Vec<f32> = uv.chunks(2).flat_map(|c| [c[1], c[0]]).collect();
            assert_eq!(got_uv, swapped, "UV, f16 {f16}");
        }
    }

    #[test]
    fn device_limits_keep_max_buffer_size_within_u32() {
        // A raw Vulkan adapter on NVIDIA reports maxBufferSize above 4 GiB; wgpu-core panics on it.
        let huge = wgpu::Limits { max_buffer_size: 1 << 40, max_storage_buffer_binding_size: 1 << 40, ..Default::default() };
        let limits = device_limits(&huge);
        assert_eq!(limits.max_buffer_size, u32::MAX as u64);
        assert_eq!(limits.max_storage_buffer_binding_size, u32::MAX as u64);

        let small = wgpu::Limits { max_buffer_size: 256 << 20, ..Default::default() };
        assert_eq!(device_limits(&small).max_buffer_size, 256 << 20);
    }
}
