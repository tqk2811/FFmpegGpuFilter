//! gpufx-nn: runs a neural network package (`docs/NN_MODEL_FORMAT.md`) with gpufx's own WGSL compute
//! shaders. Nothing in here knows a particular model: [`NnModel`] holds the graph and its weights on the GPU,
//! [`NnPlan`] is that graph laid out for one set of input sizes (tensor buffers, one dispatch list), and
//! [`FrameInterp`] drives a `frame_interp` package (RIFE) as its `io.json` describes, [`FrameUpscale`] a
//! `super_resolution` package (Real-ESRGAN), in tiles.
//!
//! The CPU reference executor of `gpufx-nnconv` (`src/reference.rs`) pins the semantics of every op; the
//! shaders follow it (same tap rules, same summation order where it matters).

mod frames;
mod interp;
mod kernels;
pub mod model;
mod plan;
mod upscale;

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

pub use frames::{InterpFrames, UpscaleFrames};
pub use interp::FrameInterp;
pub use plan::{NnPlan, Profile, TensorView};
pub use upscale::{FrameUpscale, TileLayout, UpscaleOptions, DEFAULT_TENSOR_BYTES};

use crate::runtime::GpuContext;
use crate::Error;
use kernels::{ConvConfig, ConvShape, CoopConfig, Fixed, Kernel, Kernels};
use model::{BlobRef, Dtype, Model, OpKind};

/// The arithmetic of the convolutions.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Precision {
    /// f32 everywhere.
    #[default]
    F32,
    /// Convolutions in f16 (input tile, weights and sums; bias and activations in f32) when the device has
    /// `SHADER_F16`, else f32. Tensors stay f32. Real-ESRGAN keeps ~55 dB against the f32 CPU reference.
    Auto,
}

/// A loaded package: graph, weights uploaded once (as f32, re-laid out for the convolution kernels) and the
/// pipelines its ops need.
pub struct NnModel {
    pub(crate) ctx: Arc<GpuContext>,
    pub(crate) model: Model,
    /// `io.json` as given, `Null` when the package has none.
    pub io: serde_json::Value,
    pub(crate) weights: wgpu::Buffer,
    /// Per conv/deconv op index: offset of its weights in `vec4` units and of its bias in `f32` units.
    pub(crate) conv_weights: HashMap<usize, (u32, u32)>,
    /// Per prelu op index: offset of its slopes in `f32` units and their count.
    pub(crate) slopes: HashMap<usize, (u32, u32)>,
    /// The conv ops that run the tensor core kernel: their weights are in `weights_h` (offset in f16 units).
    pub(crate) coop_ops: std::collections::HashSet<usize>,
    /// The f16 weights of the tensor core kernels (a placeholder when none runs one).
    pub(crate) weights_h: Option<wgpu::Buffer>,
    pub(crate) kernels: Kernels,
    weight_bytes: u64,
}

fn half_to_f32(h: u16) -> f32 {
    let sign = ((h >> 15) & 1) as u32;
    let exp = ((h >> 10) & 0x1f) as u32;
    let frac = (h & 0x3ff) as u32;
    let bits = if exp == 0 {
        if frac == 0 {
            sign << 31
        } else {
            let mut e: i32 = 127 - 15 + 1;
            let mut f = frac;
            while f & 0x400 == 0 {
                f <<= 1;
                e -= 1;
            }
            (sign << 31) | ((e as u32) << 23) | ((f & 0x3ff) << 13)
        }
    } else if exp == 0x1f {
        (sign << 31) | (0xff << 23) | (frac << 13)
    } else {
        (sign << 31) | ((exp + 127 - 15) << 23) | (frac << 13)
    };
    f32::from_bits(bits)
}

