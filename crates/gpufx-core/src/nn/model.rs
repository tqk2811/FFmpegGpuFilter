//! `model.json` of a gpufx-nn package (version 1, see `docs/NN_MODEL_FORMAT.md`), parsed and checked.

use std::borrow::Cow;

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
    #[serde(default)]
    params: serde_json::Map<String, serde_json::Value>,
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
    /// Declared run-time parameters (`"params"`); `ops` hold the constants at their defaults.
    pub params: Vec<Param>,
    binds: Vec<Bind>,
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
        let mut params = Vec::with_capacity(raw.params.len());
        for (name, d) in raw.params {
            let d: RawParam = serde_json::from_value(d).map_err(|e| err(format!("model.json: param \"{name}\": {e}")))?;
            if !d.default.is_finite() || d.min.is_some_and(|v| d.default < v) || d.max.is_some_and(|v| d.default > v) {
                return Err(err(format!("model.json: param \"{name}\": default {} is out of its range", d.default)));
            }
            if let Some(vs) = &d.values {
                let inside = |v: f32| v.is_finite() && d.min.is_none_or(|m| v >= m) && d.max.is_none_or(|m| v <= m);
                if vs.is_empty() || !vs.iter().all(|&v| inside(v)) {
                    return Err(err(format!("model.json: param \"{name}\": values {vs:?} must be non-empty and inside its range")));
                }
                if !vs.contains(&d.default) {
                    return Err(err(format!("model.json: param \"{name}\": default {} is not one of {vs:?}", d.default)));
                }
            }
            params.push(Param { name, default: d.default, min: d.min, max: d.max, values: d.values });
        }
        let mut ops = Vec::with_capacity(raw.ops.len());
        let mut binds = Vec::new();
        for (i, mut o) in raw.ops.into_iter().enumerate() {
            let name = o.name.clone();
            let fail = |e: Error| err(format!("model.json: op {name}: {e}"));
            take_params(&mut o.params, i, &params, &mut binds).map_err(fail)?;
            ops.push(parse_op(o).map_err(fail)?);
        }
        Ok(Model {
            name: raw.name,
            used_for: raw.used_for,
            inputs: raw.inputs.into_iter().map(|i| i.name).collect(),
            outputs: raw.outputs,
            ops,
            params,
            binds,
        })
    }

    /// The ops with parameter values by name (a parameter not given takes its default). Borrowed when
    /// nothing changes.
    pub fn ops_with(&self, values: &[(&str, f32)]) -> Result<Cow<'_, [Op]>, Error> {
        let mut v: Vec<f32> = self.params.iter().map(|p| p.default).collect();
        for &(name, x) in values {
            let Some(k) = self.params.iter().position(|p| p.name == name) else {
                return Err(err(format!("param \"{name}\" is not declared by the model")));
            };
            let p = &self.params[k];
            if !x.is_finite() || p.min.is_some_and(|m| x < m) || p.max.is_some_and(|m| x > m) {
                return Err(err(format!("param \"{name}\" = {x} is out of its range")));
            }
            if p.values.as_ref().is_some_and(|vs| !vs.contains(&x)) {
                return Err(err(format!("param \"{name}\" = {x} is not one of {:?}", p.values.as_deref().unwrap_or(&[]))));
            }
            v[k] = x;
        }
        if v.iter().zip(&self.params).all(|(x, p)| *x == p.default) {
            return Ok(Cow::Borrowed(&self.ops));
        }
        let mut ops = self.ops.clone();
        for b in &self.binds {
            let x = param_value(b.mul, v[b.param], b.pow);
            let op = &mut ops[b.op];
            if !x.is_finite() {
                return Err(err(format!("op {}: {} * {} ^ {} is not finite", op.name, b.mul, self.params[b.param].name, b.pow)));
            }
            match (&mut op.kind, b.slot) {
                (OpKind::Binary { scalar: Some(s), .. }, Slot::Scalar) => *s = x,
                (OpKind::Eltwise { coeffs: Some(c), .. }, Slot::Coeff(n)) => c[n] = x,
                // the same check as a resize scale read from the file
                (OpKind::Resize { .. }, Slot::Scale(_)) if x <= 0.0 => {
                    return Err(err(format!("op {}: resize scale {x} is not positive", op.name)));
                }
                (OpKind::Resize { scale: Some(s), .. }, Slot::Scale(n)) => s[n] = x,
                _ => return Err(err(format!("op {}: a parameter is set on a field the op does not have", op.name))),
            }
        }
        Ok(Cow::Owned(ops))
    }
}

