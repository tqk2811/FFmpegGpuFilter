//! A graph laid out for one set of input sizes: shape inference, fusion of `conv -> add -> activation`,
//! tensor lifetimes and buffer reuse, and the list of dispatches recorded per inference.
//!
//! Buffer reuse: every tensor that is not a view lives in an allocation from the step that writes it to the
//! last step that reads it (or any view of it); slices are views (an offset into their source's allocation)
//! so they cost nothing and keep the source alive. Allocations are packed into a few buffers ("slots") in
//! step order, best fit first; a slot is only released after the step's output got its own, so an op never
//! reads and writes the same buffer. A tensor only read by a concat is written straight into its channel
//! range of the concat output (no copy).

use std::collections::HashMap;
use std::time::Instant;

use super::kernels::{self, ConvConfig, Fixed, Kernel, PARAM_SLOT};
use super::model::{Activation, BinaryKind, EltwiseKind, OpKind, ResizeMode};
use super::{conv_shape, NnModel};
use crate::Error;

/// Where a tensor lives: `c x h x w` f32 values at element `offset` of `buffer`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TensorView {
    pub slot: usize,
    pub offset: u32,
    pub c: u32,
    pub h: u32,
    pub w: u32,
}

impl TensorView {
    pub fn len(&self) -> u32 {
        self.c * self.h * self.w
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn plane(&self) -> u32 {
        self.h * self.w
    }
}

struct Dispatch {
    label: &'static str,
    /// op name and output shape, for profiles
    detail: String,
    pipeline: wgpu::ComputePipeline,
    group: wgpu::BindGroup,
    groups: (u32, u32, u32),
}

/// The graph of an [`NnModel`] for fixed input sizes, ready to record.
pub struct NnPlan {
    buffers: Vec<wgpu::Buffer>,
    tensors: HashMap<String, TensorView>,
    dispatches: Vec<Dispatch>,
    _params: wgpu::Buffer,
    peak_bytes: u64,
    device: wgpu::Device,
    queue: wgpu::Queue,
}

/// Parameter words of one dispatch, in the order of the shader's `struct P`.
#[derive(Default)]
struct Words(Vec<u32>);

impl Words {
    fn u(mut self, v: u32) -> Self {
        self.0.push(v);
        self
    }

