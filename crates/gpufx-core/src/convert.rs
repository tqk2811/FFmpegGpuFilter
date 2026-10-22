//! Built-in GPU passes that convert frames between their pixel format and the RGBA
//! textures effects work on, so YUV never goes through the CPU.
//!
//! Input planes are uploaded as integer textures (`r8uint`, `rg16uint`, ...: core WebGPU
//! formats every backend has, unlike `r16unorm`) and turned into an RGBA texture with
//! straight alpha, which the first effect reads. Straight 8-bit RGBA skips the pass and
//! is read as `rgba8unorm`. The RGBA textures are `rgba16float` only when a frame of the
//! chain has more than 8 bits, else `rgba8unorm` (half the memory).
//! On output a pass encodes each plane into a storage buffer of packed words, which is
//! copied into a mappable buffer and from there into the caller's planes.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use crate::frame::{ColorInfo, FrameMut, Layout, PixelFormat, PlaneKind};
use crate::lru::Lru;
use crate::manifest::{PixelLayout, Plane};
use crate::pool::PoolKey;
use crate::shader_cache::{PipelineDesc, ShaderCache};
use crate::Error;

/// RGBA texture format that keeps the precision of `format`: `rgba16float` (about 11
/// bits) above 8 bits. A chain works in the deepest format of its frames.
pub(crate) fn work_format(format: PixelFormat) -> wgpu::TextureFormat {
    deep_format(format.layout().depth > 8)
}

fn deep_format(deep: bool) -> wgpu::TextureFormat {
    if deep {
        wgpu::TextureFormat::Rgba16Float
    } else {
        wgpu::TextureFormat::Rgba8Unorm
    }
}
const WORKGROUP: u32 = 8;
/// Pixels per side of a workgroup of the input pass of GPU frames (convert_in_tiled.wgsl).
const TILED_GROUP: u32 = 16;

/// Pixels per side of a workgroup of the input pass. `gpu` also picks the shader
/// (`to_rgba(gpu, _)` compiles convert_in_tiled.wgsl for GPU frames only), so the two
/// always agree.
fn in_group(gpu: bool) -> u32 {
    if gpu {
        TILED_GROUP
    } else {
        WORKGROUP
    }
}
/// Size of the `Conv` uniform struct of convert.wgsl.
const UNIFORM_SIZE: u64 = 112;

/// Pipelines of the conversion passes, compiled once per device. Those for frames
/// already on the GPU are compiled the first time such a frame comes.
pub(crate) struct Converter {
    device: wgpu::Device,
    /// The on-disk shader cache of the context, if any.
    cache: Option<Arc<ShaderCache>>,
    /// Integer planes uploaded from the CPU, writing `rgba8unorm` and `rgba16float`.
    to_rgba: [(wgpu::ComputePipeline, wgpu::BindGroupLayout); 2],
    /// Unorm planes of GPU frames, writing `rgba8unorm` and `rgba16float`.
    to_rgba_gpu: OnceLock<[(wgpu::ComputePipeline, wgpu::BindGroupLayout); 2]>,
    from_rgba: wgpu::ComputePipeline,
    from_rgba_layout: wgpu::BindGroupLayout,
    /// Writing the planes of GPU frames, one per plane texture format.
    to_planes: [OnceLock<(wgpu::ComputePipeline, wgpu::BindGroupLayout)>; PLANE_FORMATS.len()],
    /// Writing every plane of a YUV GPU frame in one pass, per [`PixelFormat`].
    to_yuv: [OnceLock<(wgpu::ComputePipeline, wgpu::BindGroupLayout)>; PIXEL_FORMATS],
    /// Bound in place of the planes a format does not have.
    dummy: wgpu::TextureView,
    dummy_gpu: OnceLock<wgpu::TextureView>,
    /// Passes between the `pixel_layout`s of effects (see [`LayoutConvert`]), compiled the
    /// first time a graph needs one.
    layouts: Mutex<HashMap<LayoutPass, (wgpu::ComputePipeline, wgpu::BindGroupLayout)>>,
    /// Frame planes loaded straight into plane textures, per (format, GPU frame, 16-bit
    /// planes), and plane textures written straight into one frame plane, per (layout, the
    /// storage format of a GPU frame plane or none for the readback buffer).
    planes_in: Mutex<HashMap<(PixelFormat, bool, bool), Pass>>,
    planes_out: Mutex<HashMap<(PixelLayout, Option<wgpu::TextureFormat>), Pass>>,
}

/// A compiled pass and the layout of its bind group.
type Pass = (wgpu::ComputePipeline, wgpu::BindGroupLayout);

/// Plane texture formats of GPU frames, with their WGSL storage format names.
const PLANE_FORMATS: [(wgpu::TextureFormat, &str); 6] = [
    (wgpu::TextureFormat::R8Unorm, "r8unorm"),
    (wgpu::TextureFormat::Rg8Unorm, "rg8unorm"),
    (wgpu::TextureFormat::Rgba8Unorm, "rgba8unorm"),
    (wgpu::TextureFormat::R16Unorm, "r16unorm"),
    (wgpu::TextureFormat::Rg16Unorm, "rg16unorm"),
    (wgpu::TextureFormat::Rgba16Unorm, "rgba16unorm"),
];

fn entry(binding: u32, ty: wgpu::BindingType) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry { binding, visibility: wgpu::ShaderStages::COMPUTE, ty, count: None }
}

const UNIFORM: wgpu::BindingType =
    wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None };

fn texture(sample_type: wgpu::TextureSampleType) -> wgpu::BindingType {
    wgpu::BindingType::Texture { sample_type, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false }
}

fn pipeline(
    device: &wgpu::Device,
    cache: Option<&ShaderCache>,
    label: &str,
    body: &str,
    entries: &[wgpu::BindGroupLayoutEntry],
) -> (wgpu::ComputePipeline, wgpu::BindGroupLayout) {
    let source = format!("{}{body}", include_str!("convert.wgsl"));
    let module = naga::front::wgsl::parse_str(&source).unwrap_or_else(|e| panic!("{label}: {}", e.emit_to_string(&source)));
    let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some(label), entries });
    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some(label),
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let pipeline = ShaderCache::compute_pipeline(
        cache,
        device,
        &PipelineDesc { label, layout: &pipeline_layout, entries, entry: "main" },
        module,
        &["convert", "main", &source],
        None,
    );
    (pipeline, layout)
}

/// convert_in.wgsl with its plane bindings: integer textures (CPU uploads) or unorm
/// textures (GPU frames), read back as the stored sample codes.
fn convert_in_source(deep: bool, unorm: bool) -> String {
    let mut s = plane_loads(unorm);
    let wgsl = if deep { "rgba16float" } else { "rgba8unorm" };
    s.push_str(&include_str!("convert_in.wgsl").replace("rgba16float", wgsl));
    // GPU frames: 16x16 pixels per workgroup sharing their chroma samples (see
    // [`in_group`]). Uploads keep the plain pass.
    s.push_str(if unorm { include_str!("convert_in_tiled.wgsl") } else { include_str!("convert_in_plain.wgsl") });
    s
}

/// The frame plane bindings plane0..plane3 (bindings 2..5) and load0..load3, returning the
/// stored sample codes of a texel: integer textures (CPU uploads) or unorm ones (GPU frames).
fn plane_loads(unorm: bool) -> String {
    let mut s = String::new();
    for i in 0..4 {
        if unorm {
            s.push_str(&format!(
                "@group(0) @binding({}) var plane{i}: texture_2d<f32>;\n\
                 fn load{i}(p: vec2i) -> vec4u {{ return vec4u(round(textureLoad(plane{i}, p, 0) * unorm_max())); }}\n",
                2 + i
            ));
        } else {
            s.push_str(&format!(
                "@group(0) @binding({}) var plane{i}: texture_2d<u32>;\n\
                 fn load{i}(p: vec2i) -> vec4u {{ return textureLoad(plane{i}, p, 0); }}\n",
                2 + i
            ));
        }
    }
    if unorm {
        s.push_str("fn unorm_max() -> f32 { return select(255.0, 65535.0, cv.depth + cv.shift > 8u); }\n");
    }
    s
}

