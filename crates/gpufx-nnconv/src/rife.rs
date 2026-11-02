//! `--rewrite rife-v4-scale`: turns the fixed `scale = 1` of a converted RIFE v4.6 IFNet (rife-ncnn-vulkan
//! `flownet.param`) into the run-time parameter `scale` of model.json.
//!
//! IFNet runs four IFBlocks with `scale_list = [8, 4, 2, 1] / scale`. Block `i` (factor `k = 8, 4, 2, 1`)
//! shrinks its input by `1 / (k / scale)`, shrinks the flow it is given the same way and divides it by
//! `k / scale`, then enlarges its output by `k / scale` and multiplies the flow part (channels `[0, 4)`) by
//! `k / scale`. The ncnn export has these constants baked for `scale = 1`; here each becomes
//! `{"param": "scale", "mul": m, "pow": p}` (`m * scale ^ p`). Block 3 (`k = 1`) has no resize at all in
//! the export, so its four steps are inserted as ops that are identities at `scale = 1` (the runtime drops
//! them). This module is the only place that knows the RIFE graph; the runtime runs any graph.
//!
//! Every op touched is checked by name, kind and baked value, so a model of another layout fails clearly.

use crate::model::*;
use crate::{fail, Result};

pub const REWRITE: &str = "rife-v4-scale";

/// Smallest `scale`: the padding then grows to `32 / 0.25 = 128` (see io.json `pad_multiple`).
pub const MIN_SCALE: f32 = 0.25;

fn param(mul: f32, pow: f32) -> Num {
    Num::Param { param: "scale".into(), mul, pow }
}

fn find<'a>(ops: &'a mut [Op], name: &str) -> Result<&'a mut Op> {
    match ops.iter_mut().find(|o| o.name == name) {
        Some(o) => Ok(o),
        None => fail(format!("{REWRITE}: op \"{name}\" not found; the model is not a RIFE v4.6 IFNet")),
    }
}

fn mismatch<T>(name: &str, what: &str) -> Result<T> {
    fail(format!("{REWRITE}: op \"{name}\" is not {what}; the model is not a RIFE v4.6 IFNet"))
}

/// A bilinear resize by `factor` becomes `mul * scale ^ pow`.
fn resize(ops: &mut [Op], name: &str, factor: f32, mul: f32, pow: f32) -> Result<()> {
    let op = find(ops, name)?;
    match &mut op.params {
        OpParams::Resize(ResizeParams { mode: ResizeMode::Bilinear, scale: Some(s), size: None, align_corners: false })
            if s.iter().all(|v| *v == Num::Value(factor)) =>
        {
            *s = [param(mul, pow), param(mul, pow)];
            Ok(())
        }
        _ => mismatch(name, &format!("a bilinear resize by {factor}")),
    }
}

/// A binary `kind` with the scalar `value` gets the scalar `mul * scale ^ pow`.
fn scalar(ops: &mut [Op], name: &str, kind: &str, value: f32, mul: f32, pow: f32) -> Result<()> {
    let op = find(ops, name)?;
    match &mut op.params {
        OpParams::Binary(BinaryParams { kind: k, scalar: Some(s) })
            if format!("{k:?}").eq_ignore_ascii_case(kind) && *s == Num::Value(value) =>
        {
            *s = param(mul, pow);
            Ok(())
        }
        _ => mismatch(name, &format!("a {kind} by the scalar {value}")),
    }
}

/// A weighted sum with coefficients `[1, value]` gets `[1, mul * scale ^ pow]`.
fn weighted(ops: &mut [Op], name: &str, value: f32, mul: f32, pow: f32) -> Result<()> {
    let op = find(ops, name)?;
    match &mut op.params {
        OpParams::Eltwise(EltwiseParams { kind: EltwiseKind::Sum, coeffs: Some(c) }) if *c == [Num::Value(1.0), Num::Value(value)] => {
            c[1] = param(mul, pow);
            Ok(())
        }
        _ => mismatch(name, &format!("a weighted sum [1, {value}]")),
    }
}

fn position(ops: &[Op], name: &str) -> Result<usize> {
    match ops.iter().position(|o| o.name == name) {
        Some(i) => Ok(i),
        None => fail(format!("{REWRITE}: op \"{name}\" not found; the model is not a RIFE v4.6 IFNet")),
    }
}

fn new_resize(name: &str, input: &str, output: &str, mul: f32, pow: f32) -> Op {
    Op::new(
        name,
        vec![input.into()],
        output,
        OpParams::Resize(ResizeParams {
            mode: ResizeMode::Bilinear,
            scale: Some([param(mul, pow), param(mul, pow)]),
            size: None,
            align_corners: false,
        }),
    )
}

fn new_mul(name: &str, input: &str, output: &str, mul: f32, pow: f32) -> Op {
    Op::new(name, vec![input.into()], output, OpParams::Binary(BinaryParams { kind: BinaryKind::Mul, scalar: Some(param(mul, pow)) }))
}