fn read_blob(b: &BlobRef, weights: &[u8]) -> Result<Vec<f32>, Error> {
    let size = if b.dtype == Dtype::F16 { 2 } else { 4 };
    let bytes = usize::try_from(b.offset)
        .ok()
        .and_then(|o| weights.get(o..))
        .and_then(|w| w.get(..(b.count as usize).checked_mul(size)?))
        .ok_or_else(|| Error::Package(format!("blob at {} of {} elements is outside weights.bin", b.offset, b.count)))?;
    Ok(if size == 2 {
        bytes.as_chunks::<2>().0.iter().map(|c| half_to_f32(u16::from_le_bytes(*c))).collect()
    } else {
        bytes.as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect()
    })
}

/// Refuses D3D12 devices that compile WGSL with FXC. wgpu-hal 30 uses DXC when `dxcompiler.dll` loads (its
/// `Dx12Compiler::Auto`, which gpufx keeps unless `WGPU_DX12_COMPILER` says otherwise) and falls back to FXC.
/// FXC cannot take the nn shaders: it rejects the barriers of the convolution loops (X3663) and spends many
/// minutes on one transposed convolution, burning CPU, so a model would seem to hang on load.
fn check_shader_compiler(info: &wgpu::AdapterInfo) -> Result<(), Error> {
    if info.backend != wgpu::Backend::Dx12 {
        return Ok(());
    }
    if uses_fxc(std::env::var("WGPU_DX12_COMPILER").ok().as_deref(), dxc_loads) {
        return Err(Error::Gpu(
            "gpufx-nn on D3D12 needs DXC: put dxcompiler.dll on the DLL search path (the win64 bundle ships it in \
             bin/) and do not set WGPU_DX12_COMPILER=fxc; FXC cannot compile the nn shaders"
                .into(),
        ));
    }
    Ok(())
}

/// Whether wgpu compiles with FXC given `WGPU_DX12_COMPILER` (`forced`) and whether `dxcompiler.dll` loads.
fn uses_fxc(forced: Option<&str>, dxc_loads: impl FnOnce() -> bool) -> bool {
    match forced.map(str::to_ascii_lowercase).as_deref() {
        Some("fxc") => true,
        Some("dxc" | "dynamicdxc" | "staticdxc") => false,
        // Auto (unset, or a value wgpu ignores): the same DLL lookup as wgpu's.
        _ => !dxc_loads(),
    }
}

#[cfg(windows)]
fn dxc_loads() -> bool {
    crate::dxil::DxcCompiler::get().is_some()
}

#[cfg(not(windows))]
fn dxc_loads() -> bool {
    false
}

/// The directory of the variant of `scale` in a bundle's `package.json`, checked to be a simple name.
fn bundle_variant(package_json: &[u8], scale: Option<u32>) -> Result<String, Error> {
    let bad = |m: String| Error::Package(format!("package.json: {m}"));
    let v: serde_json::Value = serde_json::from_slice(package_json).map_err(|e| bad(e.to_string()))?;
    if v["format"] != "gpufx-nn-bundle" || v["version"] != 1 {
        return Err(bad("not a gpufx-nn-bundle version 1".into()));
    }
    let variants = v["variants"].as_array().filter(|a| !a.is_empty()).ok_or_else(|| bad("no variants".into()))?;
    let mut scales = Vec::new();
    for x in variants {
        let (Some(s), Some(dir)) = (x["scale"].as_u64(), x["dir"].as_str()) else {
            return Err(bad("a variant needs an integer scale and a dir".into()));
        };
        scales.push(s.to_string());
        if Some(s) == scale.map(u64::from) {
            if dir.is_empty() || dir == "." || dir == ".." || dir.contains(['/', '\\', ':']) {
                return Err(bad(format!("variant directory \"{dir}\" must be a simple name")));
            }
            return Ok(dir.to_string());
        }
    }
    let list = scales.join(", ");
    Err(Error::Package(match scale {
        Some(s) => format!("the bundle has no variant of scale {s} (available: {list})"),
        None => format!("the model is a bundle: choose a scale (available: {list})"),
    }))
}