/// Binding of the first plane texture a frame planes pass writes (see [`planes_in_source`]).
const PLANES_FIRST_DST: u32 = 6;

/// The pass loading the planes of a `format` frame straight into the plane textures of its
/// [`PixelFormat::pixel_layout`], no RGBA in between: Y and chroma as stored codes over
/// 255 * 2^(depth - 8) (the 8-bit scale of point (11) of the plan), alpha over 2^depth - 1.
/// One thread per luma pixel; the first pixel of a UV texel writes it.
fn planes_in_source(format: PixelFormat, unorm: bool, f16: bool) -> String {
    let mut s = plane_loads(unorm);
    let layout = format.pixel_layout();
    for (b, &plane) in layout.planes().iter().enumerate() {
        let wgsl = crate::runtime::wgsl_format(crate::runtime::plane_format(plane, false, f16));
        s.push_str(&format!(
            "@group(0) @binding({}) var dst_{}: texture_storage_2d<{wgsl}, write>;\n",
            PLANES_FIRST_DST + b as u32,
            plane.suffix()
        ));
    }
    s.push_str(
        "fn code(raw: u32) -> f32 { return f32(raw >> cv.shift) / (255.0 * code_scale()); }\n\
         fn alpha_of(raw: u32) -> f32 { return f32(raw >> cv.shift) / code_max(); }\n",
    );
    let mut body = String::from("    textureStore(dst_y, p, vec4f(code(load0(p).r), 0.0, 0.0, 1.0));\n");
    if layout.planes().contains(&Plane::Uv) {
        let uv = if format.layout().kind == PlaneKind::SemiPlanar {
            "let t = load1(c);\n        let uv = vec2f(code(t.r), code(t.g));"
        } else {
            "let uv = vec2f(code(load1(c).r), code(load2(c).r));"
        };
        body.push_str(&format!(
            "    let sub = vec2u(cv.sub_x, cv.sub_y);\n    \
             if (all(id.xy % sub == vec2u(0u))) {{\n        let c = p / vec2i(sub);\n        {uv}\n        \
             textureStore(dst_uv, c, vec4f(uv, 0.0, 1.0));\n    }}\n"
        ));
    }
    if layout.planes().contains(&Plane::A) {
        body.push_str("    textureStore(dst_a, p, vec4f(alpha_of(load3(p).r), 0.0, 0.0, 1.0));\n");
    }
    s.push_str(&format!(
        "@compute @workgroup_size({WORKGROUP}, {WORKGROUP})\nfn main(@builtin(global_invocation_id) id: vec3u) {{\n    \
         if (id.x >= cv.width || id.y >= cv.height) {{ return; }}\n    let p = vec2i(id.xy);\n{body}}}\n"
    ));
    s
}

/// The pass writing one plane of a frame of `layout`'s kind straight from the plane
/// textures (the inverse of [`planes_in_source`]): convert_out_buffer.wgsl (CPU readback)
/// or, with the storage format of a GPU frame plane, convert_out_image.wgsl. Bindings: the
/// Y plane at 1, the destination at 2, UV at 3 and A at 4.
fn planes_out_source(layout: PixelLayout, storage: Option<&str>) -> String {
    let planes = layout.planes();
    let mut s = String::from("@group(0) @binding(1) var src_y: texture_2d<f32>;\n");
    if planes.contains(&Plane::Uv) {
        s.push_str("@group(0) @binding(3) var src_uv: texture_2d<f32>;\n");
    }
    let alpha = if planes.contains(&Plane::A) {
        s.push_str("@group(0) @binding(4) var src_a: texture_2d<f32>;\n");
        "textureLoad(src_a, p, 0).r"
    } else {
        "1.0"
    };
    // A chroma plane is told by its first channel (U or V), not its size: 4:4:4 chroma has
    // the size of Y.
    let chroma = if planes.contains(&Plane::Uv) {
        "    if (cv.ch0 == 1u || cv.ch0 == 2u) {\n        return vec4f(0.0, textureLoad(src_uv, p, 0).rg, 1.0);\n    }\n"
    } else {
        ""
    };
    s.push_str(&format!(
        "fn sample(s: vec2u) -> vec4f {{\n    let p = vec2i(s);\n{chroma}    \
         return vec4f(textureLoad(src_y, p, 0).r, 0.0, 0.0, {alpha});\n}}\n\
         fn encode(v: f32, ch: u32) -> u32 {{\n    let m = code_max();\n    \
         let c = select(v * 255.0 * code_scale(), v * m, ch == 3u);\n    \
         return u32(clamp(round(c), 0.0, m)) << cv.shift;\n}}\n\
         fn channel(i: u32) -> u32 {{\n    switch i {{\n        case 0u: {{ return cv.ch0; }}\n        \
         case 1u: {{ return cv.ch1; }}\n        case 2u: {{ return cv.ch2; }}\n        default: {{ return cv.ch3; }}\n    }}\n}}\n"
    ));
    match storage {
        Some(format) => s.push_str(&include_str!("convert_out_image.wgsl").replace("STORAGE_FORMAT", format)),
        None => s.push_str(include_str!("convert_out_buffer.wgsl")),
    }
    s
}

/// Layout entries of a [`planes_out_source`] pass: the destination is `dst`.
fn planes_out_entries(layout: PixelLayout, dst: wgpu::BindingType) -> Vec<wgpu::BindGroupLayoutEntry> {
    let src = texture(wgpu::TextureSampleType::Float { filterable: false });
    let mut entries = vec![entry(0, UNIFORM), entry(1, src), entry(2, dst)];
    for (b, _) in layout.planes().iter().enumerate().skip(1) {
        entries.push(entry(2 + b as u32, src));
    }
    entries
}

/// Bind group entries of a [`planes_out_source`] pass reading `views` (the planes of the
/// layout, in order) and writing `dst`.
fn planes_out_group<'a>(
    uniform: &'a wgpu::Buffer,
    views: &'a [wgpu::TextureView],
    dst: wgpu::BindingResource<'a>,
) -> Vec<wgpu::BindGroupEntry<'a>> {
    let mut entries = vec![
        wgpu::BindGroupEntry { binding: 0, resource: uniform.as_entire_binding() },
        wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&views[0]) },
        wgpu::BindGroupEntry { binding: 2, resource: dst },
    ];
    for (b, v) in views.iter().enumerate().skip(1) {
        entries.push(wgpu::BindGroupEntry { binding: 2 + b as u32, resource: wgpu::BindingResource::TextureView(v) });
    }
    entries
}

fn to_rgba_pipelines(
    device: &wgpu::Device,
    cache: Option<&ShaderCache>,
    unorm: bool,
) -> [(wgpu::ComputePipeline, wgpu::BindGroupLayout); 2] {
    let plane = texture(if unorm { wgpu::TextureSampleType::Float { filterable: false } } else { wgpu::TextureSampleType::Uint });
    [false, true].map(|deep| {
        pipeline(
            device,
            cache,
            "gpufx convert in",
            &convert_in_source(deep, unorm),
            &[
                entry(0, UNIFORM),
                entry(
                    1,
                    wgpu::BindingType::StorageTexture {
                        access: wgpu::StorageTextureAccess::WriteOnly,
                        format: deep_format(deep),
                        view_dimension: wgpu::TextureViewDimension::D2,
                    },
                ),
                entry(2, plane),
                entry(3, plane),
                entry(4, plane),
                entry(5, plane),
            ],
        )
    })
}

impl Converter {
    pub fn new(device: &wgpu::Device, cache: Option<Arc<ShaderCache>>) -> Self {
        let to_rgba = to_rgba_pipelines(device, cache.as_deref(), false);
        let (from_rgba, from_rgba_layout) = pipeline(
            device,
            cache.as_deref(),
            "gpufx convert out",
            &format!("{}{}", include_str!("convert_out.wgsl"), include_str!("convert_out_buffer.wgsl")),
            &[
                entry(0, UNIFORM),
                // textureLoad only, so rgba8unorm inputs (bypass) and rgba16float both fit.
                entry(1, texture(wgpu::TextureSampleType::Float { filterable: false })),
                entry(
                    2,
                    wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage { read_only: false },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                ),
            ],
        );
        let dummy = texture_2d(device, "gpufx dummy plane", 1, 1, wgpu::TextureFormat::R8Uint, wgpu::TextureUsages::TEXTURE_BINDING)
            .create_view(&Default::default());
        Converter {
            device: device.clone(),
            cache,
            to_rgba,
            to_rgba_gpu: OnceLock::new(),
            from_rgba,
            from_rgba_layout,
            to_planes: Default::default(),
            to_yuv: Default::default(),
            dummy,
            dummy_gpu: OnceLock::new(),
            layouts: Default::default(),
            planes_in: Default::default(),
            planes_out: Default::default(),
        }
    }

