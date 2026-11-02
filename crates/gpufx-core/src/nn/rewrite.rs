//! Graph rewrites run before planning: same values, smaller tensors. A resize works on each channel alone, so
//! - `resize(concat(a, b, ..))` is `concat(resize(a), resize(b), ..)`: no concat at the input size, and the
//!   resized parts are written in place into the concat (RIFE downscales the two frames at full size);
//! - a resize read only by channel slices is the resize of each slice: channels no slice reads are never
//!   resized (RIFE upscales a 6 channel flow and keeps 5 of them);
//! - an op that returns its input (resize by 1, multiply or divide by 1, add or subtract 0, eltwise of one
//!   input without a coefficient other than 1) is dropped and its readers read the input: a parameter at a
//!   value that makes it neutral costs no memory and no dispatch.
//!
//! Tensors that still exist keep their names (plans look model inputs and outputs up by name); a model
//! output or a tensor read anywhere else is never removed.

use std::collections::{HashMap, HashSet};

use super::model::{BinaryKind, EltwiseKind, Op, OpKind};

/// The rewritten ops and, per op, the index of the model op it comes from (weights are keyed by it).
pub(crate) fn rewrite(ops: &[Op], outputs: &[String], channels: impl Fn(&[Op]) -> HashMap<String, u32>) -> (Vec<Op>, Vec<usize>) {
    let mut g = drop_identities(ops.iter().cloned().zip(0..).collect(), outputs);
    let mut names: HashSet<String> = ops.iter().flat_map(|o| o.inputs.iter().chain([&o.output, &o.name])).cloned().collect();
    while let Some(next) = rewrite_one(&g, outputs, &mut names, &channels) {
        g = next;
    }
    g.into_iter().unzip()
}

/// Whether `op` returns its only input unchanged.
fn is_identity(op: &Op) -> bool {
    if op.inputs.len() != 1 {
        return false;
    }
    match &op.kind {
        OpKind::Resize { scale: Some(s), size: None, .. } => *s == [1.0, 1.0],
        OpKind::Binary { kind: BinaryKind::Mul | BinaryKind::Div, scalar: Some(s) } => *s == 1.0,
        OpKind::Binary { kind: BinaryKind::Add | BinaryKind::Sub, scalar: Some(s) } => *s == 0.0,
        OpKind::Eltwise { kind: EltwiseKind::Sum, coeffs } => coeffs.as_ref().is_none_or(|c| c[..] == [1.0]),
        OpKind::Eltwise { kind: EltwiseKind::Prod | EltwiseKind::Max, .. } => true,
        _ => false,
    }
}

/// Drops identity ops, their readers read the input instead (chains too); a model output is kept.
fn drop_identities(g: Vec<(Op, usize)>, outputs: &[String]) -> Vec<(Op, usize)> {
    let mut alias: HashMap<String, String> = HashMap::new();
    let mut out = Vec::with_capacity(g.len());
    for (mut op, src) in g {
        for i in &mut op.inputs {
            if let Some(a) = alias.get(i) {
                *i = a.clone();
            }
        }
        if is_identity(&op) && !outputs.contains(&op.output) {
            alias.insert(op.output.clone(), op.inputs[0].clone());
            continue;
        }
        out.push((op, src));
    }
    out
}

fn fresh(names: &mut HashSet<String>, base: &str) -> String {
    let n = (0..).map(|k| format!("{base}#{k}")).find(|n| !names.contains(n)).expect("a free name");
    names.insert(n.clone());
    n
}

