//! `model.json` schema, version 1.

use serde::Serialize;

#[derive(Serialize, Debug)]
pub struct Model {
    pub format: &'static str,
    pub version: u32,
    pub name: String,
    /// The FFmpeg filters the model is for (`--used-for`), checked by [`crate::Package::new`].
    pub used_for: Vec<String>,
    pub source: Source,
    pub weights: WeightsFile,
    pub inputs: Vec<TensorRef>,
    pub outputs: Vec<String>,
    pub ops: Vec<Op>,
}

#[derive(Serialize, Debug)]
pub struct Source {
    pub kind: &'static str,
}

#[derive(Serialize, Debug)]
pub struct WeightsFile {
    pub file: &'static str,
}

#[derive(Serialize, Debug)]
pub struct TensorRef {
    pub name: String,
}

#[derive(Serialize, Debug)]
pub struct Op {
    pub op: &'static str,
    pub name: String,
    pub inputs: Vec<String>,
    pub output: String,
    #[serde(flatten)]
    pub params: OpParams,
}

#[derive(Serialize, Debug)]
#[serde(untagged)]
pub enum OpParams {
    Conv2d(ConvParams),
    Deconv2d(DeconvParams),
    Activation(Activation),
    Binary(BinaryParams),
    Eltwise(EltwiseParams),
    Concat(ConcatParams),
    Slice(SliceParams),
    Resize(ResizeParams),
    PixelShuffle(PixelShuffleParams),
    Warp(WarpParams),
    Prelu(PreluParams),
    Clip(ClipParams),
}

impl Op {
    pub fn new(name: &str, inputs: Vec<String>, output: &str, params: OpParams) -> Self {
        Op { op: params.kind(), name: name.to_string(), inputs, output: output.to_string(), params }
    }
}

impl OpParams {
    pub fn kind(&self) -> &'static str {
        match self {
            OpParams::Conv2d(_) => "conv2d",
            OpParams::Deconv2d(_) => "deconv2d",
            OpParams::Activation(_) => "activation",
            OpParams::Binary(_) => "binary",
            OpParams::Eltwise(_) => "eltwise",
            OpParams::Concat(_) => "concat",
            OpParams::Slice(_) => "slice",
            OpParams::Resize(_) => "resize",
            OpParams::PixelShuffle(_) => "pixel_shuffle",
            OpParams::Warp(_) => "warp",
            OpParams::Prelu(_) => "prelu",
            OpParams::Clip(_) => "clip",
        }
    }
}

#[derive(Serialize, Clone, Copy, PartialEq, Debug)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Activation {
    Relu,
    LeakyRelu { slope: f32 },
    Sigmoid,
}

#[derive(Serialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Dtype {
    F16,
    F32,
}

/// A blob inside weights.bin: byte offset and element count.
#[derive(Serialize, Clone, Copy, Debug)]
pub struct BlobRef {
    pub offset: u64,
    pub count: u64,
    pub dtype: Dtype,
}

#[derive(Serialize, Debug)]
pub struct ConvParams {
    pub in_channels: u32,
    pub out_channels: u32,
    pub kernel: [u32; 2],
    pub stride: [u32; 2],
    pub dilation: [u32; 2],
    /// top, left, bottom, right
    pub pad: [u32; 4],
    pub activation: Option<Activation>,
    pub weight: BlobRef,
    pub bias: Option<BlobRef>,
}

#[derive(Serialize, Debug)]
pub struct DeconvParams {
    pub in_channels: u32,
    pub out_channels: u32,
    pub kernel: [u32; 2],
    pub stride: [u32; 2],
    pub dilation: [u32; 2],
    pub pad: [u32; 4],
    pub output_pad: [u32; 2],
    pub activation: Option<Activation>,
    pub weight: BlobRef,
    pub bias: Option<BlobRef>,
}

#[derive(Serialize, Clone, Copy, Debug)]
#[serde(rename_all = "lowercase")]
pub enum BinaryKind {
    Add,
    Sub,
    Mul,
    Div,
    Max,
    Min,
    Pow,
    Rsub,
    Rdiv,
}

#[derive(Serialize, Debug)]
pub struct BinaryParams {
    pub kind: BinaryKind,
    pub scalar: Option<f32>,
}

#[derive(Serialize, Clone, Copy, Debug)]
#[serde(rename_all = "lowercase")]
pub enum EltwiseKind {
    Prod,
    Sum,
    Max,
}

#[derive(Serialize, Debug)]
pub struct EltwiseParams {
    pub kind: EltwiseKind,
    pub coeffs: Option<Vec<f32>>,
}

#[derive(Serialize, Debug)]
pub struct ConcatParams {
    pub axis: u32,
}

#[derive(Serialize, Debug)]
pub struct SliceParams {
    pub axis: u32,
    pub start: u32,
    /// `null` is "to the end".
    pub end: Option<u32>,
}

#[derive(Serialize, Clone, Copy, Debug)]
#[serde(rename_all = "lowercase")]
pub enum ResizeMode {
    Nearest,
    Bilinear,
    Bicubic,
}

#[derive(Serialize, Debug)]
pub struct ResizeParams {
    pub mode: ResizeMode,
    pub scale: Option<[f32; 2]>,
    pub size: Option<[u32; 2]>,
    pub align_corners: bool,
}

#[derive(Serialize, Debug)]
pub struct PixelShuffleParams {
    pub factor: u32,
}

#[derive(Serialize, Debug)]
pub struct WarpParams {
    pub variant: &'static str,
}

#[derive(Serialize, Debug)]
pub struct PreluParams {
    /// Per-channel negative slope; `count` is the number of channels, or 1 when the slope is shared.
    pub slope: BlobRef,
}

#[derive(Serialize, Debug)]
pub struct ClipParams {
    pub min: f32,
    pub max: f32,
}