    fn to_rgba(&self, gpu: bool, deep: bool) -> &(wgpu::ComputePipeline, wgpu::BindGroupLayout) {
        if gpu {
            &self.to_rgba_gpu.get_or_init(|| to_rgba_pipelines(&self.device, self.cache.as_deref(), true))[deep as usize]
        } else {
            &self.to_rgba[deep as usize]
        }
    }

    fn dummy(&self, gpu: bool) -> &wgpu::TextureView {
        if !gpu {
            return &self.dummy;
        }
        self.dummy_gpu.get_or_init(|| {
            texture_2d(&self.device, "gpufx dummy plane", 1, 1, wgpu::TextureFormat::R8Unorm, wgpu::TextureUsages::TEXTURE_BINDING)
                .create_view(&Default::default())
        })
    }

    /// The pass writing a plane texture of `format`.
    fn to_plane(&self, format: wgpu::TextureFormat) -> Result<&(wgpu::ComputePipeline, wgpu::BindGroupLayout), Error> {
        let i = PLANE_FORMATS
            .iter()
            .position(|&(f, _)| f == format)
            .ok_or_else(|| Error::Frame(format!("{format:?} is not a plane format of GPU frames")))?;
        Ok(self.to_planes[i].get_or_init(|| {
            let body = format!(
                "{}{}",
                include_str!("convert_out.wgsl"),
                include_str!("convert_out_image.wgsl").replace("STORAGE_FORMAT", PLANE_FORMATS[i].1)
            );
            pipeline(
                &self.device,
                self.cache.as_deref(),
                "gpufx convert out (gpu)",
                &body,
                &[
                    entry(0, UNIFORM),
                    entry(1, texture(wgpu::TextureSampleType::Float { filterable: false })),
                    entry(
                        2,
                        wgpu::BindingType::StorageTexture {
                            access: wgpu::StorageTextureAccess::WriteOnly,
                            format,
                            view_dimension: wgpu::TextureViewDimension::D2,
                        },
                    ),
                ],
            )
        }))
    }

    /// The pass writing every plane of a YUV `format` GPU frame (convert_out_fused.wgsl).
    fn to_yuv(&self, format: PixelFormat) -> Result<&(wgpu::ComputePipeline, wgpu::BindGroupLayout), Error> {
        if !fused(format) {
            return Err(Error::Frame(format!("{} is not a YUV format", format.name())));
        }
        Ok(self.to_yuv[format as usize].get_or_init(|| {
            let (decl, entries) = fused_source(format);
            let body = format!("{}{decl}{}", include_str!("convert_out.wgsl"), include_str!("convert_out_fused.wgsl"));
            pipeline(&self.device, self.cache.as_deref(), "gpufx convert out (gpu yuv)", &body, &entries)
        }))
    }
}

impl Converter {
    /// The pass loading the planes of `format` frames into plane textures ([`planes_in_source`]).
    fn planes_in(&self, format: PixelFormat, gpu: bool, f16: bool) -> (wgpu::ComputePipeline, wgpu::BindGroupLayout) {
        let mut passes = self.planes_in.lock().unwrap_or_else(|e| e.into_inner());
        passes
            .entry((format, gpu, f16))
            .or_insert_with(|| {
                let plane = texture(if gpu { wgpu::TextureSampleType::Float { filterable: false } } else { wgpu::TextureSampleType::Uint });
                let mut entries: Vec<_> = (0..4).map(|i| entry(2 + i, plane)).collect();
                entries.insert(0, entry(0, UNIFORM));
                for (b, &p) in format.pixel_layout().planes().iter().enumerate() {
                    entries.push(entry(
                        PLANES_FIRST_DST + b as u32,
                        wgpu::BindingType::StorageTexture {
                            access: wgpu::StorageTextureAccess::WriteOnly,
                            format: crate::runtime::plane_format(p, false, f16),
                            view_dimension: wgpu::TextureViewDimension::D2,
                        },
                    ));
                }
                let source = planes_in_source(format, gpu, f16);
                pipeline(&self.device, self.cache.as_deref(), "gpufx frame planes in", &source, &entries)
            })
            .clone()
    }

    /// The pass writing one frame plane from the plane textures of `layout`
    /// ([`planes_out_source`]): into a GPU frame plane of `storage`, or packed words.
    fn planes_out(
        &self,
        layout: PixelLayout,
        storage: Option<wgpu::TextureFormat>,
    ) -> Result<(wgpu::ComputePipeline, wgpu::BindGroupLayout), Error> {
        let name = match storage {
            Some(format) => Some(
                PLANE_FORMATS
                    .iter()
                    .find(|&&(f, _)| f == format)
                    .ok_or_else(|| Error::Frame(format!("{format:?} is not a plane format of GPU frames")))?
                    .1,
            ),
            None => None,
        };
        let mut passes = self.planes_out.lock().unwrap_or_else(|e| e.into_inner());
        Ok(passes
            .entry((layout, storage))
            .or_insert_with(|| {
                let dst = match storage {
                    Some(format) => wgpu::BindingType::StorageTexture {
                        access: wgpu::StorageTextureAccess::WriteOnly,
                        format,
                        view_dimension: wgpu::TextureViewDimension::D2,
                    },
                    None => wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage { read_only: false },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                };
                let entries = planes_out_entries(layout, dst);
                pipeline(&self.device, self.cache.as_deref(), "gpufx frame planes out", &planes_out_source(layout, name), &entries)
            })
            .clone())
    }
}

/// Plane bindings dst0.. and store_luma/store_chroma of convert_out_fused.wgsl for a YUV
/// `format`, with the layout entries.
fn fused_source(format: PixelFormat) -> (String, Vec<wgpu::BindGroupLayoutEntry>) {
    let l = format.layout();
    let mut decl = String::new();
    let mut entries = vec![entry(0, UNIFORM), entry(1, texture(wgpu::TextureSampleType::Float { filterable: false }))];
    for p in 0..format.plane_count() {
        let tf = format.plane_texture_format(p);
        let name = PLANE_FORMATS.iter().find(|&&(f, _)| f == tf).expect("a plane format of GPU frames").1;
        decl.push_str(&format!("@group(0) @binding({}) var dst{p}: texture_storage_2d<{name}, write>;\n", 2 + p));
        entries.push(entry(
            2 + p as u32,
            wgpu::BindingType::StorageTexture {
                access: wgpu::StorageTextureAccess::WriteOnly,
                format: tf,
                view_dimension: wgpu::TextureViewDimension::D2,
            },
        ));
    }
    // Unwritten channels as convert_out_image.wgsl leaves them: 0, alpha 1.
    let alpha = if l.alpha { "    textureStore(dst3, p, vec4f(plane_value(v.w, 3u), 0.0, 0.0, 1.0));\n" } else { "" };
    decl.push_str(&format!(
        "fn store_luma(p: vec2i, v: vec4f) {{\n    textureStore(dst0, p, vec4f(plane_value(v.x, 0u), 0.0, 0.0, 1.0));\n{alpha}}}\n"
    ));
    decl.push_str(if l.kind == PlaneKind::SemiPlanar {
            "fn store_chroma(p: vec2i, v: vec4f) {\n    textureStore(dst1, p, vec4f(plane_value(v.y, 1u), plane_value(v.z, 2u), 0.0, 1.0));\n}\n"
        } else {
            "fn store_chroma(p: vec2i, v: vec4f) {\n    textureStore(dst1, p, vec4f(plane_value(v.y, 1u), 0.0, 0.0, 1.0));\n    \
             textureStore(dst2, p, vec4f(plane_value(v.z, 2u), 0.0, 0.0, 1.0));\n}\n"
        });
    (decl, entries)
}