pub(crate) fn conv_shape(c: &model::ConvParams) -> ConvShape {
    ConvShape { kh: c.kernel[0], kw: c.kernel[1], sh: c.stride[0], sw: c.stride[1], dh: c.dilation[0], dw: c.dilation[1] }
}

/// Appends `w` (`[out][in][kh][kw]`) laid out as `[out / ocb][in][kh * kw][ocb]` (zero filled past `out`), then
/// the bias padded to a multiple of `ocb`. Returns the offsets (`vec4` units, `f32` units).
fn push_conv_weights(blob: &mut Vec<f32>, c: &model::ConvParams, w: &[f32], bias: &[f32], ocb: u32) -> (u32, u32) {
    let (cin, cout, k) = (c.in_channels as usize, c.out_channels as usize, (c.kernel[0] * c.kernel[1]) as usize);
    let ocb = ocb as usize;
    let blocks = cout.div_ceil(ocb);
    let w_off = blob.len();
    blob.resize(w_off + blocks * cin * k * ocb, 0.0);
    for co in 0..cout {
        let (cb, o) = (co / ocb, co % ocb);
        for ci in 0..cin {
            for kk in 0..k {
                blob[w_off + ((cb * cin + ci) * k + kk) * ocb + o] = w[(co * cin + ci) * k + kk];
            }
        }
    }
    let b_off = blob.len();
    blob.extend_from_slice(bias);
    blob.resize(b_off + blocks * ocb, 0.0);
    // keep the next weights 16-byte aligned
    blob.resize(blob.len().div_ceil(4) * 4, 0.0);
    ((w_off / 4) as u32, b_off as u32)
}

/// f32 to f16 bits, rounding to nearest even (overflow to infinity, subnormals kept).
fn f32_to_half(v: f32) -> u16 {
    let b = v.to_bits();
    let sign = ((b >> 16) & 0x8000) as u16;
    let exp = ((b >> 23) & 0xff) as i32;
    let man = b & 0x7f_ffff;
    if exp == 0xff {
        return sign | 0x7c00 | if man != 0 { 0x200 } else { 0 };
    }
    let e = exp - 127 + 15;
    if e >= 0x1f {
        return sign | 0x7c00;
    }
    // the mantissa with its implicit bit, shifted to f16 precision (subnormals shift further)
    let (m, shift) = if e <= 0 { (man | 0x80_0000, (14 - e) as u32) } else { (man, 13) };
    if shift > 24 {
        return sign;
    }
    let half = 1u32 << (shift - 1);
    let rest = m & ((1u32 << shift) - 1);
    let mut r = m >> shift;
    if rest > half || (rest == half && r & 1 == 1) {
        r += 1;
    }
    // a carry out of the mantissa moves to the exponent, as the bit layout makes it
    sign | if e <= 0 { r as u16 } else { (((e as u32) << 10) + r) as u16 }
}

/// Appends `w` (`[out][in][kh][kw]`) for the tensor core kernel as f16 laid out `[kh * kw][in padded to 16][out
/// padded to 16]` (zero filled), its bias to `blob` padded to a multiple of 16. Returns the offsets (f16 units,
/// a multiple of 16 so loads stay aligned; `f32` units).
fn push_coop_weights(wh: &mut Vec<u16>, blob: &mut Vec<f32>, c: &model::ConvParams, w: &[f32], bias: &[f32]) -> (u32, u32) {
    let (cin, cout, k) = (c.in_channels as usize, c.out_channels as usize, (c.kernel[0] * c.kernel[1]) as usize);
    let (cinp, coutp) = (cin.div_ceil(16) * 16, cout.div_ceil(16) * 16);
    let w_off = wh.len();
    wh.resize(w_off + k * cinp * coutp, 0);
    for co in 0..cout {
        for ci in 0..cin {
            for kk in 0..k {
                wh[w_off + (kk * cinp + ci) * coutp + co] = f32_to_half(w[(co * cin + ci) * k + kk]);
            }
        }
    }
    let b_off = blob.len();
    blob.extend_from_slice(bias);
    blob.resize(b_off + coutp, 0.0);
    (w_off as u32, b_off as u32)
}