/// Applies the first rewrite found, or `None` when there is none.
fn rewrite_one(
    g: &[(Op, usize)],
    outputs: &[String],
    names: &mut HashSet<String>,
    channels: &impl Fn(&[Op]) -> HashMap<String, u32>,
) -> Option<Vec<(Op, usize)>> {
    let mut uses: HashMap<&str, usize> = HashMap::new();
    for (op, _) in g {
        for i in &op.inputs {
            *uses.entry(i).or_default() += 1;
        }
    }
    for o in outputs {
        *uses.entry(o).or_default() += 1;
    }
    let producer: HashMap<&str, usize> = g.iter().enumerate().map(|(i, (o, _))| (o.output.as_str(), i)).collect();
    for (i, (op, src)) in g.iter().enumerate() {
        if !matches!(op.kind, OpKind::Resize { .. }) || op.inputs.len() != 1 {
            continue;
        }
        let x = &op.inputs[0];

        // resize(concat(..)) whose concat has no other reader
        if let Some(&p) = producer.get(x.as_str()) {
            let cat = &g[p].0;
            if matches!(cat.kind, OpKind::Concat) && uses[x.as_str()] == 1 && !outputs.contains(x) {
                let mut parts: Vec<(String, String)> = Vec::new();
                for a in &cat.inputs {
                    if !parts.iter().any(|(n, _)| n == a) {
                        parts.push((a.clone(), fresh(names, &op.output)));
                    }
                }
                // at the concat: its inputs die there as before, not at the resize
                let mut out = Vec::with_capacity(g.len() + parts.len());
                for (j, e) in g.iter().enumerate() {
                    if j == i {
                        continue;
                    }
                    if j != p {
                        out.push(e.clone());
                        continue;
                    }
                    for (a, r) in &parts {
                        let name = fresh(names, &op.name);
                        out.push((Op { name, inputs: vec![a.clone()], output: r.clone(), kind: op.kind.clone() }, *src));
                    }
                    let inputs = cat.inputs.iter().map(|a| parts.iter().find(|(n, _)| n == a).unwrap().1.clone()).collect();
                    out.push((Op { name: cat.name.clone(), inputs, output: op.output.clone(), kind: OpKind::Concat }, g[p].1));
                }
                return Some(out);
            }
        }

        // a resize read only by slices that leave channels out: each slice of the resize becomes the resize
        // of a slice (slices covering every channel, or overlapping, would resize more than before)
        let readers: Vec<usize> = (i + 1..g.len()).filter(|&j| g[j].0.inputs.contains(&op.output)).collect();
        let only_slices = readers.iter().all(|&j| matches!(g[j].0.kind, OpKind::Slice { .. }) && g[j].0.inputs.len() == 1);
        if !readers.is_empty() && only_slices && uses[op.output.as_str()] == readers.len() && !outputs.contains(&op.output) {
            let ops: Vec<Op> = g.iter().map(|(o, _)| o.clone()).collect();
            let Some(&c) = channels(&ops).get(op.output.as_str()) else { continue };
            let sliced: u32 = readers
                .iter()
                .map(|&j| match g[j].0.kind {
                    OpKind::Slice { start, end } => end.unwrap_or(c).min(c).saturating_sub(start),
                    _ => unreachable!("only slices"),
                })
                .sum();
            if sliced >= c {
                continue;
            }
            let mut out = Vec::with_capacity(g.len() + readers.len());
            for (j, e) in g.iter().enumerate() {
                if j == i {
                    continue;
                }
                if !readers.contains(&j) {
                    out.push(e.clone());
                    continue;
                }
                let s = &e.0;
                let part = fresh(names, &s.output);
                out.push((Op { name: fresh(names, &s.name), inputs: vec![x.clone()], output: part.clone(), kind: s.kind.clone() }, e.1));
                out.push((Op { name: s.name.clone(), inputs: vec![part], output: s.output.clone(), kind: op.kind.clone() }, *src));
            }
            return Some(out);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nn::model::ResizeMode;

    fn op(name: &str, inputs: &[&str], kind: OpKind) -> Op {
        Op { name: name.into(), inputs: inputs.iter().map(|s| s.to_string()).collect(), output: name.into(), kind }
    }

    fn resize(name: &str, input: &str) -> Op {
        op(name, &[input], OpKind::Resize { mode: ResizeMode::Bilinear, scale: Some([0.5, 0.5]), size: None, align_corners: false })
    }

    fn slice(name: &str, input: &str, start: u32, end: Option<u32>) -> Op {
        op(name, &[input], OpKind::Slice { start, end })
    }

    /// Channels of the resizes the tests slice.
    fn chans(_: &[Op]) -> HashMap<String, u32> {
        [("r", 6), ("q", 4), ("p", 4)].map(|(n, c)| (n.to_string(), c)).into()
    }

    fn act(name: &str, input: &str) -> Op {
        op(name, &[input], OpKind::Activation(crate::nn::model::Activation::Relu))
    }

    /// `op: inputs -> output` per op, to compare graphs.
    fn show(ops: &[Op]) -> Vec<String> {
        ops.iter()
            .map(|o| {
                let k = match o.kind {
                    OpKind::Resize { .. } => "resize".to_string(),
                    OpKind::Concat => "concat".to_string(),
                    OpKind::Slice { start, end } => format!("slice{start}:{end:?}"),
                    _ => "other".to_string(),
                };
                format!("{k} {} -> {}", o.inputs.join(","), o.output)
            })
            .collect()
    }

    #[test]
    fn resize_of_nested_concats_resizes_each_part() {
        let ops = vec![
            act("a", "x"),
            op("c1", &["x", "a"], OpKind::Concat),
            op("c2", &["c1", "y", "x"], OpKind::Concat),
            resize("r", "c2"),
            act("o", "r"),
        ];
        let (got, orig) = rewrite(&ops, &["o".into()], chans);
        assert_eq!(
            show(&got),
            [
                "other x -> a",
                "resize x -> r#0#0",
                "resize a -> r#0#1",
                "concat r#0#0,r#0#1 -> r#0",
                "resize y -> r#1",
                "resize x -> r#2",
                "concat r#0,r#1,r#2 -> r",
                "other r -> o"
            ]
        );
        assert_eq!(orig, [0, 3, 3, 1, 3, 3, 2, 4]);
    }

    #[test]
    fn resize_read_by_slices_resizes_each_slice() {
        let ops = vec![act("f", "x"), resize("r", "f"), slice("s0", "r", 0, Some(4)), act("u", "s0"), slice("s1", "r", 4, Some(5))];
        let (got, orig) = rewrite(&ops, &["u".into(), "s1".into()], chans);
        assert_eq!(
            show(&got),
            [
                "other x -> f",
                "slice0:Some(4) f -> s0#0",
                "resize s0#0 -> s0",
                "other s0 -> u",
                "slice4:Some(5) f -> s1#0",
                "resize s1#0 -> s1"
            ]
        );
        assert_eq!(orig, [0, 2, 1, 3, 4, 1]);
    }

    #[test]
    fn shared_or_output_tensors_are_kept() {
        // the concat is read twice, the resize is an output, a resize also read by a non slice
        let ops = vec![
            op("c", &["x", "y"], OpKind::Concat),
            resize("r", "c"),
            act("k", "c"),
            resize("q", "x"),
            slice("s", "q", 0, Some(1)),
            resize("p", "y"),
            slice("t", "p", 0, None),
            act("v", "p"),
        ];
        let outs: Vec<String> = ["r", "k", "s", "t", "v"].map(String::from).to_vec();
        let mut with_q_out = outs.clone();
        with_q_out.push("q".into());
        let (got, _) = rewrite(&ops, &with_q_out, chans);
        assert_eq!(show(&got), show(&ops));
        // without q as an output, only q is rewritten
        let (got, _) = rewrite(&ops, &outs, chans);
        assert_eq!(got.len(), ops.len());
        assert!(got.iter().any(|o| o.output == "s" && matches!(o.kind, OpKind::Resize { .. })));
    }

    #[test]
    fn slices_reading_every_channel_keep_the_resize() {
        // overlapping slices (8 of 6 channels), one slice of all channels, a shape that is not known
        for ops in [
            vec![resize("r", "x"), slice("a", "r", 0, Some(4)), slice("b", "r", 2, Some(6))],
            vec![resize("r", "x"), slice("a", "r", 0, None)],
            vec![resize("z", "x"), slice("a", "z", 0, Some(1))],
        ] {
            let outs: Vec<String> = ops[1..].iter().map(|o| o.output.clone()).collect();
            let (got, _) = rewrite(&ops, &outs, chans);
            assert_eq!(show(&got), show(&ops));
        }
    }

    fn bin(name: &str, input: &str, kind: BinaryKind, s: f32) -> Op {
        op(name, &[input], OpKind::Binary { kind, scalar: Some(s) })
    }

    #[test]
    fn identities_are_dropped_unless_outputs() {
        let unit = OpKind::Resize { mode: ResizeMode::Bilinear, scale: Some([1.0, 1.0]), size: None, align_corners: true };
        let ops = vec![
            act("a", "x"),
            op("r", &["a"], unit.clone()),
            bin("m", "r", BinaryKind::Mul, 1.0),
            bin("d", "m", BinaryKind::Div, 1.0),
            bin("p", "d", BinaryKind::Add, 0.0),
            op("e", &["p"], OpKind::Eltwise { kind: EltwiseKind::Sum, coeffs: Some(vec![1.0]) }),
            act("b", "e"),
            // not identities: scale 2, rdiv by 1, sum of two inputs
            bin("k", "b", BinaryKind::Mul, 2.0),
            bin("q", "k", BinaryKind::Rdiv, 1.0),
            op("s", &["q", "a"], OpKind::Eltwise { kind: EltwiseKind::Sum, coeffs: None }),
            // a model output stays
            op("o", &["s"], unit),
        ];
        let (got, orig) = rewrite(&ops, &["o".into()], chans);
        assert_eq!(show(&got), ["other x -> a", "other a -> b", "other b -> k", "other k -> q", "other q,a -> s", "resize s -> o"]);
        assert_eq!(orig, [0, 6, 7, 8, 9, 10]);
    }

    #[test]
    fn graphs_without_concat_or_slice_are_unchanged() {
        let ops = vec![act("a", "x"), resize("r", "a"), act("b", "r"), op("ps", &["b"], OpKind::PixelShuffle(2))];
        let (got, orig) = rewrite(&ops, &["ps".into()], chans);
        assert_eq!(show(&got), show(&ops));
        assert_eq!(orig, [0, 1, 2, 3]);
    }
}