/// Number of [`PixelFormat`] variants.
const PIXEL_FORMATS: usize = PixelFormat::Gray as usize + 1;

/// A 1x1 `rgba8unorm` texture bound until the frame's own texture is known.
pub(crate) fn stand_in(device: &wgpu::Device, usage: wgpu::TextureUsages) -> wgpu::Texture {
    texture_2d(device, "gpufx stand-in", 1, 1, wgpu::TextureFormat::Rgba8Unorm, usage)
}

pub(crate) fn texture_2d(
    device: &wgpu::Device,
    label: &str,
    w: u32,
    h: u32,
    format: wgpu::TextureFormat,
    usage: wgpu::TextureUsages,
) -> wgpu::Texture {
    texture_2d_mips(device, label, w, h, format, usage, false)
}

/// [`texture_2d`], with a full mip chain when `mips` (filled by [`crate::mips`]).
pub(crate) fn texture_2d_mips(
    device: &wgpu::Device,
    label: &str,
    w: u32,
    h: u32,
    format: wgpu::TextureFormat,
    usage: wgpu::TextureUsages,
    mips: bool,
) -> wgpu::Texture {
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: if mips { crate::texture::mip_levels(w, h) } else { 1 },
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage,
        view_formats: &[],
    })
}

/// Integer texture format of plane `plane` of `format`.
fn plane_format(format: PixelFormat, plane: usize) -> wgpu::TextureFormat {
    use wgpu::TextureFormat as T;
    let (_, _, channels) = format.plane_dims(plane, 1, 1);
    match (channels, format.layout().bytes) {
        (4, 1) => T::Rgba8Uint,
        (4, _) => T::Rgba16Uint,
        (2, 1) => T::Rg8Uint,
        (2, _) => T::Rg16Uint,
        (_, 1) => T::R8Uint,
        _ => T::R16Uint,
    }
}

/// Bytes of the `Conv` uniform: frame and colour fields, then the output plane fields.
fn uniform(format: PixelFormat, w: u32, h: u32, color: &ColorInfo, plane: Option<usize>) -> [u8; UNIFORM_SIZE as usize] {
    let l: Layout = format.layout();
    let (kr, kb) = color.matrix.kr_kb();
    let (site_x, site_y) = color.chroma_location.siting();
    let mut words: Vec<u32> = vec![
        w,
        h,
        w.div_ceil(l.sub.0),
        h.div_ceil(l.sub.1),
        l.sub.0,
        l.sub.1,
        l.kind as u32,
        l.alpha as u32,
        l.depth,
        l.shift,
        (color.range == crate::frame::Range::Full) as u32,
        color.premultiplied as u32,
        kr.to_bits(),
        kb.to_bits(),
        site_x.to_bits(),
        site_y.to_bits(),
    ];
    if let Some(p) = plane {
        let (pw, ph, channels) = format.plane_dims(p, w, h);
        let (row_bytes, _) = format.plane_size(p, w, h);
        let chroma = (pw, ph) != (w, h);
        // Channels of each interleaved sample: 0 Y/R, 1 U/G, 2 V/B, 3 A.
        let ch: [u32; 4] = match (l.kind, p) {
            (PlaneKind::Rgba, _) => [0, 1, 2, 3],
            (PlaneKind::SemiPlanar, 1) => [1, 2, 0, 0],
            (PlaneKind::Planar, 1) => [1, 0, 0, 0],
            (PlaneKind::Planar, 2) => [2, 0, 0, 0],
            (PlaneKind::Planar, 3) => [3, 0, 0, 0],
            _ => [0, 0, 0, 0],
        };
        words.extend([pw, ph, channels, l.bytes, row_bytes.div_ceil(4), chroma as u32]);
        words.extend(ch);
    }
    words.resize(UNIFORM_SIZE as usize / 4, 0);
    let mut out = [0u8; UNIFORM_SIZE as usize];
    for (dst, word) in out.as_chunks_mut::<4>().0.iter_mut().zip(words) {
        *dst = word.to_le_bytes();
    }
    out
}

fn uniform_buffer(device: &wgpu::Device, label: &str) -> wgpu::Buffer {
    device.create_buffer(&wgpu::BufferDescriptor {
        label: Some(label),
        size: UNIFORM_SIZE,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    })
}

/// What an input slot was made for; a frame with another key needs a new slot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct InputKey {
    pub format: PixelFormat,
    pub width: u32,
    pub height: u32,
    /// Straight RGBA8: uploaded as `rgba8unorm` and read by effects without a pass. With
    /// `gpu`, the frame's own texture is read: nothing is pooled (see `graph::prepare`).
    /// With a `layout` of planes, the frame's planes are read in place as the layout's
    /// planes (8-bit NV12 and gray GPU frames, see `graph::pad_layouts`).
    pub direct: bool,
    /// A [`crate::GpuFrame`]: no upload, the conversion pass reads its plane textures.
    pub gpu: bool,
    /// What effects read: `rgba` (the conversion to RGBA), or the planes of the format's own
    /// [`PixelFormat::pixel_layout`], loaded straight from the frame planes.
    pub layout: PixelLayout,
}

/// Upload textures of one input and, unless direct, its conversion pass. Reused from
/// frame to frame while the key holds.
pub(crate) struct InputSlot {
    pub key: InputKey,
    /// Upload textures; none for GPU frames.
    planes: Vec<wgpu::Texture>,
    /// The texture the first effect reads: the RGBA8 plane itself, or the target of the
    /// conversion pass; the first of `layout_planes` for a layout with planes.
    pub texture: wgpu::Texture,
    /// The plane textures effects read for a layout with planes: written by the pass, or the
    /// planes of the GPU frame read in place. Empty for `rgba`.
    layout_planes: Vec<wgpu::Texture>,
    /// Uniforms of the conversion pass, unless direct.
    uniform: Option<wgpu::Buffer>,
    /// Made once for uploads; for GPU frames, the one of the frame's planes.
    bind_group: Option<wgpu::BindGroup>,
    /// GPU frames: the bind groups of the planes of recent frames.
    gpu_binds: Lru<Vec<wgpu::Texture>, wgpu::BindGroup>,
    deep: bool,
    /// Plane textures are 16-bit floats (see [`crate::GpuContext::plane_f16`]).
    f16: bool,
}

impl InputSlot {
    /// The textures of a slot, borrowed from the context pool: the upload planes, then
    /// the converted frame (or the layout's planes) unless direct. `deep`: convert into
    /// `rgba16float` rather than `rgba8unorm`. `mips`: the texture effects read has a mip
    /// chain (filled by the caller after `encode`).
    pub fn pool_keys(key: InputKey, deep: bool, mips: bool, f16: bool) -> Vec<PoolKey> {
        let (w, h) = (key.width, key.height);
        let tex = |width, height, format, usage, mips| PoolKey::Texture { width, height, format, usage, mips };
        let copy = wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST;
        if key.direct && key.gpu {
            return Vec::new();
        }
        if key.direct {
            let usage = if mips { copy | wgpu::TextureUsages::STORAGE_BINDING } else { copy };
            return vec![tex(w, h, wgpu::TextureFormat::Rgba8Unorm, usage, mips)];
        }
        let mut keys: Vec<PoolKey> = if key.gpu {
            Vec::new()
        } else {
            (0..key.format.plane_count())
                .map(|p| {
                    let (pw, ph, _) = key.format.plane_dims(p, w, h);
                    tex(pw, ph, plane_format(key.format, p), copy, false)
                })
                .collect()
        };
        let usage = wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING;
        if key.layout != PixelLayout::Rgba {
            for &plane in key.layout.planes() {
                let (pw, ph) = key.layout.plane_size(plane, (w, h));
                keys.push(tex(pw, ph, crate::runtime::plane_format(plane, deep, f16), usage, false));
            }
            return keys;
        }
        keys.push(tex(w, h, deep_format(deep), usage, mips));
        keys
    }

