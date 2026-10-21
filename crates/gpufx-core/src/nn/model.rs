//! `model.json` of a gpufx-nn package (version 1, see `docs/NN_MODEL_FORMAT.md`), parsed and checked.

use serde::Deserialize;

use crate::Error;

fn err(msg: impl Into<String>) -> Error {
    Error::Package(msg.into())
}

#[derive(Deserialize)]
struct RawModel {
    format: String,
    version: u32,
    #[serde(default)]
    name: String,
    used_for: Vec<String>,
    inputs: Vec<RawInput>,
    outputs: Vec<String>,
    ops: Vec<RawOp>,
}

#[derive(Deserialize)]
struct RawInput {
    name: String,
}

#[derive(Deserialize)]
struct RawOp {
    op: String,
    #[serde(default)]
    name: String,
    inputs: Vec<String>,
    output: String,
    #[serde(flatten)]
    params: serde_json::Value,
}

#[derive(Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Activation {
    Relu,
    LeakyRelu { slope: f32 },
    Sigmoid,
}

#[derive(Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Dtype {
    F16,
    F32,
}

/// A blob of `weights.bin`.
#[derive(Deserialize, Clone, Copy, Debug)]
pub struct BlobRef {
    pub offset: u64,
    pub count: u64,
    pub dtype: Dtype,
}

#[derive(Deserialize, Debug, Clone)]
pub struct ConvParams {
    pub in_channels: u32,
    pub out_channels: u32,
    pub kernel: [u32; 2],
    pub stride: [u32; 2],
    pub dilation: [u32; 2],
    /// top, left, bottom, right
    pub pad: [u32; 4],
    #[serde(default)]
    pub output_pad: [u32; 2],
    pub activation: Option<Activation>,
    pub weight: BlobRef,
    pub bias: Option<BlobRef>,
}

#[derive(Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
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

#[derive(Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum EltwiseKind {
    Prod,
    Sum,
    Max,
}

#[derive(Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ResizeMode {
    Nearest,
    Bilinear,
    Bicubic,
}

#[derive(Debug, Clone)]
pub enum OpKind {
    Conv2d(ConvParams),
    Deconv2d(ConvParams),
    Activation(Activation),
    Binary {
        kind: BinaryKind,
        scalar: Option<f32>,
    },
    Eltwise {
        kind: EltwiseKind,
        coeffs: Option<Vec<f32>>,
    },
    Concat,
    Slice {
        start: u32,
        end: Option<u32>,
    },
    Resize {
        mode: ResizeMode,
        scale: Option<[f32; 2]>,
        size: Option<[u32; 2]>,
        align_corners: bool,
    },
    PixelShuffle(u32),
    Warp,
    /// `x >= 0 ? x : slope[c] * x`, `slope.count` channels or 1 shared slope.
    Prelu {
        slope: BlobRef,
    },
    Clip {
        min: f32,
        max: f32,
    },
}

#[derive(Debug, Clone)]
pub struct Op {
    pub name: String,
    pub inputs: Vec<String>,
    pub output: String,
    pub kind: OpKind,
}

/// A parsed `model.json`.
#[derive(Debug, Clone)]
pub struct Model {
    pub name: String,
    /// The filters the model is for (see [`crate::used_for`]).
    pub used_for: Vec<String>,
    pub inputs: Vec<String>,
    pub outputs: Vec<String>,
    pub ops: Vec<Op>,
}

fn field<T: serde::de::DeserializeOwned>(v: &serde_json::Value, key: &str) -> Result<T, Error> {
    let x = v.get(key).cloned().unwrap_or(serde_json::Value::Null);
    serde_json::from_value(x).map_err(|e| err(format!("\"{key}\": {e}")))
}