/// Applies the rewrite to a model converted from rife-v4.6 `flownet.param` and declares the parameter
/// `scale` (default 1, range [[`MIN_SCALE`], 1]).
pub fn parametrize_scale(model: &mut Model) -> Result<()> {
    let ops = &mut model.ops;
    // block 0 (k = 8): input cat(img0, img1, timestep), no flow
    resize(ops, "upsample_9", 0.125, 0.125, 1.0)?;
    resize(ops, "upsample_10", 8.0, 8.0, -1.0)?;
    scalar(ops, "mul_16", "mul", 8.0, 8.0, -1.0)?;
    // block 1 (k = 4)
    resize(ops, "upsample_11", 0.25, 0.25, 1.0)?;
    scalar(ops, "div_17", "div", 4.0, 4.0, -1.0)?;
    resize(ops, "upsample_12", 0.25, 0.25, 1.0)?;
    resize(ops, "upsample_13", 4.0, 4.0, -1.0)?;
    weighted(ops, "weighted_sum_0", 4.0, 4.0, -1.0)?;
    // block 2 (k = 2)
    resize(ops, "upsample_14", 0.5, 0.5, 1.0)?;
    scalar(ops, "div_37", "div", 2.0, 2.0, -1.0)?;
    resize(ops, "upsample_15", 0.5, 0.5, 1.0)?;
    resize(ops, "upsample_16", 2.0, 2.0, -1.0)?;
    weighted(ops, "weighted_sum_1", 2.0, 2.0, -1.0)?;

    // block 3 (k = 1): x = cat_11 output, flow = weighted_sum_1 output, joined by cat_12
    let (x, flow) = {
        let cat11 = find(ops, "cat_11")?.output.clone();
        let flow = find(ops, "weighted_sum_1")?.output.clone();
        let cat12 = find(ops, "cat_12")?;
        if !matches!(cat12.params, OpParams::Concat(ConcatParams { axis: 0 })) || cat12.inputs != [cat11.clone(), flow.clone()] {
            return mismatch("cat_12", "the concat of cat_11 and weighted_sum_1");
        }
        cat12.inputs = vec!["scale3_x".into(), "scale3_flow".into()];
        (cat11, flow)
    };
    let at = position(ops, "cat_12")?;
    // x = interpolate(x, 1 / (1 / scale)); flow = interpolate(flow, scale) * (1 / (1 / scale))
    ops.splice(
        at..at,
        [
            new_resize("scale3_x_resize", &x, "scale3_x", 1.0, 1.0),
            new_resize("scale3_flow_resize", &flow, "scale3_flow_rs", 1.0, 1.0),
            new_mul("scale3_flow_mul", "scale3_flow_rs", "scale3_flow", 1.0, 1.0),
        ],
    );

    // tmp = interpolate(tmp, 1 / scale); flow = tmp[:, :4] * (1 / scale); mask = tmp[:, 4:5]
    let at = position(ops, "pixelshuffle_107")?;
    if !matches!(ops[at].params, OpParams::PixelShuffle(_)) {
        return mismatch("pixelshuffle_107", "a pixel_shuffle");
    }
    let tmp = ops[at].output.clone();
    let users: Vec<usize> = (0..ops.len()).filter(|&i| ops[i].inputs.contains(&tmp)).collect();
    let mut names: Vec<&str> = users.iter().map(|&i| ops[i].name.as_str()).collect();
    names.sort_unstable();
    if names != ["slice_120", "slice_121"] {
        return mismatch("pixelshuffle_107", "read by slice_120 and slice_121 only");
    }
    for &i in &users {
        for input in &mut ops[i].inputs {
            if *input == tmp {
                *input = "scale3_tmp".into();
            }
        }
    }
    ops.insert(at + 1, new_resize("scale3_tmp_resize", &tmp, "scale3_tmp", 1.0, -1.0));

    let at = position(ops, "slice_120")?;
    if !matches!(ops[at].params, OpParams::Slice(SliceParams { axis: 0, start: 0, end: Some(4) })) {
        return mismatch("slice_120", "the slice of channels [0, 4)");
    }
    let flow3 = ops[at].output.clone();
    let users: Vec<usize> = (0..ops.len()).filter(|&i| ops[i].inputs.contains(&flow3)).collect();
    if users.len() != 1 || ops[users[0]].name != "add_73" {
        return mismatch("slice_120", "read by add_73 only");
    }
    for input in &mut ops[users[0]].inputs {
        if *input == flow3 {
            *input = "scale3_flow_out".into();
        }
    }
    ops.insert(at + 1, new_mul("scale3_flow_out_mul", &flow3, "scale3_flow_out", 1.0, -1.0));
    let slice121 = find(ops, "slice_121")?;
    if !matches!(slice121.params, OpParams::Slice(SliceParams { axis: 0, start: 4, end: Some(5) })) {
        return mismatch("slice_121", "the slice of channel 4 (mask)");
    }

    model
        .params
        .insert("scale".into(), ParamDecl { default: 1.0, min: Some(MIN_SCALE), max: Some(1.0), values: Some(vec![0.25, 0.5, 1.0]) });
    Ok(())
}

/// Applies the rewrite named by `--rewrite`.
pub fn apply(model: &mut Model, rewrite: &str) -> Result<()> {
    match rewrite {
        REWRITE => parametrize_scale(model),
        r => fail(format!("--rewrite: unknown rewrite \"{r}\" (known: {REWRITE})")),
    }
}