    /// A slot on `textures`, made for [`InputSlot::pool_keys`] of the same arguments. A
    /// direct GPU slot reads `frame`, the plane textures of the frame being recorded
    /// (stand-ins when there are none: the caller points it at the frame before use).
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        device: &wgpu::Device,
        conv: &Converter,
        key: InputKey,
        deep: bool,
        f16: bool,
        mut textures: Vec<wgpu::Texture>,
        frame: &[wgpu::Texture],
    ) -> Self {
        let planar = key.layout != PixelLayout::Rgba;
        let bare = |texture: wgpu::Texture, planes: Vec<wgpu::Texture>, layout_planes: Vec<wgpu::Texture>| InputSlot {
            key,
            planes,
            texture,
            layout_planes,
            uniform: None,
            bind_group: None,
            gpu_binds: Lru::default(),
            deep,
            f16,
        };
        if key.direct && key.gpu {
            let n = if planar { key.layout.planes().len() } else { 1 };
            let read: Vec<wgpu::Texture> =
                (0..n).map(|p| frame.get(p).cloned().unwrap_or_else(|| stand_in(device, wgpu::TextureUsages::TEXTURE_BINDING))).collect();
            let layout_planes = if planar { read.clone() } else { Vec::new() };
            return bare(read[0].clone(), Vec::new(), layout_planes);
        }
        if key.direct {
            let tex = textures.pop().expect("one texture");
            return bare(tex.clone(), vec![tex], Vec::new());
        }
        let (texture, layout_planes, planes) = if planar {
            let n = textures.len() - key.layout.planes().len();
            let layout_planes = textures.split_off(n);
            (layout_planes[0].clone(), layout_planes, textures)
        } else {
            let texture = textures.pop().expect("the converted frame");
            (texture, Vec::new(), textures)
        };
        let mut slot = bare(texture, planes, layout_planes);
        slot.uniform = Some(uniform_buffer(device, "gpufx convert in"));
        if !key.gpu {
            let planes = slot.planes.clone();
            slot.bind_group = Some(slot.bind_group_of(device, conv, &planes));
        }
        slot
    }

    /// The textures effects read, one per plane of the key's layout.
    pub fn read_planes(&self) -> Vec<wgpu::Texture> {
        if self.key.layout == PixelLayout::Rgba {
            vec![self.texture.clone()]
        } else {
            self.layout_planes.clone()
        }
    }

    /// Points a direct GPU slot at the planes of the frame being recorded.
    pub fn read_in_place(&mut self, planes: &[wgpu::Texture]) {
        self.texture = planes[0].clone();
        if self.key.layout != PixelLayout::Rgba {
            self.layout_planes = planes[..self.key.layout.planes().len()].to_vec();
        }
    }

    /// Whether the slot runs the conversion to RGBA (not a load of planes, nor a direct read).
    pub fn converts_to_rgba(&self) -> bool {
        self.uniform.is_some() && self.key.layout == PixelLayout::Rgba
    }

    /// A bind group of the conversion pass reading `planes`.
    fn bind_group_of(&self, device: &wgpu::Device, conv: &Converter, planes: &[wgpu::Texture]) -> wgpu::BindGroup {
        let buf = self.uniform.as_ref().expect("a conversion pass");
        let rgba = self.key.layout == PixelLayout::Rgba;
        let level0 = |t: &wgpu::Texture| t.create_view(&wgpu::TextureViewDescriptor { mip_level_count: Some(1), ..Default::default() });
        let dsts: Vec<wgpu::TextureView> = if rgba { vec![level0(&self.texture)] } else { self.layout_planes.iter().map(level0).collect() };
        let views: Vec<wgpu::TextureView> = planes.iter().map(|t| t.create_view(&Default::default())).collect();
        let mut entries = vec![wgpu::BindGroupEntry { binding: 0, resource: buf.as_entire_binding() }];
        let first_dst = if rgba { 1 } else { PLANES_FIRST_DST };
        for (b, v) in dsts.iter().enumerate() {
            entries.push(wgpu::BindGroupEntry { binding: first_dst + b as u32, resource: wgpu::BindingResource::TextureView(v) });
        }
        for i in 0..4 {
            let view = views.get(i).unwrap_or(conv.dummy(self.key.gpu));
            entries.push(wgpu::BindGroupEntry { binding: 2 + i as u32, resource: wgpu::BindingResource::TextureView(view) });
        }
        let layout =
            if rgba { conv.to_rgba(self.key.gpu, self.deep).1.clone() } else { conv.planes_in(self.key.format, self.key.gpu, self.f16).1 };
        device.create_bind_group(&wgpu::BindGroupDescriptor { label: Some("gpufx convert in"), layout: &layout, entries: &entries })
    }

    /// Textures this slot holds: the planes, and the converted frame (or its layout's
    /// planes) unless direct.
    pub fn texture_count(&self) -> usize {
        let made = if self.key.layout == PixelLayout::Rgba { 1 } else { self.layout_planes.len() };
        self.planes.len() + if self.uniform.is_some() { made } else { 0 }
    }

    /// Bytes of those textures, mip chains included.
    pub fn texture_bytes(&self) -> u64 {
        let size = |t: &wgpu::Texture| {
            let bytes = t.format().block_copy_size(None).unwrap_or(4) as u64;
            let mips = if t.mip_level_count() > 1 { crate::mips::chain_bytes(t.width(), t.height(), bytes) } else { 0 };
            t.width() as u64 * t.height() as u64 * bytes + mips
        };
        let made: u64 = if self.uniform.is_none() {
            0
        } else if self.key.layout == PixelLayout::Rgba {
            size(&self.texture)
        } else {
            self.layout_planes.iter().map(size).sum()
        };
        self.planes.iter().map(size).sum::<u64>() + made
    }

    /// Uploads the planes of a frame matching the key, and its colour info.
    pub fn upload(&self, queue: &wgpu::Queue, planes: &[&[u8]; 4], strides: &[u32; 4], color: &ColorInfo) {
        let (w, h) = (self.key.width, self.key.height);
        for (p, tex) in self.planes.iter().enumerate() {
            let (pw, ph, _) = self.key.format.plane_dims(p, w, h);
            queue.write_texture(
                tex.as_image_copy(),
                planes[p],
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(strides[p]), rows_per_image: Some(ph) },
                wgpu::Extent3d { width: pw, height: ph, depth_or_array_layers: 1 },
            );
        }
        if let Some(buf) = &self.uniform {
            queue.write_buffer(buf, 0, &uniform(self.key.format, w, h, color, None));
        }
    }

    /// Points the conversion pass at the planes of a GPU frame matching the key. Returns
    /// whether a bind group was made (the planes of a recent frame reuse theirs).
    pub fn use_gpu_frame(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        conv: &Converter,
        planes: &[wgpu::Texture],
        color: &ColorInfo,
    ) -> bool {
        let mut binds = std::mem::take(&mut self.gpu_binds);
        let (bg, made) = binds
            .get_or_make(planes.to_vec(), |p| Ok::<_, std::convert::Infallible>(self.bind_group_of(device, conv, p)))
            .unwrap_or_else(|e| match e {});
        self.bind_group = Some(bg.clone());
        self.gpu_binds = binds;
        self.upload(queue, &[&[]; 4], &[0; 4], color);
        made
    }

    pub fn encode(&self, conv: &Converter, cpass: &mut wgpu::ComputePass) {
        if let Some(bg) = &self.bind_group {
            if self.key.layout != PixelLayout::Rgba {
                cpass.set_pipeline(&conv.planes_in(self.key.format, self.key.gpu, self.f16).0);
                cpass.set_bind_group(0, bg, &[]);
                cpass.dispatch_workgroups(self.key.width.div_ceil(WORKGROUP), self.key.height.div_ceil(WORKGROUP), 1);
                return;
            }
            cpass.set_pipeline(&conv.to_rgba(self.key.gpu, self.deep).0);
            cpass.set_bind_group(0, bg, &[]);
            let group = in_group(self.key.gpu);
            cpass.dispatch_workgroups(self.key.width.div_ceil(group), self.key.height.div_ceil(group), 1);
        }
    }
}