impl NnModel {
    /// Loads a package from a `.zip` or a directory (`model.json`, `weights.bin`, optional `io.json`), computing in
    /// f32. A bundle (`package.json` with several variants) needs [`NnModel::load_with`].
    pub fn load(ctx: Arc<GpuContext>, path: impl AsRef<Path>) -> Result<Self, Error> {
        Self::load_with(ctx, path, None, Precision::F32)
    }

    /// Loads a package, or the variant of a bundle of the given `scale` (`docs/NN_MODEL_FORMAT.md`, "Bundles").
    /// A single model package ignores `scale`; a bundle without one fails, listing its scales.
    pub fn load_with(ctx: Arc<GpuContext>, path: impl AsRef<Path>, scale: Option<u32>, precision: Precision) -> Result<Self, Error> {
        let files = crate::package::read_files(path.as_ref())?;
        let dir = match files.get("package.json") {
            // a bundle given to a filter that takes no scale says which filter takes it
            Some(b) => format!(
                "{}/",
                bundle_variant(b, scale).map_err(|e| match (e, scale, crate::used_for::describe(&files)) {
                    (Error::Package(m), None, Some(kind)) => Error::Package(format!("{m}; {kind}")),
                    (e, ..) => e,
                })?
            ),
            None => String::new(),
        };
        let get = |n: &str| files.get(&format!("{dir}{n}")).map(Vec::as_slice);
        let model = match get("model.json") {
            Some(m) => m,
            None if dir.is_empty() => return Err(crate::used_for::wrong_kind(&files, "model.json")),
            None => return Err(Error::Package(format!("missing {dir}model.json"))),
        };
        let weights = get("weights.bin").ok_or_else(|| Error::Package(format!("missing {dir}weights.bin")))?;
        Self::from_parts_with(ctx, model, weights, get("io.json"), precision)
    }

    /// [`NnModel::from_parts_with`] in f32.
    pub fn from_parts(ctx: Arc<GpuContext>, model_json: &[u8], weights: &[u8], io_json: Option<&[u8]>) -> Result<Self, Error> {
        Self::from_parts_with(ctx, model_json, weights, io_json, Precision::F32)
    }