    fn f(mut self, v: f32) -> Self {
        self.0.push(v.to_bits());
        self
    }
}

/// Workgroups for `n` invocations of a 1D kernel of `size`, split over x and y (65535 per dimension).
fn groups_1d(n: u32, size: u32) -> (u32, u32) {
    let g = n.div_ceil(size).max(1);
    let gx = g.min(32768);
    (gx, g.div_ceil(gx))
}

fn act_code(a: Option<Activation>) -> (u32, f32) {
    match a {
        None => (0, 0.0),
        Some(Activation::Relu) => (1, 0.0),
        Some(Activation::LeakyRelu { slope }) => (2, slope),
        Some(Activation::Sigmoid) => (3, 0.0),
    }
}

fn conv_out(i: u32, pad_a: u32, pad_b: u32, k: u32, dil: u32, stride: u32) -> Option<u32> {
    let span = dil * (k - 1) + 1;
    (i + pad_a + pad_b).checked_sub(span).map(|v| v / stride + 1)
}

fn deconv_out(i: u32, pad_a: u32, pad_b: u32, k: u32, dil: u32, stride: u32, out_pad: u32) -> Option<u32> {
    let full = (i.checked_sub(1)?) * stride + dil * (k - 1) + out_pad + 1;
    full.checked_sub(pad_a + pad_b).filter(|&v| v > 0)
}

/// Output shape of an op from its input shapes.
fn infer(kind: &OpKind, ins: &[[u32; 3]]) -> Result<[u32; 3], String> {
    let one = || match ins {
        [a] => Ok(*a),
        _ => Err(format!("expected 1 input, got {}", ins.len())),
    };
    Ok(match kind {
        OpKind::Conv2d(c) | OpKind::Deconv2d(c) => {
            let [ch, h, w] = one()?;
            if ch != c.in_channels {
                return Err(format!("expects {} channels, got {ch}", c.in_channels));
            }
            let deconv = matches!(kind, OpKind::Deconv2d(_));
            let axis = |i: u32, a: usize| {
                if deconv {
                    deconv_out(i, c.pad[a], c.pad[a + 2], c.kernel[a], c.dilation[a], c.stride[a], c.output_pad[a])
                } else {
                    conv_out(i, c.pad[a], c.pad[a + 2], c.kernel[a], c.dilation[a], c.stride[a])
                }
            };
            let (Some(oh), Some(ow)) = (axis(h, 0), axis(w, 1)) else { return Err(format!("input {h}x{w} is too small")) };
            [c.out_channels, oh, ow]
        }
        OpKind::Activation(_) => one()?,
        OpKind::Binary { scalar, .. } => match (scalar, ins) {
            (Some(_), [a]) => *a,
            (None, [a, b]) => {
                let mut o = [0; 3];
                for d in 0..3 {
                    o[d] = if a[d] == b[d] || b[d] == 1 {
                        a[d]
                    } else if a[d] == 1 {
                        b[d]
                    } else {
                        return Err(format!("cannot broadcast {a:?} and {b:?}"));
                    };
                }
                o
            }
            _ => return Err("binary takes one input with a scalar, or two without".into()),
        },
        OpKind::Eltwise { .. } => {
            let a = *ins.first().ok_or("eltwise without inputs")?;
            if ins.iter().any(|s| *s != a) {
                return Err("eltwise inputs differ in shape".into());
            }
            a
        }
        OpKind::Concat => {
            let a = *ins.first().ok_or("concat without inputs")?;
            if ins.iter().any(|s| s[1] != a[1] || s[2] != a[2]) {
                return Err("concat inputs differ in size".into());
            }
            [ins.iter().map(|s| s[0]).sum(), a[1], a[2]]
        }
        OpKind::Slice { start, end } => {
            let [c, h, w] = one()?;
            let end = end.unwrap_or(c);
            if *start >= end || end > c {
                return Err(format!("slice [{start}, {end}) of {c} channels"));
            }
            [end - start, h, w]
        }
        OpKind::Resize { scale, size, .. } => {
            let [c, h, w] = one()?;
            let (oh, ow) = match (size, scale) {
                (Some([h, w]), _) => (*h, *w),
                (None, Some([sh, sw])) => ((h as f32 * sh).floor() as u32, (w as f32 * sw).floor() as u32),
                _ => return Err("resize needs scale or size".into()),
            };
            if oh == 0 || ow == 0 || h == 0 || w == 0 {
                return Err("resize to or from an empty image".into());
            }
            [c, oh, ow]
        }
        OpKind::PixelShuffle(r) => {
            let [c, h, w] = one()?;
            if c % (r * r) != 0 {
                return Err(format!("pixel_shuffle factor {r} does not divide {c} channels"));
            }
            [c / (r * r), h * r, w * r]
        }
        OpKind::Warp => match ins {
            [img, flow] if flow[0] >= 2 && flow[1] == img[1] && flow[2] == img[2] => *img,
            _ => return Err("warp needs [image, flow] of the same size, flow with 2 channels".into()),
        },
    })
}

/// One step after fusion: an op, maybe with the residual add and activation that followed it.
struct Step {
    op: usize,
    inputs: Vec<String>,
    output: String,
    residual: Option<String>,
    post_act: Option<Activation>,
}

/// Finds `conv -> add(conv, r) [-> activation]` where the conv output and the sum have one reader each, and
/// `r` exists before the conv runs.
fn fuse(m: &NnModel, shapes: &HashMap<String, [u32; 3]>) -> Vec<Step> {
    let ops = &m.model.ops;
    let mut uses: HashMap<&str, usize> = HashMap::new();
    for op in ops {
        for i in &op.inputs {
            *uses.entry(i).or_default() += 1;
        }
    }
    for o in &m.model.outputs {
        *uses.entry(o).or_default() += 1;
    }
    let producer: HashMap<&str, usize> = ops.iter().enumerate().map(|(i, o)| (o.output.as_str(), i)).collect();
    let reader = |name: &str, after: usize| (after + 1..ops.len()).find(|&j| ops[j].inputs.iter().any(|i| i == name));
    let mut taken = vec![false; ops.len()];
    let mut steps = Vec::new();
    for (i, op) in ops.iter().enumerate() {
        if taken[i] {
            continue;
        }
        let mut step = Step { op: i, inputs: op.inputs.clone(), output: op.output.clone(), residual: None, post_act: None };
        if matches!(op.kind, OpKind::Conv2d(_)) && uses.get(op.output.as_str()) == Some(&1) {
            if let Some(j) = reader(&op.output, i) {
                let add = &ops[j];
                let is_add = matches!(add.kind, OpKind::Binary { kind: BinaryKind::Add, scalar: None }) && add.inputs.len() == 2;
                let other = add.inputs.iter().find(|n| **n != op.output).cloned();
                let ready = |r: &str| producer.get(r).is_none_or(|&p| p < i);
                if let (true, Some(r)) = (is_add, other) {
                    if shapes.get(&r) == shapes.get(&op.output) && ready(&r) && add.inputs.iter().filter(|n| **n == op.output).count() == 1
                    {
                        taken[j] = true;
                        step.residual = Some(r);
                        step.output = add.output.clone();
                        if uses.get(add.output.as_str()) == Some(&1) {
                            if let Some(k) = reader(&add.output, j) {
                                if let OpKind::Activation(a) = ops[k].kind {
                                    taken[k] = true;
                                    step.post_act = Some(a);
                                    step.output = ops[k].output.clone();
                                }
                            }
                        }
                    }
                }
            }
        }
        steps.push(step);
    }
    steps
}

struct Alloc {
    elems: u64,
    last: usize,
    slot: usize,
}

pub(crate) fn build(m: &NnModel, inputs: &[(&str, [u32; 3])]) -> Result<NnPlan, Error> {
    let ops = &m.model.ops;
    let graph = |msg: String| Error::Graph(msg);
    // shapes
    let mut shapes: HashMap<String, [u32; 3]> = HashMap::new();
    for name in &m.model.inputs {
        let Some((_, s)) = inputs.iter().find(|(n, _)| n == name) else { return Err(graph(format!("missing shape of input \"{name}\""))) };
        if s.contains(&0) {
            return Err(graph(format!("input \"{name}\" is empty")));
        }
        shapes.insert(name.clone(), *s);
    }
    for op in ops {
        let ins: Vec<[u32; 3]> = op
            .inputs
            .iter()
            .map(|i| shapes.get(i).copied().ok_or_else(|| graph(format!("op {}: tensor \"{i}\" does not exist", op.name))))
            .collect::<Result<_, _>>()?;
        let out = infer(&op.kind, &ins).map_err(|e| graph(format!("op {}: {e}", op.name)))?;
        if (out[0] as u64) * (out[1] as u64) * (out[2] as u64) >= u32::MAX as u64 / 4 {
            return Err(graph(format!("op {}: tensor {out:?} is too large", op.name)));
        }
        shapes.insert(op.output.clone(), out);
    }
    for o in &m.model.outputs {
        if !shapes.contains_key(o) {
            return Err(graph(format!("output \"{o}\" is never produced")));
        }
    }
    let steps = fuse(m, &shapes);

    // lifetimes: tensor -> (alloc, offset)
    let mut allocs: Vec<Alloc> = Vec::new();
    let mut at: HashMap<String, (usize, u32)> = HashMap::new();
    let mut defs: Vec<Vec<usize>> = vec![Vec::new(); steps.len() + 1];
    let elems = |s: [u32; 3]| s[0] as u64 * s[1] as u64 * s[2] as u64;
    for name in &m.model.inputs {
        at.insert(name.clone(), (allocs.len(), 0));
        defs[0].push(allocs.len());
        allocs.push(Alloc { elems: elems(shapes[name]), last: 0, slot: usize::MAX });
    }
    // Concat inputs written in place: a tensor read only by one concat, written by a step (not a view, not
    // a model input or output), is a channel range of the concat's output, so the concat copies nothing for
    // it. The concat output's allocation then starts at the first such write. Nested concats chain.
    let mut place: HashMap<&str, (&str, u32)> = HashMap::new();
    {
        let mut uses: HashMap<&str, usize> = HashMap::new();
        for step in &steps {
            for n in step.inputs.iter().chain(&step.residual) {
                *uses.entry(n.as_str()).or_default() += 1;
            }
        }
        let written: HashMap<&str, bool> =
            steps.iter().map(|st| (st.output.as_str(), !matches!(ops[st.op].kind, OpKind::Slice { .. }))).collect();
        for step in &steps {
            if !matches!(ops[step.op].kind, OpKind::Concat) {
                continue;
            }
            let mut ch = 0;
            for x in &step.inputs {
                let once = step.inputs.iter().filter(|n| *n == x).count() == 1;
                if once && uses.get(x.as_str()) == Some(&1) && written.get(x.as_str()) == Some(&true) && !m.model.outputs.contains(x) {
                    place.insert(x, (&step.output, ch));
                }
                ch += shapes[x][0];
            }
        }
    }
    // root tensor and element offset in it
    fn root<'a>(place: &HashMap<&'a str, (&'a str, u32)>, shapes: &HashMap<String, [u32; 3]>, n: &'a str) -> (&'a str, u32) {
        let (mut r, mut off) = (n, 0u32);
        while let Some(&(parent, ch)) = place.get(r) {
            let [_, h, w] = shapes[parent];
            off += ch * h * w;
            r = parent;
        }
        (r, off)
    }
    let mut root_alloc: HashMap<&str, usize> = HashMap::new();
    for (s, step) in steps.iter().enumerate() {
        for n in step.inputs.iter().chain(&step.residual) {
            let a = at[n].0;
            allocs[a].last = allocs[a].last.max(s + 1);
        }
        if let OpKind::Slice { start, .. } = ops[step.op].kind {
            let src = &step.inputs[0];
            let (a, off) = at[src];
            let [_, h, w] = shapes[src];
            at.insert(step.output.clone(), (a, off + start * h * w));
        } else {
            let (r, off) = root(&place, &shapes, &step.output);
            let a = *root_alloc.entry(r).or_insert_with(|| {
                defs[s + 1].push(allocs.len());
                allocs.push(Alloc { elems: elems(shapes[r]), last: s + 1, slot: usize::MAX });
                allocs.len() - 1
            });
            at.insert(step.output.clone(), (a, off));
        }
    }
    for o in &m.model.outputs {
        allocs[at[o].0].last = usize::MAX;
    }
    // slots, best fit; step s + 1 of `defs` / `last` is steps[s] (0 is the model inputs)
    let mut slot_size: Vec<u64> = Vec::new();
    let mut free: Vec<usize> = Vec::new();
    for (t, born) in defs.iter().enumerate() {
        for &a in born {
            let need = allocs[a].elems;
            let fit = free.iter().enumerate().filter(|(_, &s)| slot_size[s] >= need).min_by_key(|(_, &s)| slot_size[s]).map(|(k, _)| k);
            let pick = fit.or_else(|| free.iter().enumerate().max_by_key(|(_, &s)| slot_size[s]).map(|(k, _)| k));
            let slot = match pick {
                Some(k) => free.swap_remove(k),
                None => {
                    slot_size.push(0);
                    slot_size.len() - 1
                }
            };
            slot_size[slot] = slot_size[slot].max(need);
            allocs[a].slot = slot;
        }
        for a in allocs.iter().filter(|a| a.last == t) {
            free.push(a.slot);
        }
    }
    let device = &m.ctx.device;
    let max_binding = device.limits().max_storage_buffer_binding_size;
    let buffers: Vec<wgpu::Buffer> = slot_size
        .iter()
        .enumerate()
        .map(|(k, &e)| {
            let size = (e * 4).max(16);
            if size > max_binding {
                return Err(Error::Gpu(format!("tensor buffer of {size} bytes is above the device limit {max_binding}")));
            }
            Ok(device.create_buffer(&wgpu::BufferDescriptor {
                label: Some(&format!("gpufx nn tensors {k}")),
                size,
                usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }))
        })
        .collect::<Result<_, _>>()?;
    let peak_bytes = buffers.iter().map(|b| b.size()).sum();
    let view = |n: &str| {
        let (a, offset) = at[n];
        let [c, h, w] = shapes[n];
        TensorView { slot: allocs[a].slot, offset, c, h, w }
    };

    // dispatches
    struct Pending {
        label: &'static str,
        kernel: Kernel,
        words: Words,
        src0: usize,
        src1: usize,
        dst: usize,
        groups: (u32, u32, u32),
    }
    let mut pend: Vec<Pending> = Vec::new();
    let mut details: Vec<String> = Vec::new();
    // Aliasing check: what a dispatch writes (slot, offset, len) must not overlap anything it reads in the
    // same slot, or threads would read values other threads already overwrote.
    type Range = (usize, u32, u32);
    let mut checks: Vec<(&str, Range, Vec<Range>)> = Vec::new();
    let range = |v: &TensorView| -> Range { (v.slot, v.offset, v.len()) };
    for step in &steps {
        let op = &ops[step.op];
        let out = view(&step.output);
        let fused = if step.residual.is_some() { "+add" } else { "" };
        let detail = format!("{}{fused} {}x{}x{}", op.name, out.c, out.h, out.w);
        let ins: Vec<TensorView> = step.inputs.iter().map(|n| view(n)).collect();
        let ew = |label, words: Words, a: &TensorView, b: &TensorView, n: u32| {
            let (gx, gy) = groups_1d(n, 256);
            Pending { label, kernel: Kernel::Fixed(Fixed::Ew), words, src0: a.slot, src1: b.slot, dst: out.slot, groups: (gx, gy, 1) }
        };
        // mode, n, out_off, use_scalar, out shape, a, b, scalar, ca, cb
        let ew_words = |mode: u32, use_scalar: bool, a: &TensorView, b: &TensorView, scalar: f32, ca: f32, cb: f32| {
            Words::default()
                .u(mode)
                .u(out.len())
                .u(out.offset)
                .u(use_scalar as u32)
                .u(out.c)
                .u(out.h)
                .u(out.w)
                .u(a.offset)
                .u(a.c)
                .u(a.h)
                .u(a.w)
                .u(b.offset)
                .u(b.c)
                .u(b.h)
                .u(b.w)
                .f(scalar)
                .f(ca)
                .f(cb)
        };
        match &op.kind {
            OpKind::Conv2d(c) | OpKind::Deconv2d(c) => {
                let x = &ins[0];
                let res = step.residual.as_deref().map(view);
                let (pre, pre_slope) = act_code(c.activation);
                let (post, post_slope) = act_code(step.post_act);
                let (w_off, b_off) = m.conv_weights[&step.op];
                let words = Words::default()
                    .u(x.c)
                    .u(x.h)
                    .u(x.w)
                    .u(out.c)
                    .u(out.h)
                    .u(out.w)
                    .u(c.pad[0])
                    .u(c.pad[1])
                    .u(x.offset)
                    .u(out.offset)
                    .u(res.map_or(0, |r| r.offset))
                    .u(w_off)
                    .u(b_off)
                    .u(pre)
                    .u(res.is_some() as u32)
                    .u(post)
                    .f(pre_slope)
                    .f(post_slope);
                let shape = conv_shape(c);
                let src1 = res.map_or(x.slot, |r| r.slot);
                if matches!(op.kind, OpKind::Conv2d(_)) {
                    let ocb = ConvConfig::ocb(out.c);
                    let cfg = ConvConfig::choose(&shape, ocb, out.w, out.h, out.c)
                        .ok_or_else(|| Error::Unsupported(format!("op {}: kernel {:?} is too large", op.name, c.kernel)))?;
                    let groups = (out.w.div_ceil(cfg.tx * cfg.px), out.h.div_ceil(cfg.ty), out.c.div_ceil(cfg.ocb));
                    pend.push(Pending {
                        label: "conv2d",
                        kernel: Kernel::Conv(shape, cfg),
                        words,
                        src0: x.slot,
                        src1,
                        dst: out.slot,
                        groups,
                    });
                } else {
                    let blocks = out.h.div_ceil(shape.sh) * out.w.div_ceil(shape.sw);
                    let (gx, gy) = groups_1d(blocks, kernels::DECONV_WG);
                    let groups = (gx, gy, out.c.div_ceil(kernels::DECONV_OCB));
                    let kernel = Kernel::Deconv(shape, c.pad[0] % shape.sh, c.pad[1] % shape.sw);
                    pend.push(Pending { label: "deconv2d", kernel, words, src0: x.slot, src1, dst: out.slot, groups });
                }
            }
            OpKind::Activation(a) => {
                let x = &ins[0];
                let (mode, slope) = match a {
                    Activation::Relu => (10, 0.0),
                    Activation::LeakyRelu { slope } => (11, *slope),
                    Activation::Sigmoid => (12, 0.0),
                };
                pend.push(ew("activation", ew_words(mode, true, x, x, slope, 1.0, 1.0), x, x, out.len()));
            }
            OpKind::Binary { kind, scalar } => {
                let a = &ins[0];
                let b = ins.get(1).unwrap_or(a);
                pend.push(ew("binary", ew_words(*kind as u32, scalar.is_some(), a, b, scalar.unwrap_or(0.0), 1.0, 1.0), a, b, out.len()));
            }
            OpKind::Eltwise { kind, coeffs } => {
                let a = &ins[0];
                let b = ins.get(1).unwrap_or(a);
                let ca = coeffs.as_ref().map_or(1.0, |c| c[0]);
                let cb = coeffs.as_ref().map_or(1.0, |c| c.get(1).copied().unwrap_or(1.0));
                let words = match (ins.len(), kind) {
                    (1, EltwiseKind::Sum) => ew_words(9, true, a, a, 0.0, ca, 1.0),
                    (1, _) => ew_words(9, true, a, a, 0.0, 1.0, 1.0),
                    (_, EltwiseKind::Sum) => ew_words(13, false, a, b, 0.0, ca, cb),
                    (_, EltwiseKind::Prod) => ew_words(BinaryKind::Mul as u32, false, a, b, 0.0, 1.0, 1.0),
                    (_, EltwiseKind::Max) => ew_words(BinaryKind::Max as u32, false, a, b, 0.0, 1.0, 1.0),
                };
                pend.push(ew("eltwise", words, a, b, out.len()));
            }
            OpKind::Concat => {
                let mut off = out.offset;
                for x in &ins {
                    if x.slot == out.slot && x.offset == off {
                        // written in place
                        off += x.len();
                        continue;
                    }
                    let dst = TensorView { offset: off, ..*x };
                    let words = Words::default()
                        .u(9)
                        .u(x.len())
                        .u(off)
                        .u(1)
                        .u(dst.c)
                        .u(dst.h)
                        .u(dst.w)
                        .u(x.offset)
                        .u(x.c)
                        .u(x.h)
                        .u(x.w)
                        .u(x.offset)
                        .u(x.c)
                        .u(x.h)
                        .u(x.w)
                        .f(0.0)
                        .f(1.0)
                        .f(1.0);
                    checks.push((&op.name, (out.slot, off, x.len()), vec![range(x)]));
                    pend.push(ew("concat", words, x, x, x.len()));
                    off += x.len();
                }
            }
            OpKind::Slice { .. } => {}
            OpKind::Resize { mode, scale, size, align_corners } => {
                let x = &ins[0];
                let (sy, sx) = match (size, scale) {
                    (None, Some([sh, sw])) => (*sh, *sw),
                    _ => (0.0, 0.0),
                };
                let mode = match mode {
                    ResizeMode::Nearest => 0,
                    ResizeMode::Bilinear => 1,
                    ResizeMode::Bicubic => 2,
                };
                let words = Words::default()
                    .u(out.plane())
                    .u(out.c)
                    .u(x.h)
                    .u(x.w)
                    .u(out.h)
                    .u(out.w)
                    .u(x.offset)
                    .u(out.offset)
                    .u(mode)
                    .u(*align_corners as u32)
                    .f(sy)
                    .f(sx);
                let (gx, gy) = groups_1d(out.plane(), 256);
                pend.push(Pending {
                    label: "resize",
                    kernel: Kernel::Fixed(Fixed::Resize),
                    words,
                    src0: x.slot,
                    src1: x.slot,
                    dst: out.slot,
                    groups: (gx, gy, 1),
                });
            }
            OpKind::PixelShuffle(r) => {
                let x = &ins[0];
                let words = Words::default().u(out.len()).u(out.h).u(out.w).u(*r).u(x.h).u(x.w).u(x.offset).u(out.offset);
                let (gx, gy) = groups_1d(out.len(), 256);
                pend.push(Pending {
                    label: "pixel_shuffle",
                    kernel: Kernel::Fixed(Fixed::PixelShuffle),
                    words,
                    src0: x.slot,
                    src1: x.slot,
                    dst: out.slot,
                    groups: (gx, gy, 1),
                });
            }
            OpKind::Warp => {
                let (img, flow) = (&ins[0], &ins[1]);
                let words = Words::default().u(img.c).u(img.h).u(img.w).u(img.offset).u(flow.offset).u(out.offset);
                pend.push(Pending {
                    label: "warp",
                    kernel: Kernel::Fixed(Fixed::Warp),
                    words,
                    src0: img.slot,
                    src1: flow.slot,
                    dst: out.slot,
                    groups: (img.w.div_ceil(16), img.h.div_ceil(16), 1),
                });
            }
        }
        if !matches!(op.kind, OpKind::Concat | OpKind::Slice { .. }) {
            let mut reads: Vec<Range> = ins.iter().map(range).collect();
            reads.extend(step.residual.as_deref().map(view).as_ref().map(range));
            checks.push((&op.name, range(&out), reads));
        }
        details.resize(pend.len(), detail);
    }
    for (name, (slot, off, len), reads) in &checks {
        for &(rslot, roff, rlen) in &reads[..] {
            let overlap = rslot == *slot && (*len > 0 && rlen > 0) && roff < off + len && *off < roff + rlen;
            if overlap {
                return Err(Error::Gpu(format!(
                    "internal: aliasing in op {name}: writes [{off}, {}) of buffer {slot} and reads [{roff}, {}) of it",
                    off + len,
                    roff + rlen
                )));
            }
        }
    }

    let mut bytes = vec![0u8; pend.len().max(1) * PARAM_SLOT as usize];
    for (k, p) in pend.iter().enumerate() {
        for (j, w) in p.words.0.iter().enumerate() {
            bytes[k * PARAM_SLOT as usize + j * 4..][..4].copy_from_slice(&w.to_le_bytes());
        }
    }
    let params = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("gpufx nn params"),
        size: bytes.len() as u64,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    m.ctx.queue.write_buffer(&params, 0, &bytes);
    let dispatches = pend
        .iter()
        .enumerate()
        .map(|(k, p)| {
            let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("gpufx nn op"),
                layout: &m.kernels.layout,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                            buffer: &params,
                            offset: k as u64 * PARAM_SLOT,
                            size: wgpu::BufferSize::new(PARAM_SLOT),
                        }),
                    },
                    wgpu::BindGroupEntry { binding: 1, resource: buffers[p.src0].as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 2, resource: buffers[p.src1].as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 3, resource: m.weights.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 4, resource: m.weights.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 5, resource: buffers[p.dst].as_entire_binding() },
                ],
            });
            Dispatch { label: p.label, detail: details[k].clone(), pipeline: m.kernels.get(device, p.kernel), group, groups: p.groups }
        })
        .collect();
    let mut tensors = HashMap::new();
    for n in m.model.inputs.iter().chain(&m.model.outputs) {
        tensors.insert(n.clone(), view(n));
    }
    Ok(NnPlan { buffers, tensors, dispatches, _params: params, peak_bytes, device: device.clone(), queue: m.ctx.queue.clone() })
}