/// Conversion passes of one output that stays on the GPU: they write the plane textures
/// of the [`crate::GpuFrame`] given with each frame. A YUV output is written by one pass
/// for all its planes (convert_out_fused.wgsl), RGBA by one pass per plane; an output read
/// from plane textures of its format's own layout ([`GpuOutputSlot::bind_planes`]) by one
/// pass per plane too, with no RGBA in between.
pub(crate) struct GpuOutputSlot {
    pub key: (PixelFormat, u32, u32),
    /// One per plane; a fused pass uses the first.
    uniforms: Vec<wgpu::Buffer>,
    /// The passes to record: pipeline, bind group, workgroups.
    passes: Vec<OutPass>,
    /// The passes of recent (sources, planes), as the frames of a pool come back.
    binds: Lru<(Vec<wgpu::Texture>, Vec<wgpu::Texture>), Vec<OutPass>>,
    /// Bound through [`GpuOutputSlot::bind_planes`].
    planar: bool,
}

type OutPass = (wgpu::ComputePipeline, wgpu::BindGroup, (u32, u32));

/// Whether the planes of a `format` GPU output are written by one fused pass.
fn fused(format: PixelFormat) -> bool {
    matches!(format.layout().kind, PlaneKind::SemiPlanar | PlaneKind::Planar)
}

impl GpuOutputSlot {
    pub fn new(device: &wgpu::Device, format: PixelFormat, w: u32, h: u32) -> Self {
        let uniforms = (0..format.plane_count()).map(|_| uniform_buffer(device, "gpufx convert out")).collect();
        GpuOutputSlot { key: (format, w, h), uniforms, passes: Vec::new(), binds: Lru::default(), planar: false }
    }

    /// Makes the passes read `source` and write `planes`, with the colours of `color`.
    /// Returns whether bind groups were made (a recent source and planes reuse theirs).
    pub fn bind(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        conv: &Converter,
        source: &wgpu::Texture,
        planes: &[wgpu::Texture],
        color: &ColorInfo,
    ) -> Result<bool, Error> {
        let (format, w, h) = self.key;
        if fused(format) {
            queue.write_buffer(&self.uniforms[0], 0, &uniform(format, w, h, color, None));
        } else {
            for (i, buf) in self.uniforms.iter().enumerate() {
                queue.write_buffer(buf, 0, &uniform(format, w, h, color, Some(i)));
            }
        }
        self.planar = false;
        self.bind_with(vec![source.clone()], planes, |slot, sources, planes| slot.passes_of(device, conv, &sources[0], planes))
    }

    /// Makes the passes write `planes` straight from `sources`, the plane textures of the
    /// format's own [`PixelFormat::pixel_layout`] (the codes as they are, see
    /// [`planes_out_source`]). Returns whether bind groups were made.
    pub fn bind_planes(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        conv: &Converter,
        sources: &[wgpu::Texture],
        planes: &[wgpu::Texture],
        color: &ColorInfo,
    ) -> Result<bool, Error> {
        let (format, w, h) = self.key;
        for (i, buf) in self.uniforms.iter().enumerate() {
            queue.write_buffer(buf, 0, &uniform(format, w, h, color, Some(i)));
        }
        self.planar = true;
        self.bind_with(sources.to_vec(), planes, |slot, sources, planes| {
            let views: Vec<wgpu::TextureView> = sources.iter().map(|t| t.create_view(&Default::default())).collect();
            let mut passes = Vec::new();
            for (p, (buf, plane)) in slot.uniforms.iter().zip(planes).enumerate() {
                let (pipeline, layout) = conv.planes_out(format.pixel_layout(), Some(plane.format()))?;
                let dst = plane.create_view(&Default::default());
                let entries = planes_out_group(buf, &views, wgpu::BindingResource::TextureView(&dst));
                let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("gpufx frame planes out (gpu)"),
                    layout: &layout,
                    entries: &entries,
                });
                let (pw, ph) = format.plane_texture_size(p, w, h);
                passes.push((pipeline, group, (pw.div_ceil(WORKGROUP), ph.div_ceil(WORKGROUP))));
            }
            Ok(passes)
        })
    }

    /// Whether the slot is bound to write from plane textures.
    pub fn is_planar(&self) -> bool {
        self.planar && !self.passes.is_empty()
    }

    /// Whether the slot has passes to record (not written by an effect in place).
    pub fn is_bound(&self) -> bool {
        !self.passes.is_empty()
    }

    fn bind_with(
        &mut self,
        sources: Vec<wgpu::Texture>,
        planes: &[wgpu::Texture],
        make: impl FnOnce(&Self, &[wgpu::Texture], &[wgpu::Texture]) -> Result<Vec<OutPass>, Error>,
    ) -> Result<bool, Error> {
        let mut binds = std::mem::take(&mut self.binds);
        let made = binds.get_or_make((sources, planes.to_vec()), |(sources, planes)| make(self, sources, planes));
        let made = made.map(|(passes, made)| {
            self.passes = passes.clone();
            made
        });
        self.binds = binds;
        made
    }

    fn passes_of(
        &self,
        device: &wgpu::Device,
        conv: &Converter,
        source: &wgpu::Texture,
        planes: &[wgpu::Texture],
    ) -> Result<Vec<OutPass>, Error> {
        let (format, w, h) = self.key;
        let view = source.create_view(&wgpu::TextureViewDescriptor { mip_level_count: Some(1), ..Default::default() });
        if fused(format) {
            let views: Vec<wgpu::TextureView> = planes.iter().map(|p| p.create_view(&Default::default())).collect();
            let mut entries = vec![
                wgpu::BindGroupEntry { binding: 0, resource: self.uniforms[0].as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&view) },
            ];
            for (i, v) in views.iter().enumerate() {
                entries.push(wgpu::BindGroupEntry { binding: 2 + i as u32, resource: wgpu::BindingResource::TextureView(v) });
            }
            let (pipeline, layout) = conv.to_yuv(format)?;
            let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("gpufx convert out (gpu yuv)"),
                layout,
                entries: &entries,
            });
            // One invocation per chroma sample (plane 1).
            let (cw, ch) = format.plane_texture_size(1, w, h);
            return Ok(vec![(pipeline.clone(), group, (cw.div_ceil(WORKGROUP), ch.div_ceil(WORKGROUP)))]);
        }
        let mut passes = Vec::new();
        for (p, (buf, plane)) in self.uniforms.iter().zip(planes).enumerate() {
            let dst = plane.create_view(&Default::default());
            let (pipeline, layout) = conv.to_plane(plane.format())?;
            let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("gpufx convert out (gpu)"),
                layout,
                entries: &[
                    wgpu::BindGroupEntry { binding: 0, resource: buf.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&view) },
                    wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&dst) },
                ],
            });
            let (pw, ph) = format.plane_texture_size(p, w, h);
            passes.push((pipeline.clone(), group, (pw.div_ceil(WORKGROUP), ph.div_ceil(WORKGROUP))));
        }
        Ok(passes)
    }

    /// No pass until bound again: the output is written by an effect.
    pub fn unbind(&mut self) {
        self.passes.clear();
    }

    pub fn encode(&self, _conv: &Converter, cpass: &mut wgpu::ComputePass) -> Result<(), Error> {
        for (pipeline, group, (x, y)) in &self.passes {
            cpass.set_pipeline(pipeline);
            cpass.set_bind_group(0, group, &[]);
            cpass.dispatch_workgroups(*x, *y, 1);
        }
        Ok(())
    }
}

struct OutPlane {
    /// Packed words the pass writes: a pooled buffer of `size` bytes, set per frame.
    words: Option<wgpu::Buffer>,
    size: u64,
    uniform: wgpu::Buffer,
    row_words: u32,
    rows: u32,
    row_bytes: u32,
    /// Offset of the plane in the readback buffer.
    offset: u64,
}

/// Conversion passes of one output. Its planes are copied into a readback buffer shared
/// by every output of a graph, at `offset`..`end()`.
pub(crate) struct OutputSlot {
    pub key: (PixelFormat, u32, u32),
    planes: Vec<OutPlane>,
    end: u64,
    /// Bind groups reading the effect output ([0]) and the input texture (bypass, [1]),
    /// both kept so a timeline toggling the filter makes nothing new.
    bind_groups: [Option<Vec<wgpu::BindGroup>>; 2],
    /// The pass of the bind groups of the effect output when it writes the planes straight
    /// from plane textures ([`OutputSlot::bind_planes`]); else `from_rgba`.
    planar: Option<wgpu::ComputePipeline>,
}