    /// A package from the bytes of its files.
    pub fn from_parts_with(
        ctx: Arc<GpuContext>,
        model_json: &[u8],
        weights: &[u8],
        io_json: Option<&[u8]>,
        precision: Precision,
    ) -> Result<Self, Error> {
        let model = Model::parse(model_json)?;
        let io = match io_json {
            Some(b) => serde_json::from_slice(b).map_err(|e| Error::Package(format!("io.json: {e}")))?,
            None => serde_json::Value::Null,
        };
        check_shader_compiler(&ctx.info)?;
        let device = &ctx.device;
        let f16 = precision == Precision::Auto && device.features().contains(wgpu::Features::SHADER_F16);
        let coop = f16 && ctx.coop_f16 && kernels::coop_available(device, &ctx.info);
        let kernels = Kernels::new(device, ctx.shader_cache.clone(), f16, coop);
        let mut blob: Vec<f32> = Vec::new();
        let mut wh: Vec<u16> = Vec::new();
        let mut coop_ops = std::collections::HashSet::new();
        let mut conv_weights = HashMap::new();
        let mut slopes = HashMap::new();
        for (i, op) in model.ops.iter().enumerate() {
            let fail = |e: Error| Error::Package(format!("op {}: {e}", op.name));
            let kernel = match &op.kind {
                OpKind::Conv2d(c) | OpKind::Deconv2d(c) => {
                    let shape = conv_shape(c);
                    let (kernel, ocb) = if matches!(op.kind, OpKind::Conv2d(_)) {
                        let ocb = ConvConfig::ocb(c.out_channels);
                        let cfg = ConvConfig::choose(&shape, ocb, 1, 1, 1)
                            .ok_or_else(|| Error::Unsupported(format!("op {}: kernel {:?} is too large", op.name, c.kernel)))?;
                        (Kernel::Conv(shape, cfg), ocb)
                    } else {
                        (Kernel::Deconv(shape, c.pad[0] % shape.sh, c.pad[1] % shape.sw), kernels::DECONV_OCB)
                    };
                    let w = read_blob(&c.weight, weights).map_err(fail)?;
                    let b = match &c.bias {
                        Some(b) => read_blob(b, weights).map_err(fail)?,
                        None => vec![0.0; c.out_channels as usize],
                    };
                    if coop && matches!(op.kind, OpKind::Conv2d(_)) && CoopConfig::supports(&shape) {
                        conv_weights.insert(i, push_coop_weights(&mut wh, &mut blob, c, &w, &b));
                        coop_ops.insert(i);
                    } else {
                        conv_weights.insert(i, push_conv_weights(&mut blob, c, &w, &b, ocb));
                    }
                    kernel
                }
                OpKind::Prelu { slope } => {
                    // a convolution's output channels are known now; other inputs are checked by the plan
                    let producer = model.ops[..i].iter().rev().find(|o| op.inputs.first() == Some(&o.output));
                    if let Some(OpKind::Conv2d(c) | OpKind::Deconv2d(c)) = producer.map(|o| &o.kind) {
                        if slope.count != 1 && slope.count != c.out_channels as u64 {
                            return Err(fail(Error::Package(format!(
                                "prelu slope has {} values, expected 1 or {} (the channels of its input)",
                                slope.count, c.out_channels
                            ))));
                        }
                    }
                    let s = read_blob(slope, weights).map_err(fail)?;
                    let off = blob.len();
                    blob.extend_from_slice(&s);
                    // the conv epilogue reads 4 slopes at a time; keep the next weights 16-byte aligned
                    blob.resize(blob.len().div_ceil(4) * 4, 0.0);
                    slopes.insert(i, (off as u32, s.len() as u32));
                    Kernel::Fixed(Fixed::Ew)
                }
                OpKind::Resize { .. } => Kernel::Fixed(Fixed::Resize),
                OpKind::Warp => Kernel::Fixed(Fixed::Warp),
                OpKind::PixelShuffle(_) => Kernel::Fixed(Fixed::PixelShuffle),
                OpKind::Eltwise { coeffs, .. } => {
                    let n = op.inputs.len();
                    if n == 0 || n > 2 {
                        return Err(Error::Unsupported(format!("op {}: eltwise of {n} inputs (1 or 2 supported)", op.name)));
                    }
                    if coeffs.as_ref().is_some_and(|c| c.len() != n) {
                        return Err(Error::Package(format!("op {}: eltwise coeffs and inputs differ in count", op.name)));
                    }
                    Kernel::Fixed(Fixed::Ew)
                }
                _ => Kernel::Fixed(Fixed::Ew),
            };
            // compiled now, so a broken shader fails the load; convolutions get the tile of each output size
            // when a plan is made
            if !matches!(kernel, Kernel::Conv(..)) {
                kernels.get(device, kernel);
            }
        }
        // ew also fills and copies (concat, timestep planes).
        kernels.get(device, Kernel::Fixed(Fixed::Ew));
        if blob.is_empty() {
            blob.resize(4, 0.0);
        }
        let bytes: Vec<u8> = blob.iter().flat_map(|v| v.to_le_bytes()).collect();
        if wh.is_empty() {
            wh.resize(8, 0);
        }
        let bytes_h: Vec<u8> = wh.iter().flat_map(|v| v.to_le_bytes()).collect();
        let limits = device.limits();
        let max_bytes = limits.max_storage_buffer_binding_size.min(limits.max_buffer_size);
        if bytes.len().max(bytes_h.len()) as u64 > max_bytes {
            return Err(Error::Gpu(format!(
                "the weights take {} bytes on the GPU, above the device limit of {max_bytes} bytes for one storage buffer",
                bytes.len().max(bytes_h.len())
            )));
        }
        let buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx nn weights"),
            size: bytes.len() as u64,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        ctx.queue.write_buffer(&buffer, 0, &bytes);
        let weights_h = coop.then(|| {
            let b = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("gpufx nn weights f16"),
                size: bytes_h.len() as u64,
                usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            ctx.queue.write_buffer(&b, 0, &bytes_h);
            b
        });
        let weight_bytes = bytes.len() as u64 + weights_h.as_ref().map_or(0, |b| b.size());
        Ok(NnModel { ctx, model, io, weights: buffer, conv_weights, slopes, coop_ops, weights_h, kernels, weight_bytes })
    }