fn parse_op(raw: RawOp) -> Result<Op, Error> {
    let p = &raw.params;
    let kind = match raw.op.as_str() {
        "conv2d" | "deconv2d" => {
            let c: ConvParams = serde_json::from_value(p.clone()).map_err(|e| err(e.to_string()))?;
            let k = c.kernel[0] as u64 * c.kernel[1] as u64;
            if c.in_channels == 0 || c.out_channels == 0 || k == 0 || c.stride.contains(&0) || c.dilation.contains(&0) {
                return Err(err("empty kernel, channels, stride or dilation"));
            }
            if c.weight.count != c.in_channels as u64 * c.out_channels as u64 * k {
                return Err(err(format!("weight has {} elements, expected in x out x kh x kw", c.weight.count)));
            }
            if c.bias.is_some_and(|b| b.count != c.out_channels as u64) {
                return Err(err("bias count is not out_channels"));
            }
            if raw.op == "conv2d" {
                OpKind::Conv2d(c)
            } else {
                OpKind::Deconv2d(c)
            }
        }
        "activation" => OpKind::Activation(serde_json::from_value(p.clone()).map_err(|e| err(e.to_string()))?),
        "binary" => OpKind::Binary { kind: field(p, "kind")?, scalar: field(p, "scalar")? },
        "eltwise" => OpKind::Eltwise { kind: field(p, "kind")?, coeffs: field(p, "coeffs")? },
        "concat" | "slice" => {
            if field::<u32>(p, "axis")? != 0 {
                return Err(err("only channel axis 0 is supported"));
            }
            if raw.op == "concat" {
                OpKind::Concat
            } else {
                OpKind::Slice { start: field(p, "start")?, end: field(p, "end")? }
            }
        }
        "resize" => {
            let scale: Option<[f32; 2]> = field(p, "scale")?;
            let size: Option<[u32; 2]> = field(p, "size")?;
            if scale.is_none() && size.is_none() {
                return Err(err("resize needs scale or size"));
            }
            OpKind::Resize {
                mode: field(p, "mode")?,
                scale,
                size,
                align_corners: field::<Option<bool>>(p, "align_corners")?.unwrap_or(false),
            }
        }
        "pixel_shuffle" => {
            let r: u32 = field(p, "factor")?;
            if r == 0 {
                return Err(err("pixel_shuffle factor 0"));
            }
            OpKind::PixelShuffle(r)
        }
        "warp" => {
            let v: String = field(p, "variant")?;
            if v != "rife" {
                return Err(err(format!("unknown warp variant \"{v}\"")));
            }
            OpKind::Warp
        }
        "prelu" => {
            let slope: BlobRef = field(p, "slope")?;
            if slope.count == 0 {
                return Err(err("prelu slope is empty"));
            }
            OpKind::Prelu { slope }
        }
        "clip" => {
            // a missing bound is the f32 limit (ncnn Clip)
            let min = field::<Option<f32>>(p, "min")?.unwrap_or(f32::MIN);
            let max = field::<Option<f32>>(p, "max")?.unwrap_or(f32::MAX);
            if min.is_nan() || max.is_nan() || min > max {
                return Err(err(format!("clip [{min}, {max}] is not a range")));
            }
            OpKind::Clip { min, max }
        }
        k => return Err(err(format!("unknown op \"{k}\""))),
    };
    Ok(Op { name: raw.name, inputs: raw.inputs, output: raw.output, kind })
}

impl Model {
    pub fn parse(json: &[u8]) -> Result<Self, Error> {
        let raw: RawModel = serde_json::from_slice(json).map_err(|e| {
            let hint = if e.to_string().starts_with("missing field `used_for`") {
                r#": list the filters the model is for, e.g. "used_for": ["gpufx_ai_upscale"]"#
            } else {
                ""
            };
            err(format!("model.json: {e}{hint}"))
        })?;
        if raw.format != "gpufx-nn" || raw.version != 1 {
            return Err(err("model.json is not a gpufx-nn version 1 model"));
        }
        crate::used_for::validate(&raw.used_for).map_err(|e| err(format!("model.json: {e}")))?;
        let mut ops = Vec::with_capacity(raw.ops.len());
        for o in raw.ops {
            let name = o.name.clone();
            ops.push(parse_op(o).map_err(|e| err(format!("model.json: op {name}: {e}")))?);
        }
        Ok(Model {
            name: raw.name,
            used_for: raw.used_for,
            inputs: raw.inputs.into_iter().map(|i| i.name).collect(),
            outputs: raw.outputs,
            ops,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(used_for: &str) -> Result<Model, String> {
        let json =
            format!(r#"{{"format":"gpufx-nn","version":1,"name":"m"{used_for},"inputs":[{{"name":"in0"}}],"outputs":["in0"],"ops":[]}}"#);
        Model::parse(json.as_bytes()).map_err(|e| e.to_string())
    }

    #[test]
    fn used_for_is_required_and_checked() {
        assert_eq!(parse(r#","used_for":["gpufx_ai_upscale"]"#).unwrap().used_for, ["gpufx_ai_upscale"]);
        let missing = parse("").err().unwrap();
        assert!(missing.contains("missing field `used_for`") && missing.contains(r#""used_for": ["gpufx_ai_upscale"]"#), "{missing}");
        assert!(parse(r#","used_for":[]"#).err().unwrap().contains("`used_for` is empty"));
        assert!(parse(r#","used_for":["upscale"]"#).err().unwrap().contains("unknown filter `upscale`"));
    }
}