impl OutputSlot {
    /// `offset`: where the planes start in the shared readback buffer (a multiple of 4).
    pub fn new(device: &wgpu::Device, format: PixelFormat, w: u32, h: u32, mut offset: u64) -> Result<Self, Error> {
        let max = device.limits().max_storage_buffer_binding_size;
        let mut planes = Vec::new();
        for p in 0..format.plane_count() {
            let (row_bytes, rows) = format.plane_size(p, w, h);
            let row_words = row_bytes.div_ceil(4);
            let size = row_words as u64 * 4 * rows as u64;
            if size > max {
                return Err(Error::Frame(format!(
                    "a {w}x{h} {} frame is too large for this GPU: plane {p} needs {size} bytes, the limit is {max}",
                    format.name()
                )));
            }
            planes.push(OutPlane {
                words: None,
                size,
                uniform: uniform_buffer(device, "gpufx convert out"),
                row_words,
                rows,
                row_bytes,
                offset,
            });
            offset += size;
        }
        Ok(OutputSlot { key: (format, w, h), planes, end: offset, bind_groups: [None, None], planar: None })
    }

    /// The word buffers of the planes, borrowed from the context pool.
    pub fn pool_keys(&self) -> Vec<PoolKey> {
        let usage = wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC;
        self.planes.iter().map(|p| PoolKey::Buffer { size: p.size, usage }).collect()
    }

    /// Makes the passes write `words` (one per [`OutputSlot::pool_keys`]); they have to
    /// be bound again.
    pub fn set_words(&mut self, words: Vec<wgpu::Buffer>) {
        for (p, b) in self.planes.iter_mut().zip(words) {
            p.words = Some(b);
        }
        self.bind_groups = [None, None];
    }

    /// Drops the bind groups, for a new source texture.
    pub fn unbind(&mut self) {
        self.bind_groups = [None, None];
    }

    /// End of the planes in the readback buffer.
    pub fn end(&self) -> u64 {
        self.end
    }

    pub fn is_bound(&self, input: bool) -> bool {
        self.bind_groups[input as usize].is_some()
    }

    /// Makes the passes read `source`: the RGBA result, or the input when `input`.
    pub fn bind(&mut self, device: &wgpu::Device, conv: &Converter, source: &wgpu::Texture, input: bool) {
        if !input {
            self.planar = None;
        }
        let view = source.create_view(&wgpu::TextureViewDescriptor { mip_level_count: Some(1), ..Default::default() });
        self.bind_groups[input as usize] = Some(
            self.planes
                .iter()
                .map(|p| {
                    device.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: Some("gpufx convert out"),
                        layout: &conv.from_rgba_layout,
                        entries: &[
                            wgpu::BindGroupEntry { binding: 0, resource: p.uniform.as_entire_binding() },
                            wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&view) },
                            wgpu::BindGroupEntry {
                                binding: 2,
                                resource: p.words.as_ref().expect("words set before binding").as_entire_binding(),
                            },
                        ],
                    })
                })
                .collect(),
        );
    }

    /// Makes the passes of the effect output read `sources`, the plane textures of the
    /// format's own [`PixelFormat::pixel_layout`], and pack their codes as they are.
    pub fn bind_planes(&mut self, device: &wgpu::Device, conv: &Converter, sources: &[wgpu::Texture]) -> Result<(), Error> {
        let (pipeline, layout) = conv.planes_out(self.key.0.pixel_layout(), None)?;
        let views: Vec<wgpu::TextureView> = sources.iter().map(|t| t.create_view(&Default::default())).collect();
        let groups = self
            .planes
            .iter()
            .map(|p| {
                let words = p.words.as_ref().expect("words set before binding").as_entire_binding();
                let entries = planes_out_group(&p.uniform, &views, words);
                device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("gpufx frame planes out"),
                    layout: &layout,
                    entries: &entries,
                })
            })
            .collect();
        self.bind_groups[0] = Some(groups);
        self.planar = Some(pipeline);
        Ok(())
    }

    /// Whether the effect output is packed from plane textures.
    pub fn is_planar(&self) -> bool {
        self.planar.is_some()
    }

    pub fn encode(&self, queue: &wgpu::Queue, conv: &Converter, cpass: &mut wgpu::ComputePass, color: &ColorInfo, input: bool) {
        let (format, w, h) = self.key;
        let groups = self.bind_groups[input as usize].as_ref().expect("bound before use");
        let pipeline = match (&self.planar, input) {
            (Some(p), false) => p,
            _ => &conv.from_rgba,
        };
        cpass.set_pipeline(pipeline);
        for (i, (p, bg)) in self.planes.iter().zip(groups).enumerate() {
            queue.write_buffer(&p.uniform, 0, &uniform(format, w, h, color, Some(i)));
            cpass.set_bind_group(0, bg, &[]);
            cpass.dispatch_workgroups(p.row_words.div_ceil(WORKGROUP), p.rows.div_ceil(WORKGROUP), 1);
        }
    }

    /// Copies the encoded planes into the shared readback buffer; after the compute pass.
    pub fn copy(&self, enc: &mut wgpu::CommandEncoder, readback: &wgpu::Buffer) {
        for p in &self.planes {
            enc.copy_buffer_to_buffer(p.words.as_ref().expect("words set before use"), 0, readback, p.offset, p.size);
        }
    }

    /// Copies every plane from the mapped readback buffer into `out`.
    fn read(&self, mapped: &[u8], out: &mut FrameMut) {
        for (i, p) in self.planes.iter().enumerate() {
            let (row, stride) = (p.row_bytes as usize, out.strides[i] as usize);
            for y in 0..p.rows as usize {
                let src = &mapped[p.offset as usize + y * p.row_words as usize * 4..][..row];
                out.planes[i][y * stride..][..row].copy_from_slice(src);
            }
        }
    }
}

/// The pool key of the one mappable buffer every output of a graph is read back through.
pub(crate) fn readback_key(size: u64) -> PoolKey {
    PoolKey::Buffer { size, usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ }
}

/// Waits for the GPU, maps `readback` once and copies every output into its frame.
pub(crate) fn read_outputs(
    device: &wgpu::Device,
    readback: &wgpu::Buffer,
    slots: &[OutputSlot],
    outs: &mut [FrameMut],
) -> Result<(), Error> {
    let slice = readback.slice(..);
    let (tx, rx) = std::sync::mpsc::channel();
    slice.map_async(wgpu::MapMode::Read, move |r| {
        let _ = tx.send(r);
    });
    device.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| Error::Gpu(e.to_string()))?;
    rx.recv().map_err(|e| Error::Gpu(e.to_string()))?.map_err(|e| Error::Gpu(e.to_string()))?;
    {
        let mapped = slice.get_mapped_range().map_err(|e| Error::Gpu(e.to_string()))?;
        for (slot, out) in slots.iter().zip(outs.iter_mut()) {
            slot.read(&mapped, out);
        }
    }
    readback.unmap();
    Ok(())
}

/// A layout pass: (from, to, deep, 16-bit planes).
type LayoutPass = (PixelLayout, PixelLayout, bool, bool);

/// Size of the `LayoutConv` uniform struct of convert_layout.wgsl.
const LAYOUT_UNIFORM_SIZE: u64 = 48;
/// Binding of the first destination texture of a layout pass; the sources start at 1.
const LAYOUT_FIRST_DST: u32 = 8;

/// The WGSL name of the texture of `plane` in a layout pass: `src_y`, `dst_rgba`, ...
fn layout_var(side: &str, plane: Plane) -> String {
    format!("{side}_{}", plane.suffix())
}