impl NnPlan {
    /// Records every op of the graph.
    pub fn encode(&self, cpass: &mut wgpu::ComputePass) {
        for d in &self.dispatches {
            cpass.set_pipeline(&d.pipeline);
            cpass.set_bind_group(0, &d.group, &[]);
            cpass.dispatch_workgroups(d.groups.0, d.groups.1, d.groups.2);
        }
    }

    /// Where a model input or output lives.
    pub fn tensor(&self, name: &str) -> Option<TensorView> {
        self.tensors.get(name).copied()
    }

    pub fn buffer(&self, slot: usize) -> &wgpu::Buffer {
        &self.buffers[slot]
    }

    /// Bytes of all tensor buffers (the most the plan ever holds).
    pub fn tensor_bytes(&self) -> u64 {
        self.peak_bytes
    }

    pub fn buffer_count(&self) -> usize {
        self.buffers.len()
    }

    pub fn dispatch_count(&self) -> usize {
        self.dispatches.len()
    }

    /// Writes the values of a model input (`c * h * w` of them).
    pub fn write_input(&self, name: &str, data: &[f32]) -> Result<(), Error> {
        let t = self.tensor(name).ok_or_else(|| Error::Graph(format!("no tensor \"{name}\"")))?;
        if data.len() != t.len() as usize {
            return Err(Error::Graph(format!("input \"{name}\" takes {} values, got {}", t.len(), data.len())));
        }
        let bytes: Vec<u8> = data.iter().flat_map(|v| v.to_le_bytes()).collect();
        self.queue.write_buffer(&self.buffers[t.slot], t.offset as u64 * 4, &bytes);
        Ok(())
    }

