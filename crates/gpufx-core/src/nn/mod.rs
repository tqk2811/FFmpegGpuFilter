//! gpufx-nn: runs a neural network package (`docs/NN_MODEL_FORMAT.md`) with gpufx's own WGSL compute
//! shaders. Nothing in here knows a particular model: [`NnModel`] holds the graph and its weights on the GPU,
//! [`NnPlan`] is that graph laid out for one set of input sizes (tensor buffers, one dispatch list), and
//! [`FrameInterp`] drives a `frame_interp` package (RIFE) as its `io.json` describes.
//!
//! The CPU reference executor of `gpufx-nnconv` (`src/reference.rs`) pins the semantics of every op; the
//! shaders follow it (same tap rules, same summation order where it matters).

mod interp;
mod kernels;
pub mod model;
mod plan;

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

pub use interp::FrameInterp;
pub use plan::{NnPlan, Profile, TensorView};

use crate::runtime::GpuContext;
use crate::Error;
use kernels::{ConvConfig, ConvShape, Fixed, Kernel, Kernels};
use model::{BlobRef, Dtype, Model, OpKind};

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

impl NnModel {
    /// Loads a package from a `.zip` or a directory (`model.json`, `weights.bin`, optional `io.json`).
    pub fn load(ctx: Arc<GpuContext>, path: impl AsRef<Path>) -> Result<Self, Error> {
        let files = crate::package::read_files(path.as_ref())?;
        let get = |n: &str| files.get(n).map(Vec::as_slice);
        let model = get("model.json").ok_or_else(|| Error::Package("missing model.json".into()))?;
        let weights = get("weights.bin").ok_or_else(|| Error::Package("missing weights.bin".into()))?;
        Self::from_parts(ctx, model, weights, get("io.json"))
    }

    pub fn from_parts(ctx: Arc<GpuContext>, model_json: &[u8], weights: &[u8], io_json: Option<&[u8]>) -> Result<Self, Error> {
        let model = Model::parse(model_json)?;
        let io = match io_json {
            Some(b) => serde_json::from_slice(b).map_err(|e| Error::Package(format!("io.json: {e}")))?,
            None => serde_json::Value::Null,
        };
        let device = &ctx.device;
        let kernels = Kernels::new(device);
        let mut blob: Vec<f32> = Vec::new();
        let mut conv_weights = HashMap::new();
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
                    conv_weights.insert(i, push_conv_weights(&mut blob, c, &w, &b, ocb));
                    kernel
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
        let limits = device.limits();
        let max_bytes = limits.max_storage_buffer_binding_size.min(limits.max_buffer_size);
        if bytes.len() as u64 > max_bytes {
            return Err(Error::Gpu(format!(
                "the weights take {} bytes on the GPU, above the device limit of {max_bytes} bytes for one storage buffer",
                bytes.len()
            )));
        }
        let buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx nn weights"),
            size: bytes.len() as u64,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        ctx.queue.write_buffer(&buffer, 0, &bytes);
        Ok(NnModel { ctx, model, io, weights: buffer, conv_weights, kernels, weight_bytes: bytes.len() as u64 })
    }

    pub fn name(&self) -> &str {
        &self.model.name
    }

    /// Names of the input tensors.
    pub fn inputs(&self) -> &[String] {
        &self.model.inputs
    }

    pub fn outputs(&self) -> &[String] {
        &self.model.outputs
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