/// convert_layout.wgsl with the bindings and the load and store code of one layout pass.
fn layout_source(from: PixelLayout, to: PixelLayout, deep: bool, f16: bool) -> String {
    let mut s = String::new();
    for (b, &plane) in from.planes().iter().enumerate() {
        s.push_str(&format!("@group(0) @binding({}) var {}: texture_2d<f32>;\n", b + 1, layout_var("src", plane)));
    }
    for (b, &plane) in to.planes().iter().enumerate() {
        let format = crate::runtime::wgsl_format(crate::runtime::plane_format(plane, deep, f16));
        s.push_str(&format!(
            "@group(0) @binding({}) var {}: texture_storage_2d<{format}, write>;\n",
            LAYOUT_FIRST_DST + b as u32,
            layout_var("dst", plane)
        ));
    }
    let load = match from {
        PixelLayout::Rgba => "return to_codes(textureLoad(src_rgba, p, 0));".to_string(),
        PixelLayout::Y => "return vec4f(textureLoad(src_y, p, 0).r, NEUTRAL, NEUTRAL, 1.0);".to_string(),
        _ => format!(
            "let uv = textureLoad(src_uv, p / vec2i(lc.src_scale), 0).rg;\n    return vec4f(textureLoad(src_y, p, 0).r, uv, {});",
            if from.planes().contains(&Plane::A) { "textureLoad(src_a, p, 0).r" } else { "1.0" }
        ),
    };
    s.push_str(&format!("fn load_src(p: vec2i) -> vec4f {{\n    {load}\n}}\n"));
    let mut store = String::new();
    for &plane in to.planes() {
        store.push_str(match plane {
            Plane::Rgba => "    textureStore(dst_rgba, p, from_codes(v));\n",
            Plane::Y => "    textureStore(dst_y, p, vec4f(v.x, 0.0, 0.0, 1.0));\n",
            Plane::A => "    textureStore(dst_a, p, vec4f(v.w, 0.0, 0.0, 1.0));\n",
            Plane::Uv => "    store_uv(p, v.yz);\n",
        });
    }
    if to.planes().contains(&Plane::Uv) {
        s.push_str(
            "// The mean chroma of the luma pixels of a UV texel, written by its first pixel, whose\n\
             // chroma `c` the caller loaded already.\n\
             fn store_uv(p: vec2i, c: vec2f) {\n    \
             let s = vec2i(lc.dst_scale);\n    \
             if (any(p % s != vec2i(0))) { return; }\n    \
             var sum = c;\n    var n = 1.0;\n    \
             for (var dy = 0; dy < s.y; dy++) {\n        for (var dx = 0; dx < s.x; dx++) {\n            \
             let q = p + vec2i(dx, dy);\n            \
             if ((dx != 0 || dy != 0) && all(q < vec2i(lc.size))) { sum += load_src(q).yz; n += 1.0; }\n        }\n    }\n    \
             textureStore(dst_uv, p / s, vec4f(sum / n, 0.0, 1.0));\n}\n",
        );
    }
    s.push_str(&format!(
        "@compute @workgroup_size({WORKGROUP}, {WORKGROUP})\nfn main(@builtin(global_invocation_id) id: vec3u) {{\n    \
         if (any(id.xy >= lc.size)) {{ return; }}\n    let p = vec2i(id.xy);\n    let v = load_src(p);\n{store}}}\n"
    ));
    format!("{}{s}", include_str!("convert_layout.wgsl"))
}

impl Converter {
    /// The pass converting textures of layout `from` into `to` (see [`LayoutConvert`]).
    fn layout_pass(&self, key: LayoutPass) -> (wgpu::ComputePipeline, wgpu::BindGroupLayout) {
        let mut passes = self.layouts.lock().unwrap_or_else(|e| e.into_inner());
        passes
            .entry(key)
            .or_insert_with(|| {
                let (from, to, deep, f16) = key;
                let source = layout_source(from, to, deep, f16);
                let mut entries = vec![entry(0, UNIFORM)];
                for b in 0..from.planes().len() {
                    // textureLoad only: 32-bit float planes cannot be filtered.
                    entries.push(entry(b as u32 + 1, texture(wgpu::TextureSampleType::Float { filterable: false })));
                }
                for (b, &plane) in to.planes().iter().enumerate() {
                    entries.push(entry(
                        LAYOUT_FIRST_DST + b as u32,
                        wgpu::BindingType::StorageTexture {
                            access: wgpu::StorageTextureAccess::WriteOnly,
                            format: crate::runtime::plane_format(plane, deep, f16),
                            view_dimension: wgpu::TextureViewDimension::D2,
                        },
                    ));
                }
                let label = "gpufx layout convert";
                let module = naga::front::wgsl::parse_str(&source).unwrap_or_else(|e| panic!("{label}: {}", e.emit_to_string(&source)));
                let layout =
                    self.device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some(label), entries: &entries });
                let pipeline_layout = self.device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                    label: Some(label),
                    bind_group_layouts: &[Some(&layout)],
                    immediate_size: 0,
                });
                let pipeline = ShaderCache::compute_pipeline(
                    self.cache.as_deref(),
                    &self.device,
                    &PipelineDesc { label, layout: &pipeline_layout, entries: &entries, entry: "main" },
                    module,
                    &["convert layout", "main", &source],
                    None,
                );
                (pipeline, layout)
            })
            .clone()
    }
}

/// A pass converting the textures of an effect output or an input pad from one
/// `pixel_layout` into another, on the GPU: RGBA (straight alpha, as effects work) to and
/// from Y'CbCr planes holding the stored codes of a frame (0..1, in the matrix and range
/// of the graph's first input), and between plane layouts without going through RGBA.
/// Chroma is the mean of the pixels of a UV texel when subsampled and the nearest UV
/// texel when upsampled; a missing alpha is 1, a missing chroma neutral. One thread per
/// luma pixel, at the size of Y.
pub(crate) struct LayoutConvert {
    pipeline: wgpu::ComputePipeline,
    group: wgpu::BindGroup,
    uniform: wgpu::Buffer,
    from: PixelLayout,
    to: PixelLayout,
    size: (u32, u32),
}

impl LayoutConvert {
    /// `src` and `dst` hold the planes of `layouts` (from, to), in their order, for a luma `size`.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        device: &wgpu::Device,
        conv: &Converter,
        layouts: (PixelLayout, PixelLayout),
        src: &[wgpu::Texture],
        dst: &[wgpu::Texture],
        size: (u32, u32),
        deep: bool,
        f16: bool,
    ) -> Self {
        let (from, to) = layouts;
        let (pipeline, layout) = conv.layout_pass((from, to, deep, f16));
        let uniform = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx layout convert"),
            size: LAYOUT_UNIFORM_SIZE,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let level0 = |t: &wgpu::Texture| t.create_view(&wgpu::TextureViewDescriptor { mip_level_count: Some(1), ..Default::default() });
        let views: Vec<wgpu::TextureView> = src.iter().chain(dst).map(level0).collect();
        let mut entries = vec![wgpu::BindGroupEntry { binding: 0, resource: uniform.as_entire_binding() }];
        for (b, v) in views.iter().enumerate() {
            let binding = if b < src.len() { b as u32 + 1 } else { LAYOUT_FIRST_DST + (b - src.len()) as u32 };
            entries.push(wgpu::BindGroupEntry { binding, resource: wgpu::BindingResource::TextureView(v) });
        }
        let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("gpufx layout convert"),
            layout: &layout,
            entries: &entries,
        });
        LayoutConvert { pipeline, group, uniform, from, to, size }
    }

    /// Records the pass, with the matrix and range of `color`.
    pub fn encode(&self, queue: &wgpu::Queue, color: &ColorInfo, cpass: &mut wgpu::ComputePass) {
        let (kr, kb) = color.matrix.kr_kb();
        let full = (color.range == crate::frame::Range::Full) as u32;
        let (fx, fy) = self.from.chroma_scale();
        let (tx, ty) = self.to.chroma_scale();
        let words: [u32; 12] = [kr.to_bits(), kb.to_bits(), full, 0, self.size.0, self.size.1, fx, fy, tx, ty, 0, 0];
        let bytes: Vec<u8> = words.iter().flat_map(|w| w.to_le_bytes()).collect();
        queue.write_buffer(&self.uniform, 0, &bytes);
        cpass.set_pipeline(&self.pipeline);
        cpass.set_bind_group(0, &self.group, &[]);
        cpass.dispatch_workgroups(self.size.0.div_ceil(WORKGROUP), self.size.1.div_ceil(WORKGROUP), 1);
    }
}