/// A run-time parameter of the model (`"params"` of `model.json`).
#[derive(Debug, Clone, PartialEq)]
pub struct Param {
    pub name: String,
    pub default: f32,
    pub min: Option<f32>,
    pub max: Option<f32>,
    /// The only values allowed, when the model has no meaning in between.
    pub values: Option<Vec<f32>>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawParam {
    default: f32,
    min: Option<f32>,
    max: Option<f32>,
    values: Option<Vec<f32>>,
}

fn one() -> f32 {
    1.0
}

/// `{"param": name, "mul": k, "pow": p}` in place of an f32 constant: `k * value ^ p`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRef {
    param: String,
    #[serde(default = "one")]
    mul: f32,
    #[serde(default = "one")]
    pow: f32,
}

/// Where a parameter goes in an op.
#[derive(Debug, Clone, Copy)]
enum Slot {
    Scalar,
    Coeff(usize),
    Scale(usize),
}

/// The constant at `slot` of op `op` is `mul * params[param] ^ pow`.
#[derive(Debug, Clone, Copy)]
struct Bind {
    op: usize,
    slot: Slot,
    param: usize,
    mul: f32,
    pow: f32,
}

/// In f64, like the CPU reference of gpufx-nnconv.
fn param_value(mul: f32, v: f32, pow: f32) -> f32 {
    (mul as f64 * (v as f64).powf(pow as f64)) as f32
}

/// Replaces the parameter references of op `i` (scalar, coeffs, scale) by their values at the defaults
/// and records them in `binds`.
fn take_params(o: &mut serde_json::Value, i: usize, params: &[Param], binds: &mut Vec<Bind>) -> Result<(), Error> {
    let mut at = |v: &mut serde_json::Value, slot: Slot| -> Result<(), Error> {
        if !v.is_object() {
            return Ok(());
        }
        let r: RawRef = serde_json::from_value(v.take()).map_err(|e| err(format!("parameter reference: {e}")))?;
        let Some(param) = params.iter().position(|p| p.name == r.param) else {
            return Err(err(format!("param \"{}\" is not declared in \"params\"", r.param)));
        };
        let x = param_value(r.mul, params[param].default, r.pow);
        if !x.is_finite() {
            return Err(err(format!("{} * {} ^ {} is not finite at the default", r.mul, r.param, r.pow)));
        }
        *v = serde_json::Value::from(x);
        binds.push(Bind { op: i, slot, param, mul: r.mul, pow: r.pow });
        Ok(())
    };
    if let Some(v) = o.get_mut("scalar") {
        at(v, Slot::Scalar)?;
    }
    for (key, slot) in [("coeffs", Slot::Coeff as fn(usize) -> Slot), ("scale", Slot::Scale)] {
        if let Some(a) = o.get_mut(key).and_then(serde_json::Value::as_array_mut) {
            for (n, v) in a.iter_mut().enumerate() {
                at(v, slot(n))?;
            }
        }
    }
    Ok(())
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

    fn with_ops(extra: &str, ops: &str) -> Result<Model, String> {
        let json = format!(
            r#"{{"format":"gpufx-nn","version":1,"used_for":["gpufx_ai_upscale"]{extra},"inputs":[{{"name":"x"}}],"outputs":["y"],"ops":[{ops}]}}"#
        );
        Model::parse(json.as_bytes()).map_err(|e| e.to_string())
    }

    #[test]
    fn parameters_resolve_to_numbers() {
        let ops =
            r#"{"op":"resize","name":"y","inputs":["x"],"output":"y","mode":"bilinear","scale":[{"param":"s","mul":2,"pow":-1},0.5]}"#;
        let m = with_ops(r#","params":{"s":{"default":0.5}}"#, ops).unwrap();
        let scale = |ops: &[Op]| match ops[0].kind {
            OpKind::Resize { scale, .. } => scale.unwrap(),
            _ => unreachable!(),
        };
        assert_eq!(scale(&m.ops), [4.0, 0.5]);
        assert!(matches!(m.ops_with(&[("s", 0.5)]).unwrap(), Cow::Borrowed(_)));
        assert_eq!(scale(&m.ops_with(&[("s", 0.25)]).unwrap()), [8.0, 0.5]);
        // a model without parameters: nothing declared, ops as written
        let old = with_ops("", r#"{"op":"binary","name":"y","inputs":["x"],"output":"y","kind":"mul","scalar":3}"#).unwrap();
        assert!(old.params.is_empty() && matches!(old.ops_with(&[]).unwrap(), Cow::Borrowed(_)));
        assert!(old.ops_with(&[("s", 1.0)]).is_err());
        // a value that is not finite at the default
        let e = with_ops(r#","params":{"s":{"default":0}}"#, ops).unwrap_err();
        assert!(e.contains("not finite"), "{e}");
    }
}