    pub fn name(&self) -> &str {
        &self.model.name
    }

    /// The filters the model is for (`used_for` of `model.json`).
    pub fn used_for(&self) -> &[String] {
        &self.model.used_for
    }

    /// Names of the input tensors.
    pub fn inputs(&self) -> &[String] {
        &self.model.inputs
    }

    pub fn outputs(&self) -> &[String] {
        &self.model.outputs
    }

    /// Whether the convolutions compute in f16 ([`Precision::Auto`] on a device with `SHADER_F16`).
    pub fn uses_f16(&self) -> bool {
        self.kernels.f16
    }

    /// How many convolutions run the tensor core kernel (Vulkan devices with cooperative matrices, f16).
    pub fn coop_convs(&self) -> usize {
        self.coop_ops.len()
    }

    /// Bytes of the weights buffer on the GPU.
    pub fn weight_bytes(&self) -> u64 {
        self.weight_bytes
    }

    pub fn context(&self) -> &Arc<GpuContext> {
        &self.ctx
    }

    /// Lays the graph out for inputs of the given `C x H x W` shapes (every model input).
    pub fn plan(&self, inputs: &[(&str, [u32; 3])]) -> Result<NnPlan, Error> {
        plan::build(self, inputs)
    }
}

#[cfg(test)]
mod tests {
    use super::{f32_to_half, uses_fxc};

    /// The f16 weights of the tensor core kernels round to nearest even, keep subnormals, NaN and inf.
    #[test]
    fn f32_to_half_rounds_like_ieee() {
        for (v, want) in [
            (0.0f32, 0x0000u16),
            (-0.0, 0x8000),
            (1.0, 0x3c00),
            (-2.0, 0xc000),
            (65504.0, 0x7bff),
            (65520.0, 0x7c00),
            (f32::INFINITY, 0x7c00),
            (f32::NEG_INFINITY, 0xfc00),
            (2f32.powi(-24), 0x0001),
            (2f32.powi(-25), 0x0000),
            (2f32.powi(-14), 0x0400),
            (1.0 + 2f32.powi(-11), 0x3c00),
            (1.0 + 3.0 * 2f32.powi(-11), 0x3c02),
        ] {
            assert_eq!(f32_to_half(v), want, "{v:e}");
        }
        assert_eq!(f32_to_half(f32::NAN) & 0x7c00, 0x7c00);
        assert_ne!(f32_to_half(f32::NAN) & 0x03ff, 0);
    }

    /// D3D12 without DXC must be refused up front: FXC hung for minutes on the RIFE deconvolutions.
    #[test]
    fn fxc_is_detected_like_wgpu_picks_it() {
        assert!(uses_fxc(None, || false), "Auto without dxcompiler.dll falls back to FXC");
        assert!(!uses_fxc(None, || true), "Auto with dxcompiler.dll uses DXC");
        assert!(uses_fxc(Some("FXC"), || true), "forced FXC, even with the DLL");
        assert!(!uses_fxc(Some("dxc"), || false));
        assert!(!uses_fxc(Some("DynamicDxc"), || false));
        assert!(uses_fxc(Some("bogus"), || false), "a value wgpu ignores is Auto");
    }
}