    /// Runs the graph once and waits.
    pub fn run(&self) -> Result<(), Error> {
        let mut enc = self.device.create_command_encoder(&Default::default());
        {
            let mut cpass = enc.begin_compute_pass(&Default::default());
            self.encode(&mut cpass);
        }
        self.queue.submit([enc.finish()]);
        self.device.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| Error::Gpu(e.to_string()))?;
        Ok(())
    }

    /// Reads a model output (or input) back, waiting for the GPU.
    pub fn read(&self, name: &str) -> Result<Vec<f32>, Error> {
        let t = self.tensor(name).ok_or_else(|| Error::Graph(format!("no tensor \"{name}\"")))?;
        let size = t.len() as u64 * 4;
        let staging = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx nn readback"),
            size: size.max(4),
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut enc = self.device.create_command_encoder(&Default::default());
        enc.copy_buffer_to_buffer(&self.buffers[t.slot], t.offset as u64 * 4, &staging, 0, size);
        self.queue.submit([enc.finish()]);
        read_buffer(&self.device, &staging, |b| b.as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect())
    }

    /// GPU time per kind of op, in ms, from timing every dispatch `repeat` times on its own (wall clock).
    pub fn profile(&self, repeat: u32) -> Result<Profile, Error> {
        let mut total: Vec<(&'static str, f64, usize)> = Vec::new();
        let mut each = Vec::new();
        for d in &self.dispatches {
            let mut enc = self.device.create_command_encoder(&Default::default());
            {
                let mut cpass = enc.begin_compute_pass(&Default::default());
                cpass.set_pipeline(&d.pipeline);
                cpass.set_bind_group(0, &d.group, &[]);
                cpass.dispatch_workgroups(d.groups.0, d.groups.1, d.groups.2);
            }
            self.queue.submit([enc.finish()]);
            self.device.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| Error::Gpu(e.to_string()))?;
            let start = Instant::now();
            let mut enc = self.device.create_command_encoder(&Default::default());
            {
                let mut cpass = enc.begin_compute_pass(&Default::default());
                cpass.set_pipeline(&d.pipeline);
                cpass.set_bind_group(0, &d.group, &[]);
                for _ in 0..repeat {
                    cpass.dispatch_workgroups(d.groups.0, d.groups.1, d.groups.2);
                }
            }
            self.queue.submit([enc.finish()]);
            self.device.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| Error::Gpu(e.to_string()))?;
            let ms = start.elapsed().as_secs_f64() * 1e3 / repeat as f64;
            each.push((d.detail.clone(), ms));
            match total.iter_mut().find(|t| t.0 == d.label) {
                Some(t) => {
                    t.1 += ms;
                    t.2 += 1;
                }
                None => total.push((d.label, ms, 1)),
            }
        }
        total.sort_by(|a, b| b.1.total_cmp(&a.1));
        Ok(Profile { by_kind: total, dispatches: each })
    }
}

/// Times of [`NnPlan::profile`]: per kind of op (kind, ms, dispatches), slowest first, and per dispatch in
/// order (op name and output shape, ms).
pub struct Profile {
    pub by_kind: Vec<(&'static str, f64, usize)>,
    pub dispatches: Vec<(String, f64)>,
}

/// Maps `buffer` (MAP_READ), waits, and converts its bytes.
pub(crate) fn read_buffer<T>(device: &wgpu::Device, buffer: &wgpu::Buffer, f: impl FnOnce(&[u8]) -> T) -> Result<T, Error> {
    let slice = buffer.slice(..);
    let (tx, rx) = std::sync::mpsc::channel();
    slice.map_async(wgpu::MapMode::Read, move |r| {
        let _ = tx.send(r);
    });
    device.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| Error::Gpu(e.to_string()))?;
    rx.recv().map_err(|e| Error::Gpu(e.to_string()))?.map_err(|e| Error::Gpu(e.to_string()))?;
    let out = {
        let mapped = slice.get_mapped_range().map_err(|e| Error::Gpu(e.to_string()))?;
        f(&mapped)
    };
    buffer.unmap();
    Ok(out)
}
