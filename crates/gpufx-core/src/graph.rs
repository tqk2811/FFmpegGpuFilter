//! Effects wired as a graph (a DAG) and run in one GPU submission: chains
//! (`a.zip|b.zip`, one statement without labels) and graphs (`[0]split[a][b]; [a]blur.zip[x]; ...`) share this engine.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::convert::{read_outputs, readback_key, work_format, GpuOutputSlot, InputKey, InputSlot, LayoutConvert, OutputSlot};
use crate::frame::{Frame, FrameMut, GpuFrame, PixelFormat};
use crate::manifest::{PixelLayout, Plane, StreamInfo};
use crate::mips::MipChain;
use crate::params::ParamBlock;
use crate::pool::PoolKey;
use crate::runtime::{plane_format, Effect, FrameInfo, Image, ImageMut};
use crate::Error;

/// Where an effect input or a graph output takes its frame from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// An input pad of the graph (`[0]`, `[1]`...).
    Input(usize),
    /// Output `o` (manifest order) of effect `k`, by its index in [`EffectGraph::effects`]:
    /// `Node(k, o)`.
    Node(usize, usize),
}

/// The input pad the outputs of a bypassed graph pass (see [`EffectGraph::set_bypass_pad`]).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum BypassPad {
    /// The pad each output has the size of (following first inputs), as without effects.
    #[default]
    First,
    /// The pad reached through the input each effect passes when switched off
    /// ([`EffectGraph::set_node_bypass`]): what the effects give with every one off.
    Nodes,
    /// This pad, for every output.
    Pad(usize),
}

/// The wiring of a graph: every effect input and graph output names its source.
pub(crate) struct Topology {
    pub nb_inputs: usize,
    /// The sources of the inputs of each effect, in manifest order.
    pub node_inputs: Vec<Vec<Source>>,
    /// Effects in an order where each comes after the effects it reads.
    pub order: Vec<usize>,
    pub outputs: Vec<Source>,
}

impl Topology {
    /// One effect of one output reading every input pad.
    pub fn single(nb_inputs: usize) -> Self {
        Topology {
            nb_inputs,
            node_inputs: vec![(0..nb_inputs).map(Source::Input).collect()],
            order: vec![0],
            outputs: vec![Source::Node(0, 0)],
        }
    }

    /// The input pad `src` follows: an effect follows its first input. It has that pad's
    /// size unless an effect on the way stacks its inputs (see [`node_size`]).
    pub fn pad_of(&self, src: Source) -> usize {
        match src {
            Source::Input(i) => i,
            Source::Node(j, _) => self.pad_of(self.node_inputs[j][0]),
        }
    }

    /// The input pad output `src` passes when bypassed: output `o` of effect `j` hands on
    /// its input `bypass(j, o)`, down to a pad.
    pub fn bypass_pad(&self, src: Source, bypass: &dyn Fn(usize, usize) -> usize) -> usize {
        match src {
            Source::Input(i) => i,
            Source::Node(j, o) => self.bypass_pad(self.node_inputs[j][bypass(j, o)], bypass),
        }
    }

    /// Output `o` of effect `k` is read by an effect or is an output of the graph. The
    /// others are dropped: no texture, and no pass runs only for them.
    pub fn used(&self, k: usize, o: usize) -> bool {
        let src = Source::Node(k, o);
        self.outputs.contains(&src) || self.node_inputs.iter().flatten().any(|s| *s == src)
    }
}

/// GPU memory a graph holds for its current frame sizes and formats.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MemoryStats {
    /// Pooled textures for pass outputs, chain links and graph edges. Textures whose
    /// lifetimes do not overlap share one, so this is the peak number alive at once.
    pub pass_textures: usize,
    pub pass_texture_bytes: u64,
    /// Upload textures of the inputs: the planes and, unless straight RGBA, the
    /// converted frame. One set per input pad, whatever reads it.
    pub input_textures: usize,
    pub input_texture_bytes: u64,
    /// The one mappable buffer every output is read back through.
    pub readback_bytes: u64,
}

/// Frame upload, conversion and readback resources, shared by the effects of a graph.
#[derive(Default)]
pub(crate) struct FrameIo {
    /// How many times textures or bind groups were made; see [`EffectGraph::allocations`].
    allocations: usize,
    /// The frames of the graph carry more than 8 bits: see [`work_format`].
    deep: bool,
    inputs: Vec<InputSlot>,
    outputs: Vec<OutputSlot>,
    /// Outputs written into GPU frames.
    gpu_outputs: Vec<GpuOutputSlot>,
    /// Size of the readback buffer of the outputs, and the pool's id of the one borrowed
    /// last time. It is borrowed apart from the rest: the CPU maps it after the submission,
    /// so it is given back only once unmapped.
    readback_size: u64,
    readback_id: Option<u64>,
    memory: MemoryStats,
    /// Mip chains of the input pads and effect outputs (by effect, by output) an effect
    /// input wants mipmapped.
    input_mips: Vec<Option<MipChain>>,
    node_mips: Vec<Vec<Option<MipChain>>>,
    /// What `prepare` planned for the current inputs; the textures come from the pool.
    layout: Option<Layout>,
    /// Ids of the pooled resources the bind groups were made for: the input slots and
    /// pass textures, then the output words. Another id back from the pool rebinds.
    bound_ids: Vec<u64>,
    out_ids: Vec<u64>,
    /// Borrowed for the frame being recorded, given back once it is submitted.
    borrowed: Vec<u64>,
    /// The pool's id of this borrower, and the context of the pool.
    user: u64,
    ctx: Option<Arc<crate::GpuContext>>,
    /// Timings of GPU frames, with `GPUFX_PROFILE` set (see [`crate::profile`]).
    pub(crate) prof: Option<crate::profile::Profiler>,
    /// Vulkan frames may be read in place (see `prepare`).
    pub(crate) direct_gpu: bool,
    /// The input textures of the GPU frame being recorded, for the slots made for it.
    frame_ins: Vec<Vec<wgpu::Texture>>,
    /// The output textures of that frame, for the effects writing them in place.
    frame_outs: Vec<Option<wgpu::Texture>>,
    /// Bind groups made for the textures of GPU frames (input and output passes, effects
    /// bound to frames in place); those of a recent frame are reused.
    frame_binds: usize,
    /// Effects switched off (`<effect>.enable`), by index; empty when all are on. An
    /// effect switched off copies an input into each output texture instead of running,
    /// so the plan and the bindings of the others stay as they are.
    enabled: Vec<bool>,
    /// The copies of the effects switched off for the frame being recorded (by effect, by
    /// output), and those made for recent textures (frames read or written in place
    /// change every frame).
    copy_groups: Vec<Vec<Option<wgpu::BindGroup>>>,
    copies: Vec<crate::lru::Lru<(wgpu::Texture, wgpu::Texture), wgpu::BindGroup>>,
    /// The input each effect switched off copies into every output (`<effect>.bypass`),
    /// by index; `None` (or empty) when each output copies the input its manifest
    /// `bypass` names.
    bypass: Vec<Option<usize>>,
    /// The input pad every output passes when the whole graph is bypassed.
    bypass_pad: BypassPad,
    /// The pad each output slot is bound to in bypass, to rebind when it changes.
    bypass_bound: Vec<usize>,
    /// The layout converts of the plan, made for the pooled textures: (index in
    /// `Plan::converts`, pass), in recording order; and the textures each one writes.
    converts: Vec<(usize, LayoutConvert)>,
    convert_dsts: Vec<Vec<wgpu::Texture>>,
    /// The matrix and range of the layout converts: those of the first input frame.
    color: crate::frame::ColorInfo,
    /// The layout converts standing for the copies of effects switched off, by effect, by
    /// output, for an input or output with planes; with the source textures they were made for.
    off_converts: Vec<Vec<Option<OffConvert>>>,
}

/// A layout convert standing for the copy of an effect switched off, with the source and
/// destination textures it was made for.
type OffConvert = ((Vec<wgpu::Texture>, Vec<wgpu::Texture>), LayoutConvert);

/// The planned textures of a graph for one set of inputs.
struct Layout {
    keys: Vec<InputKey>,
    plan: Plan,
    /// Size of every effect output, by effect, by output.
    sizes: Vec<Vec<(u32, u32)>>,
    pad_mips: Vec<bool>,
    node_mips: Vec<Vec<bool>>,
    /// For each output of each effect, the output frame its pass writes in place, if any.
    direct_out: Vec<Vec<Option<usize>>>,
    /// By graph output: written straight from the planes of its source (see [`planar_outputs`]).
    planar_out: Vec<bool>,
}

impl FrameIo {
    fn enabled(&self, k: usize) -> bool {
        self.enabled.get(k).copied().unwrap_or(true)
    }

    /// The input output `o` of effect `k` copies when the effect is switched off: the one
    /// `<effect>.bypass` picked, else the one its manifest `bypass` names.
    fn bypass(&self, effects: &[Effect], k: usize, o: usize) -> usize {
        match self.bypass.get(k).copied().flatten() {
            Some(i) => i,
            None => effects[k].package().manifest.output_bypass(o),
        }
    }

    /// Whether layout convert `n` of the plan has a reader this frame: an effect that is on,
    /// or a graph output. An effect switched off copies its sources, not its converts.
    fn convert_read(&self, n: usize) -> bool {
        let Some(plan) = self.layout.as_ref().map(|l| &l.plan) else { return true };
        plan.output_convert.contains(&Some(n))
            || plan.input_convert.iter().enumerate().any(|(k, ins)| self.enabled(k) && ins.contains(&Some(n)))
    }

    /// The input pad output `k` passes when the whole graph is bypassed.
    fn out_pad(&self, effects: &[Effect], topo: &Topology, k: usize) -> usize {
        match self.bypass_pad {
            BypassPad::First => topo.pad_of(topo.outputs[k]),
            BypassPad::Nodes => topo.bypass_pad(topo.outputs[k], &|j, o| self.bypass(effects, j, o)),
            BypassPad::Pad(p) => p,
        }
    }

    /// Picks the copies of every effect switched off, once the effects are bound for the
    /// frame: for each output in use, from its chosen input (`bypass`) to its texture.
    /// Effects that are on get none. Fails when that input has another size than the output.
    fn bind_copies(&mut self, effects: &[Effect], topo: &Topology) -> Result<(), Error> {
        let ctx = &effects[0].program.ctx;
        self.copy_groups.clear();
        self.copy_groups.resize(effects.len(), Vec::new());
        self.off_converts.resize_with(effects.len(), Vec::new);
        for (k, c) in self.off_converts.iter_mut().enumerate() {
            if self.enabled.get(k).copied().unwrap_or(true) {
                c.clear();
            }
        }
        if self.enabled.iter().all(|&on| on) {
            return Ok(());
        }
        self.copies.resize_with(effects.len(), Default::default);
        let pads: Vec<PixelLayout> = self.inputs.iter().map(|s| s.key.layout).collect();
        for k in 0..effects.len() {
            if self.enabled(k) {
                continue;
            }
            let mut groups = vec![None; effects[k].output_count()];
            self.off_converts[k].resize_with(effects[k].output_count(), || None);
            for (o, group) in groups.iter_mut().enumerate() {
                if !topo.used(k, o) {
                    self.off_converts[k][o] = None;
                    continue;
                }
                let i = self.bypass(effects, k, o);
                let source = topo.node_inputs[k][i];
                let (from, to) = (source_layout(effects, &pads, source), effects[k].package().manifest.outputs[o].pixel_layout);
                let planes = from != PixelLayout::Rgba || to != PixelLayout::Rgba;
                let (src, dst) = if planes {
                    (source_planes(effects, &self.inputs, source), effects[k].output_planes(o))
                } else {
                    (vec![source_texture(effects, &self.inputs, source)], vec![effects[k].output(o).clone()])
                };
                let (src, dst, srcs, dsts) = (src[0].clone(), dst[0].clone(), src, dst);
                if (src.width(), src.height()) != (dst.width(), dst.height()) {
                    let what = if effects[k].output_count() == 1 {
                        "its output".to_string()
                    } else {
                        format!("its output `{}`", effects[k].package().manifest.outputs[o].name)
                    };
                    return Err(Error::Frame(format!(
                        "effect {k} is switched off and passes its input {i}, which is {}x{} while {what} is {}x{}",
                        src.width(),
                        src.height(),
                        dst.width(),
                        dst.height()
                    )));
                }
                if planes {
                    // Through a layout convert, from the planes of the source to those of the
                    // output (the same values when the layouts are the same).
                    // Made again when either side was bound to other textures. The sizes of
                    // Y (or RGBA) were checked equal above, as for the RGBA copy, so the
                    // convert reads no texel outside the source.
                    let fresh = !matches!(&self.off_converts[k][o], Some(((s, d), _)) if *s == srcs && *d == dsts);
                    if fresh {
                        let size = (dst.width(), dst.height());
                        let c = LayoutConvert::new(&ctx.device, &ctx.conv, (from, to), &srcs, &dsts, size, self.deep, ctx.plane_f16);
                        self.off_converts[k][o] = Some(((srcs, dsts), c));
                        self.frame_binds += 1;
                    }
                    continue;
                }
                let made = self.copies[k].get_or_make((src, dst), |(src, dst)| Ok::<_, Error>(ctx.mips.copy_group(&ctx.device, src, dst)));
                let (made_group, made) = made.expect("infallible");
                *group = Some(made_group.clone());
                self.frame_binds += made as usize;
            }
            self.copy_groups[k] = groups;
        }
        Ok(())
    }

    /// Gives back what the last frame borrowed: its submission was made (or nothing was).
    pub(crate) fn release(&mut self) {
        if let Some(ctx) = &self.ctx {
            if !self.borrowed.is_empty() {
                ctx.pool.give_back(self.user, &std::mem::take(&mut self.borrowed));
            }
        }
    }
}

impl Drop for FrameIo {
    fn drop(&mut self) {
        self.release();
    }
}

/// Which input pads and effect outputs (by effect, by output) some effect reads through
/// a `mipmaps` input.
fn mip_sources(effects: &[Effect], topo: &Topology) -> (Vec<bool>, Vec<Vec<bool>>) {
    let mut pads = vec![false; topo.nb_inputs];
    let mut nodes: Vec<Vec<bool>> = effects.iter().map(|fx| vec![false; fx.output_count()]).collect();
    for (k, sources) in topo.node_inputs.iter().enumerate() {
        for (def, src) in effects[k].package().manifest.inputs.iter().zip(sources) {
            if def.mipmaps {
                match *src {
                    Source::Input(i) => pads[i] = true,
                    Source::Node(j, o) => nodes[j][o] = true,
                }
            }
        }
    }
    (pads, nodes)
}

/// A pooled texture: size, whether it has a mip chain, and the plane it holds (its format).
type Slot = (u32, u32, bool, Plane);

/// Fails for an effect output with planes some effect reads through a `mipmaps` input: the
/// mip chain is made of the output's own texture, which an output with planes does not have.
fn check_plane_mips(effects: &[Effect], node_mips: &[Vec<bool>]) -> Result<(), Error> {
    for (k, mips) in node_mips.iter().enumerate() {
        for (o, _) in mips.iter().enumerate().filter(|(_, &m)| m) {
            let def = &effects[k].package().manifest.outputs[o];
            if def.pixel_layout != PixelLayout::Rgba {
                return Err(Error::Manifest(format!(
                    "output `{}` of `{}` has pixel_layout planes, and is read by a `mipmaps` input",
                    def.name,
                    effects[k].package().manifest.name
                )));
            }
        }
    }
    Ok(())
}

/// Which input pads an effect reads in another layout than the pad's (`layouts`), through
/// a layout convert.
fn converted_pads(effects: &[Effect], topo: &Topology, layouts: &[PixelLayout]) -> Vec<bool> {
    let mut pads = vec![false; topo.nb_inputs];
    for (k, sources) in topo.node_inputs.iter().enumerate() {
        for (def, src) in effects[k].package().manifest.inputs.iter().zip(sources) {
            if let Source::Input(i) = *src {
                pads[i] |= def.pixel_layout != layouts.get(i).copied().unwrap_or_default();
            }
        }
    }
    pads
}

/// The layout each input pad is read in: the planes of its frame format's own
/// [`PixelFormat::pixel_layout`], loaded straight from the frame, when every effect input
/// reading the pad wants planes (those wanting another layout of planes read a plane to
/// plane layout convert); else `rgba` (the conversion to RGBA, then a layout convert for
/// each reader wanting planes). A pad no effect reads, read by a graph output
/// itself or through a `mipmaps` input, with premultiplied alpha, or in a bypass call
/// (its outputs read the pads as RGBA) stays `rgba`.
fn pad_layouts(effects: &[Effect], topo: &Topology, inputs: &[Desc], pad_mips: &[bool], bypass: bool) -> Vec<PixelLayout> {
    (0..topo.nb_inputs)
        .map(|i| {
            let Some(f) = inputs.get(i) else { return PixelLayout::Rgba };
            let own = f.format.pixel_layout();
            if bypass || own == PixelLayout::Rgba || f.premultiplied || pad_mips[i] || topo.outputs.contains(&Source::Input(i)) {
                return PixelLayout::Rgba;
            }
            let wants: Vec<PixelLayout> = topo
                .node_inputs
                .iter()
                .enumerate()
                .flat_map(|(k, sources)| sources.iter().zip(&effects[k].package().manifest.inputs))
                .filter(|(s, _)| **s == Source::Input(i))
                .map(|(_, d)| d.pixel_layout)
                .collect();
            if !wants.is_empty() && wants.iter().all(|&l| l != PixelLayout::Rgba) {
                own
            } else {
                PixelLayout::Rgba
            }
        })
        .collect()
}

/// Which graph outputs are written straight from the planes of their source: an effect
/// output with planes, into a frame format of the same layout (see
/// [`PixelFormat::pixel_layout`]) with straight alpha.
fn planar_outputs(effects: &[Effect], topo: &Topology, outs: &[Desc]) -> Vec<bool> {
    topo.outputs
        .iter()
        .zip(outs)
        .map(|(src, o)| {
            let layout = match *src {
                Source::Node(j, k) => effects[j].package().manifest.outputs[k].pixel_layout,
                Source::Input(_) => PixelLayout::Rgba,
            };
            layout != PixelLayout::Rgba && o.format.pixel_layout() == layout && !o.premultiplied
        })
        .collect()
}

/// The textures of `src`, one per plane of its layout: an input pad's slot (`rgba`), or
/// the planes of an effect output.
fn source_planes(effects: &[Effect], inputs: &[InputSlot], src: Source) -> Vec<wgpu::Texture> {
    match src {
        Source::Input(i) => inputs[i].read_planes(),
        Source::Node(j, o) => effects[j].output_planes(o),
    }
}

/// The input textures effect `k` is bound with, in [`crate::Manifest::input_keys`] order:
/// the planes of each source, or those of the layout convert of an input reading a source
/// of another layout.
fn effect_inputs(effects: &[Effect], topo: &Topology, io: &FrameIo, plan: &Plan, k: usize) -> Vec<wgpu::Texture> {
    topo.node_inputs[k]
        .iter()
        .enumerate()
        .flat_map(|(i, &src)| match plan.input_convert[k][i] {
            Some(c) => io.convert_dsts[c].clone(),
            None => source_planes(effects, &io.inputs, src),
        })
        .collect()
}

/// The RGBA texture graph output `n` reads, from `src`: the layout convert to `rgba` of an
/// effect output with planes, else the source itself.
fn output_texture(effects: &[Effect], io: &FrameIo, n: usize, src: Source) -> wgpu::Texture {
    match io.layout.as_ref().and_then(|l| l.plan.output_convert.get(n).copied().flatten()) {
        Some(c) => io.convert_dsts[c][0].clone(),
        None => source_texture(effects, &io.inputs, src),
    }
}

/// Which pooled texture each pass output gets, and the size of each pooled texture.
struct Plan {
    /// By effect: the pooled texture of each pass texture key (see [`PixelLayout::plane_key`]).
    assign: Vec<HashMap<String, usize>>,
    slots: Vec<Slot>,
    /// The layout converts of the graph (see [`LayoutConvert`]): one per source and
    /// `pixel_layout` some effect input or graph output wants another layout of.
    converts: Vec<ConvertPlan>,
    /// By effect, by input: the convert the input reads, if its source has another layout.
    input_convert: Vec<Vec<Option<usize>>>,
    /// By graph output: the convert to `rgba` it reads, for an effect output with planes.
    output_convert: Vec<Option<usize>>,
}

/// One layout convert of a [`Plan`].
struct ConvertPlan {
    src: Source,
    from: PixelLayout,
    to: PixelLayout,
    /// Size of Y (of the source).
    size: (u32, u32),
    /// The pooled textures it writes, one per plane of `to`.
    slots: Vec<usize>,
    /// The effect it runs right before (its first reader), or `None`: after every effect,
    /// for a graph output only.
    before: Option<usize>,
    /// The last pass reading it, in execution order (see `plan`).
    end: usize,
}

impl Plan {
    fn bytes(&self, deep: bool, f16: bool) -> u64 {
        self.slots
            .iter()
            .map(|&(w, h, mips, plane)| {
                let texel = plane_format(plane, deep, f16).block_copy_size(None).unwrap_or(4) as u64;
                w as u64 * h as u64 * texel + if mips { crate::mips::chain_bytes(w, h, texel) } else { 0 }
            })
            .sum()
    }
}

/// The `pixel_layout` of a source: an input pad in the layout it is read in (`pads`, see
/// [`pad_layouts`]), an effect output in the layout its manifest gives.
fn source_layout(effects: &[Effect], pads: &[PixelLayout], src: Source) -> PixelLayout {
    match src {
        Source::Input(i) => pads[i],
        Source::Node(j, o) => effects[j].package().manifest.outputs[o].pixel_layout,
    }
}

/// For each output of each effect, the output frame its pass may write in place of a
/// pooled texture and a copy: a straight RGBA8 output (the storage format of a pass that
/// is not deep) that is the only use of that effect output: read by no other effect, by
/// no mip chain and by no other pass of the effect, nor written by another pass.
fn direct_outputs(effects: &[Effect], topo: &Topology, outs: &[Desc], node_mips: &[Vec<bool>]) -> Vec<Vec<Option<usize>>> {
    let mut direct: Vec<Vec<Option<usize>>> = effects.iter().map(|fx| vec![None; fx.output_count()]).collect();
    for (j, (src, out)) in topo.outputs.iter().zip(outs).enumerate() {
        let Source::Node(k, o) = *src else { continue };
        if out.format != PixelFormat::Rgba || out.premultiplied || node_mips[k][o] || source_layout(effects, &[], *src) != PixelLayout::Rgba
        {
            continue;
        }
        if topo.outputs.iter().filter(|s| **s == *src).count() != 1 || topo.node_inputs.iter().flatten().any(|s| s == src) {
            continue;
        }
        // The compiled passes that run: their inputs are resolved.
        let Ok(passes) = effects[k].passes(false) else { continue };
        let running: Vec<&crate::runtime::Pass> = passes.iter().enumerate().filter(|(i, _)| effects[k].runs(*i)).map(|(_, p)| p).collect();
        let name = &effects[k].package().manifest.outputs[o].name;
        let elsewhere = running.iter().any(|p| p.inputs.contains(name)) || running.iter().filter(|p| p.outputs.contains(name)).count() != 1;
        if !elsewhere {
            direct[k][o] = Some(j);
        }
    }
    direct
}

/// Assigns the pass outputs of every effect to pooled textures: a texture goes back to
/// the pool (per size and plane) after the last pass that reads it, counted over the whole
/// graph in execution order. Graph outputs stay alive until they are read back. The effect
/// outputs in `mips` get pooled textures with a mip chain, kept apart from the others.
/// Passes that do not run (outputs nobody uses) get nothing. A texture of a layout with
/// planes takes one pooled texture per plane, while its liveness stays that of its name.
/// An effect input reading a source of another `pixel_layout` reads a layout convert run
/// before the effect, alive through its passes; the convert is shared by the readers of
/// the same source in the same layout, and a graph output with planes reads one to `rgba`
/// unless it is written straight from its planes (`planar_out`).
#[allow(clippy::too_many_arguments)]
fn plan(
    effects: &[Effect],
    topo: &Topology,
    pads: &[(u32, u32)],
    sizes: &[Vec<(u32, u32)>],
    mips: &[Vec<bool>],
    direct_out: &[Vec<Option<usize>>],
    pad_layouts: &[PixelLayout],
    planar_out: &[bool],
    deep: bool,
) -> Result<Plan, Error> {
    let finals: Vec<Vec<&str>> =
        effects.iter().map(|fx| fx.program.package.manifest.outputs.iter().map(|o| o.name.as_str()).collect()).collect();
    let mut last: HashMap<(usize, &str), usize> = HashMap::new();
    fn bump<'a>(last: &mut HashMap<(usize, &'a str), usize>, key: (usize, &'a str), g: usize) {
        let end = last.entry(key).or_insert(g);
        *end = (*end).max(g);
    }
    let mut converts: Vec<ConvertPlan> = Vec::new();
    let mut input_convert: Vec<Vec<Option<usize>>> = effects.iter().map(|fx| vec![None; fx.input_count()]).collect();
    let convert_of = |converts: &mut Vec<ConvertPlan>, src: Source, to: PixelLayout, before: Option<usize>, end: usize| {
        if let Some(c) = converts.iter().position(|c| c.src == src && c.to == to) {
            converts[c].end = converts[c].end.max(end);
            return c;
        }
        let from = source_layout(effects, pad_layouts, src);
        converts.push(ConvertPlan { src, from, to, size: source_size(src, pads, sizes), slots: Vec::new(), before, end });
        converts.len() - 1
    };
    let mut g = 0;
    for &k in &topo.order {
        let m = &effects[k].program.package.manifest;
        let passes = effects[k].passes(deep)?;
        let runs = (0..passes.len()).filter(|&i| effects[k].runs(i)).count();
        for (i, &src) in topo.node_inputs[k].iter().enumerate() {
            if let Source::Node(j, o) = src {
                // Any input may be read by the copies of the effect when it is switched off
                // (`bypass`), even if no pass reads it. The copies write the outputs: keep the
                // input alive up to the last pass so the pool cannot give its texture to one.
                bump(&mut last, (j, finals[j][o]), g + runs.max(1) - 1);
            }
            let to = m.inputs[i].pixel_layout;
            if source_layout(effects, pad_layouts, src) != to {
                input_convert[k][i] = Some(convert_of(&mut converts, src, to, Some(k), g + runs.max(1) - 1));
            }
        }
        for (i, pass) in passes.iter().enumerate() {
            if !effects[k].runs(i) {
                continue;
            }
            for name in &pass.inputs {
                if let Some(out) = passes.iter().flat_map(|p| &p.outputs).find(|o| *o == name) {
                    bump(&mut last, (k, out.as_str()), g);
                } else if let Some(i) = m.inputs.iter().position(|d| d.name == *name) {
                    // The output of another effect is this effect's input.
                    if let Source::Node(j, o) = topo.node_inputs[k][i] {
                        bump(&mut last, (j, finals[j][o]), g);
                    }
                }
            }
            // Every output, read or not, so each one gets an end below.
            for out in &pass.outputs {
                bump(&mut last, (k, out.as_str()), g);
            }
            g += 1;
        }
    }
    let mut output_convert = vec![None; topo.outputs.len()];
    for (n, src) in topo.outputs.iter().enumerate() {
        if let Source::Node(j, o) = *src {
            // Read by the output conversion, after every effect.
            last.insert((j, finals[j][o]), usize::MAX);
            if source_layout(effects, pad_layouts, *src) != PixelLayout::Rgba && !planar_out[n] {
                output_convert[n] = Some(convert_of(&mut converts, *src, PixelLayout::Rgba, None, usize::MAX));
            }
        }
    }

    let mut free: HashMap<Slot, Vec<usize>> = HashMap::new();
    let mut live: Vec<(usize, usize)> = Vec::new();
    let mut slots: Vec<Slot> = Vec::new();
    fn take(free: &mut HashMap<Slot, Vec<usize>>, slots: &mut Vec<Slot>, key: Slot) -> usize {
        free.get_mut(&key).and_then(|f| f.pop()).unwrap_or_else(|| {
            slots.push(key);
            slots.len() - 1
        })
    }
    fn expire(live: &mut Vec<(usize, usize)>, free: &mut HashMap<Slot, Vec<usize>>, slots: &[Slot], g: usize) {
        live.retain(|&(end, slot)| {
            if end < g {
                free.entry(slots[slot]).or_default().push(slot);
            }
            end >= g
        });
    }
    let mut assign = vec![HashMap::new(); effects.len()];
    let mut g = 0;
    for &k in &topo.order {
        // The converts this effect reads first, alive through its passes.
        expire(&mut live, &mut free, &slots, g);
        for c in converts.iter_mut().filter(|c| c.before == Some(k)) {
            for &plane in c.to.planes() {
                let (w, h) = c.to.plane_size(plane, c.size);
                let slot = take(&mut free, &mut slots, (w, h, false, plane));
                live.push((c.end, slot));
                c.slots.push(slot);
            }
        }
        for (i, pass) in effects[k].passes(deep)?.iter().enumerate() {
            if !effects[k].runs(i) {
                continue;
            }
            expire(&mut live, &mut free, &slots, g);
            let (w, h) = sizes[k][pass.size_of];
            for out in &pass.outputs {
                let o = finals[k].iter().position(|n| n == out);
                // An output frame written in place takes no pooled texture, nor does an output
                // switched off (its pass writes a stand-in, see `Effect::bind`).
                let in_place = o.is_some_and(|o| direct_out[k][o].is_some());
                let off = effects[k].package().manifest.off_outputs.contains(out);
                let layout = effects[k].package().manifest.layout_of(out);
                for &plane in layout.planes() {
                    let key = layout.plane_key(out, plane);
                    if in_place || off || assign[k].contains_key(&key) {
                        continue;
                    }
                    let (pw, ph) = layout.plane_size(plane, (w, h));
                    let slot = take(&mut free, &mut slots, (pw, ph, o.is_some_and(|o| mips[k][o]), plane));
                    live.push((last[&(k, out.as_str())], slot));
                    assign[k].insert(key, slot);
                }
            }
            g += 1;
        }
    }
    // The converts of graph outputs only, after every effect.
    for c in converts.iter_mut().filter(|c| c.before.is_none()) {
        for &plane in c.to.planes() {
            let (w, h) = c.to.plane_size(plane, c.size);
            c.slots.push(take(&mut free, &mut slots, (w, h, false, plane)));
        }
    }
    Ok(Plan { assign, slots, converts, input_convert, output_convert })
}

/// Checks every effect against its manifest rules: an input pad gives its stream, an
/// edge the size of the effect output writing it and the format negotiated for it (`links`).
fn check_nodes<'a>(
    effects: &[Effect],
    topo: &Topology,
    links: Option<&'a [Vec<Option<String>>]>,
    streams: &[StreamInfo<'a>],
) -> Result<(), Error> {
    let max = effects[0].program.ctx.device.limits().max_texture_dimension_2d;
    let mut sizes: Vec<Vec<(u32, u32)>> = vec![Vec::new(); topo.node_inputs.len()];
    for &k in &topo.order {
        let infos: Vec<StreamInfo> = topo.node_inputs[k]
            .iter()
            .enumerate()
            .map(|(i, src)| match *src {
                Source::Input(p) => streams[p],
                Source::Node(j, o) => {
                    StreamInfo { format: links.and_then(|l| l[k][i].as_deref()), width: sizes[j][o].0, height: sizes[j][o].1 }
                }
            })
            .collect();
        effects[k].package().manifest.check_inputs(&infos)?;
        let ins: Vec<(u32, u32)> = infos.iter().map(|s| (s.width, s.height)).collect();
        sizes[k] = node_size(&effects[k], &ins, max)?;
    }
    Ok(())
}

/// Size of every output of `fx` for its input sizes: its manifest output size rules,
/// within the `max` texture side of the device.
fn node_size(fx: &Effect, ins: &[(u32, u32)], max: u32) -> Result<Vec<(u32, u32)>, Error> {
    let m = &fx.package().manifest;
    let sizes = fx.output_sizes(ins)?;
    for (o, &(w, h)) in sizes.iter().enumerate() {
        if w > max || h > max {
            let what = if m.outputs.len() == 1 {
                format!("output of `{}`", m.name)
            } else {
                format!("output `{}` of `{}`", m.outputs[o].name, m.name)
            };
            return Err(Error::Unsupported(format!("{what} would be {w}x{h}; this GPU allows at most {max} a side")));
        }
    }
    Ok(sizes)
}

/// Size of every effect output for the given pad sizes (see [`node_size`]).
fn node_sizes(effects: &[Effect], topo: &Topology, pads: &[(u32, u32)]) -> Result<Vec<Vec<(u32, u32)>>, Error> {
    let max = effects[0].program.ctx.device.limits().max_texture_dimension_2d;
    let mut sizes: Vec<Vec<(u32, u32)>> = vec![Vec::new(); topo.node_inputs.len()];
    for &k in &topo.order {
        let ins: Vec<(u32, u32)> = topo.node_inputs[k].iter().map(|s| source_size(*s, pads, &sizes)).collect();
        sizes[k] = node_size(&effects[k], &ins, max)?;
    }
    Ok(sizes)
}

fn source_size(src: Source, pads: &[(u32, u32)], sizes: &[Vec<(u32, u32)>]) -> (u32, u32) {
    match src {
        Source::Input(p) => pads[p],
        Source::Node(j, o) => sizes[j][o],
    }
}

fn source_texture(effects: &[Effect], inputs: &[InputSlot], src: Source) -> wgpu::Texture {
    match src {
        Source::Input(i) => inputs[i].texture.clone(),
        Source::Node(j, o) => effects[j].output(o).clone(),
    }
}

/// Checks that an output can pass input pad `pad` when bypassed: an existing pad of its size.
fn check_bypass_pad(ins: &[Desc], out: &Desc, pad: usize) -> Result<(), Error> {
    let Some(i) = ins.get(pad) else {
        return Err(Error::Frame(format!("bypass passes input {pad}, but the effect has {} inputs", ins.len())));
    };
    if (i.width, i.height) != (out.width, out.height) {
        return Err(Error::Frame(format!(
            "bypass passes input {pad}, which is {}x{} while the output is {}x{}",
            i.width, i.height, out.width, out.height
        )));
    }
    Ok(())
}

/// What the engine needs to know of a frame, in CPU or GPU memory.
#[derive(Clone, Copy)]
struct Desc {
    format: PixelFormat,
    width: u32,
    height: u32,
    premultiplied: bool,
}

/// Checks the frame counts and output sizes of a call, and (re)makes the input slots,
/// pooled textures and effect bind groups when the inputs changed.
fn prepare(
    effects: &mut [Effect],
    topo: &Topology,
    io: &mut FrameIo,
    inputs: &[Desc],
    outs: &[Desc],
    bypass: bool,
    gpu: bool,
) -> Result<(), Error> {
    if bypass {
        if inputs.is_empty() || inputs.len() > topo.nb_inputs {
            return Err(Error::Frame(format!("bypass takes 1 to {} inputs, got {}", topo.nb_inputs, inputs.len())));
        }
    } else if inputs.len() != topo.nb_inputs {
        return Err(Error::Frame(format!("effect expects {} inputs, got {}", topo.nb_inputs, inputs.len())));
    }
    if outs.len() != topo.outputs.len() {
        return Err(Error::Frame(format!("effect writes {} outputs, got {}", topo.outputs.len(), outs.len())));
    }
    // Effects that stack their inputs write a size no input pad has.
    let stacked = if effects.iter().any(|fx| fx.program.has_size_functions()) {
        let planned: &[InputKey] = io.layout.as_ref().map_or(&[], |l| &l.keys);
        let pads: Vec<(u32, u32)> = (0..topo.nb_inputs)
            .map(|i| match (inputs.get(i), planned.get(i)) {
                (Some(f), _) => (f.width, f.height),
                (None, Some(p)) => (p.width, p.height),
                (None, None) => (inputs[0].width, inputs[0].height),
            })
            .collect();
        let sizes = node_sizes(effects, topo, &pads)?;
        Some(topo.outputs.iter().map(|s| source_size(*s, &pads, &sizes)).collect::<Vec<_>>())
    } else {
        None
    };
    for (k, out) in outs.iter().enumerate() {
        let what = if outs.len() == 1 { "output".to_string() } else { format!("output {k}") };
        if let Some(sizes) = &stacked {
            let (w, h) = sizes[k];
            if (out.width, out.height) != (w, h) {
                return Err(Error::Frame(format!(
                    "{what} is {}x{}, the effect writes {w}x{h} (a size from gpufx_output_size must not change while the stream runs, e.g. with a parameter)",
                    out.width, out.height
                )));
            }
            continue;
        }
        let pad = topo.pad_of(topo.outputs[k]);
        let Some(f) = inputs.get(pad) else {
            return Err(Error::Frame(format!("{what} has the size of input {pad}, which is not given")));
        };
        let (w, h) = (f.width, f.height);
        if (out.width, out.height) != (w, h) {
            let of = if pad == 0 { "the first input".to_string() } else { format!("input {pad}") };
            return Err(Error::Frame(format!("{what} is {}x{}, the effect writes {w}x{h} (the size of {of})", out.width, out.height)));
        }
    }

    let ctx = effects[0].program.ctx.clone();
    let mut keys: Vec<InputKey> = inputs
        .iter()
        .map(|f| InputKey {
            format: f.format,
            width: f.width,
            height: f.height,
            direct: !gpu && f.format == PixelFormat::Rgba && !f.premultiplied,
            gpu,
            layout: PixelLayout::Rgba,
        })
        .collect();
    let (pad_mips, node_mips) = mip_sources(effects, topo);
    for (k, layout) in keys.iter_mut().zip(pad_layouts(effects, topo, inputs, &pad_mips, bypass)) {
        k.layout = layout;
    }
    let planned: &[InputKey] = io.layout.as_ref().map_or(&[], |l| &l.keys);
    // A bypass call may bring only the first inputs: keep the slots of the others, and
    // their depth, so toggling the filter on and off does not rebuild anything.
    let others = if bypass { planned.get(inputs.len()..).unwrap_or_default() } else { &[][..] };
    let deep = keys.iter().chain(others).any(|k| work_format(k.format) != wgpu::TextureFormat::Rgba8Unorm)
        || outs.iter().any(|o| work_format(o.format) != wgpu::TextureFormat::Rgba8Unorm);
    check_plane_mips(effects, &node_mips)?;
    let layouts: Vec<PixelLayout> = keys.iter().map(|k| k.layout).collect();
    // Input pads read as RGBA some effect reads in another layout: read through a convert,
    // so not in place.
    let converted = converted_pads(effects, topo, &layouts);
    // Vulkan frames in straight RGBA8, in a graph that is not deep: effects read the
    // frame itself, with no pooled texture and no conversion pass. So are 8-bit NV12 and
    // gray frames read in their layout's planes: their unorm planes hold the codes / 255.
    let in_place = gpu && io.direct_gpu && !deep;
    if in_place {
        for (i, k) in keys.iter_mut().enumerate() {
            k.direct = match k.layout {
                PixelLayout::Rgba => k.format == PixelFormat::Rgba && !inputs[i].premultiplied && !pad_mips[i] && !converted[i],
                _ => matches!(k.format, PixelFormat::Nv12 | PixelFormat::Gray) && !converted[i],
            };
        }
    }
    let planar_out = planar_outputs(effects, topo, outs);
    // And the pass writing an effect output writes a straight RGBA8 output frame in place.
    let direct_out = if in_place {
        direct_outputs(effects, topo, outs, &node_mips)
    } else {
        effects.iter().map(|fx| vec![None; fx.output_count()]).collect()
    };
    let stale = io.deep != deep
        || io.layout.as_ref().is_some_and(|l| l.direct_out != direct_out || l.planar_out != planar_out)
        || if bypass { planned.len() < keys.len() } else { planned.len() != keys.len() }
        || planned.iter().zip(&keys).any(|(p, k)| p != k);
    if stale {
        let mut keys = keys.clone();
        // Missing inputs keep their keys, or take input 0's when there are none yet.
        for i in keys.len()..topo.nb_inputs {
            keys.push(planned.get(i).copied().unwrap_or(keys[0]));
        }
        // Size rules of the manifests; pixel formats are the caller's to check.
        let streams: Vec<StreamInfo> = keys.iter().map(|k| StreamInfo { format: None, width: k.width, height: k.height }).collect();
        check_nodes(effects, topo, None, &streams)?;
        let pads: Vec<(u32, u32)> = keys.iter().map(|k| (k.width, k.height)).collect();
        let sizes = node_sizes(effects, topo, &pads)?;
        let layouts: Vec<PixelLayout> = keys.iter().map(|k| k.layout).collect();
        let plan = plan(effects, topo, &pads, &sizes, &node_mips, &direct_out, &layouts, &planar_out, deep)?;
        // Drop the bindings of the old textures; they go back to the pool's trimming.
        io.input_mips.clear();
        io.node_mips.clear();
        io.inputs.clear();
        io.outputs.clear();
        io.gpu_outputs.clear();
        io.readback_size = 0;
        io.readback_id = None;
        io.bound_ids.clear();
        io.out_ids.clear();
        io.converts.clear();
        io.convert_dsts.clear();
        io.off_converts.clear();
        for fx in effects.iter_mut() {
            fx.bound = None;
        }
        io.deep = deep;
        io.memory =
            MemoryStats { pass_textures: plan.slots.len(), pass_texture_bytes: plan.bytes(deep, ctx.plane_f16), ..Default::default() };
        io.layout = Some(Layout { keys, plan, sizes, pad_mips, node_mips, direct_out, planar_out });
    }
    acquire(effects, topo, io, &ctx)
}

/// Borrows the input slot and pass textures of a frame from the context pool, and
/// rebinds the slots and effects when the pool gave other textures than last time.
fn acquire(effects: &mut [Effect], topo: &Topology, io: &mut FrameIo, ctx: &Arc<crate::GpuContext>) -> Result<(), Error> {
    let (device, conv) = (&ctx.device, &ctx.conv);
    // Given back after the submission of the frame before, unless the caller did.
    io.release();
    if io.user == 0 {
        io.user = ctx.pool.new_user();
        io.ctx = Some(ctx.clone());
    }
    // Taken out while the slots are rebuilt, put back below.
    let layout = io.layout.take().expect("planned before");
    let deep = io.deep;
    let f16 = ctx.plane_f16;
    let usage = wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING;
    let mut keys = Vec::new();
    let mut counts = Vec::new();
    for (i, &k) in layout.keys.iter().enumerate() {
        let slot = InputSlot::pool_keys(k, deep, layout.pad_mips[i], f16);
        counts.push(slot.len());
        keys.extend(slot);
    }
    keys.extend(layout.plan.slots.iter().map(|&(width, height, mips, plane)| PoolKey::Texture {
        width,
        height,
        format: plane_format(plane, deep, f16),
        usage,
        mips,
    }));
    let wants: Vec<(PoolKey, Option<u64>)> = keys.iter().enumerate().map(|(n, &k)| (k, io.bound_ids.get(n).copied())).collect();
    let leases = ctx.pool.take(device, &wants);
    let ids: Vec<u64> = leases.iter().map(|l| l.id).collect();
    io.borrowed = ids.clone();
    // Slots are made once per layout even when nothing is pooled (frames read and written
    // in place), so empty ids match only once they are.
    if ids == io.bound_ids && !io.inputs.is_empty() {
        io.layout = Some(layout);
        return Ok(());
    }
    io.bound_ids.clear();
    // The copies of effects switched off hold the old textures.
    io.copies.clear();
    io.off_converts.clear();
    let mut textures = leases.iter().map(|l| l.texture().clone());
    io.input_mips.clear();
    io.node_mips.clear();
    io.inputs = layout
        .keys
        .iter()
        .zip(&counts)
        .enumerate()
        .map(|(i, (&k, &n))| {
            let frame = io.frame_ins.get(i).map_or(&[][..], Vec::as_slice);
            InputSlot::new(device, conv, k, deep, f16, textures.by_ref().take(n).collect(), frame)
        })
        .collect();
    let pool: Vec<wgpu::Texture> = textures.collect();
    io.convert_dsts = layout.plan.converts.iter().map(|c| c.slots.iter().map(|&s| pool[s].clone()).collect()).collect();
    io.converts.clear();
    let make_convert = |effects: &[Effect], io: &FrameIo, c: &ConvertPlan, n: usize| {
        let src = source_planes(effects, &io.inputs, c.src);
        LayoutConvert::new(device, conv, (c.from, c.to), &src, &io.convert_dsts[n], c.size, deep, f16)
    };
    for &k in &topo.order {
        // The converts read before the effect: their sources are bound by now.
        for (n, c) in layout.plan.converts.iter().enumerate().filter(|(_, c)| c.before == Some(k)) {
            let made = make_convert(&*effects, io, c, n);
            io.converts.push((n, made));
        }
        let sources = effect_inputs(effects, topo, io, &layout.plan, k);
        let mut outputs: HashMap<String, wgpu::Texture> =
            layout.plan.assign[k].iter().map(|(name, &slot)| (name.clone(), pool[slot].clone())).collect();
        for (o, j) in layout.direct_out[k].iter().enumerate() {
            let Some(j) = *j else { continue };
            // Written in place: the frame being recorded, bound again for each frame.
            let name = effects[k].package().manifest.outputs[o].name.clone();
            let frame = io.frame_outs.get(j).cloned().flatten();
            outputs.insert(name, frame.unwrap_or_else(|| crate::convert::stand_in(device, wgpu::TextureUsages::STORAGE_BINDING)));
        }
        if let Err(e) = effects[k].bind(&sources.iter().collect::<Vec<_>>(), outputs, &layout.sizes[k], deep) {
            io.release();
            io.layout = Some(layout);
            return Err(e);
        }
    }
    for (n, c) in layout.plan.converts.iter().enumerate().filter(|(_, c)| c.before.is_none()) {
        let made = make_convert(&*effects, io, c, n);
        io.converts.push((n, made));
    }
    io.input_mips = io.inputs.iter().zip(&layout.pad_mips).map(|(slot, &m)| m.then(|| ctx.mips.chain(device, &slot.texture))).collect();
    io.node_mips = (0..effects.len())
        .map(|k| layout.node_mips[k].iter().enumerate().map(|(o, &m)| m.then(|| ctx.mips.chain(device, effects[k].output(o)))).collect())
        .collect();
    for slot in &mut io.outputs {
        slot.unbind();
    }
    io.memory.input_textures = io.inputs.iter().map(|s| s.texture_count()).sum();
    io.memory.input_texture_bytes = io.inputs.iter().map(|s| s.texture_bytes()).sum();
    io.bound_ids = ids;
    io.layout = Some(layout);
    io.allocations += 1;
    Ok(())
}

fn desc_of(f: &Frame) -> Desc {
    Desc { format: f.format, width: f.width, height: f.height, premultiplied: f.color.premultiplied }
}

/// Runs the effects of `topo`: every input is uploaded once, every pass goes into one
/// command buffer in topological order and every output is read back once, through one
/// shared buffer. Without `info` the effects are bypassed: each output is its source
/// input pad (the pad whose size it has) converted to the output format; `inputs` may
/// then hold only the first pads.
pub(crate) fn run(
    effects: &mut [Effect],
    topo: &Topology,
    io: &mut FrameIo,
    inputs: &[Frame],
    outs: &mut [FrameMut],
    info: Option<&FrameInfo>,
) -> Result<(), Error> {
    let bypass = info.is_none();
    if !bypass {
        for fx in effects.iter_mut() {
            // Already reported when set through a graph; the last good shaders keep running.
            if let Err(e) = fx.sync_exprs() {
                eprintln!("gpufx: {e}; keeping the previous expressions");
            }
        }
    }
    for (i, f) in inputs.iter().enumerate() {
        f.check(&format!("input {i}"))?;
    }
    for (k, out) in outs.iter().enumerate() {
        out.check(&if outs.len() == 1 { "output".to_string() } else { format!("output {k}") })?;
    }
    let ins: Vec<Desc> = inputs.iter().map(desc_of).collect();
    let out_descs: Vec<Desc> =
        outs.iter().map(|o| Desc { format: o.format, width: o.width, height: o.height, premultiplied: o.color.premultiplied }).collect();
    prepare(effects, topo, io, &ins, &out_descs, bypass, false)?;
    if let Some(f) = inputs.first() {
        io.color = f.color;
    }

    let ctx = effects[0].program.ctx.clone();
    let (device, queue, conv) = (&ctx.device, &ctx.queue, &ctx.conv);
    if io.outputs.len() != outs.len() || io.outputs.iter().zip(outs.iter()).any(|(slot, o)| slot.key != (o.format, o.width, o.height)) {
        io.outputs.clear();
        io.readback_size = 0;
        io.readback_id = None;
        io.out_ids.clear();
        let mut offset = 0;
        for o in outs.iter() {
            let slot = match OutputSlot::new(device, o.format, o.width, o.height, offset) {
                Ok(slot) => slot,
                Err(e) => {
                    io.release();
                    return Err(e);
                }
            };
            offset = slot.end();
            io.outputs.push(slot);
        }
        io.readback_size = offset;
        io.memory.readback_bytes = offset;
    }
    // The output words are pooled too; the readback buffer is borrowed below.
    let keys: Vec<PoolKey> = io.outputs.iter().flat_map(|slot| slot.pool_keys()).collect();
    let wants: Vec<(PoolKey, Option<u64>)> = keys.iter().enumerate().map(|(n, &k)| (k, io.out_ids.get(n).copied())).collect();
    let leases = ctx.pool.take(device, &wants);
    let ids: Vec<u64> = leases.iter().map(|l| l.id).collect();
    io.borrowed.extend(&ids);
    if ids != io.out_ids {
        let mut buffers = leases.iter().map(|l| l.buffer().clone());
        for slot in &mut io.outputs {
            let n = slot.pool_keys().len();
            slot.set_words(buffers.by_ref().take(n).collect());
        }
        io.out_ids = ids;
    }
    let mut bound = false;
    io.bypass_bound.resize(outs.len(), usize::MAX);
    for (k, out_desc) in out_descs.iter().enumerate() {
        let pad = io.out_pad(effects, topo, k);
        if bypass {
            check_bypass_pad(&ins, out_desc, pad)?;
        }
        let planar = !bypass && io.layout.as_ref().is_some_and(|l| l.planar_out[k]);
        if planar && (!io.outputs[k].is_bound(false) || !io.outputs[k].is_planar()) {
            // Packed straight from the planes of the effect output.
            let src = source_planes(effects, &io.inputs, topo.outputs[k]);
            io.outputs[k].bind_planes(device, conv, &src)?;
            bound = true;
        } else if !planar
            && (!io.outputs[k].is_bound(bypass) || (bypass && io.bypass_bound[k] != pad) || (!bypass && io.outputs[k].is_planar()))
        {
            let tex = if bypass {
                source_texture(effects, &io.inputs, Source::Input(pad))
            } else {
                output_texture(effects, io, k, topo.outputs[k])
            };
            io.outputs[k].bind(device, conv, &tex, bypass);
            if bypass {
                io.bypass_bound[k] = pad;
            }
            bound = true;
        }
    }
    io.allocations += bound as usize;
    if !bypass {
        io.bind_copies(effects, topo)?;
    }

    for (slot, f) in io.inputs.iter().zip(inputs) {
        slot.upload(queue, &f.planes, &f.strides, &f.color);
    }
    let mut enc = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("gpufx") });
    {
        let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("gpufx"), timestamp_writes: None });
        encode_effects(effects, topo, io, inputs.len(), info, &mut cpass);
        for (slot, out) in io.outputs.iter().zip(outs.iter()) {
            slot.encode(queue, conv, &mut cpass, &out.color, bypass);
        }
    }
    let readback = ctx.pool.take(device, &[(readback_key(io.readback_size), io.readback_id)]).remove(0);
    io.readback_id = Some(readback.id);
    for slot in &io.outputs {
        slot.copy(&mut enc, readback.buffer());
    }
    queue.submit([enc.finish()]);
    // Later submissions may reuse the pooled resources: the GPU runs them after this one.
    io.release();
    let read = read_outputs(device, readback.buffer(), &io.outputs, outs);
    // Mapped by this graph alone: back to the pool once unmapped, or dropped when a failed
    // read may have left it mapped or a map pending.
    match read {
        Ok(()) => ctx.pool.put_back(&[readback.id]),
        Err(_) => {
            ctx.pool.forget(&[readback.id]);
            io.readback_id = None;
        }
    }
    read
}

/// Encodes the conversion of the first `given` inputs and, unless bypassed (no `info`),
/// every effect in order, each mip chain right after the texture it is made from.
fn encode_effects(
    effects: &[Effect],
    topo: &Topology,
    io: &FrameIo,
    given: usize,
    info: Option<&FrameInfo>,
    cpass: &mut wgpu::ComputePass,
) {
    encode_inputs(effects, io, given, info, cpass);
    encode_nodes(effects, topo, io, info, cpass);
}

/// The input half of [`encode_effects`]: conversions and the mip chains of the inputs.
fn encode_inputs(effects: &[Effect], io: &FrameIo, given: usize, info: Option<&FrameInfo>, cpass: &mut wgpu::ComputePass) {
    let ctx = &effects[0].program.ctx;
    for (i, slot) in io.inputs[..given].iter().enumerate() {
        slot.encode(&ctx.conv, cpass);
        if let (Some(Some(chain)), Some(_)) = (io.input_mips.get(i), info) {
            chain.encode(&ctx.device, &ctx.mips, cpass);
        }
    }
}

/// The effect half of [`encode_effects`]: each effect after the layout converts it reads,
/// then the converts of graph outputs only.
fn encode_nodes(effects: &[Effect], topo: &Topology, io: &FrameIo, info: Option<&FrameInfo>, cpass: &mut wgpu::ComputePass) {
    let ctx = &effects[0].program.ctx;
    let Some(info) = info else { return };
    let before = |n: usize| io.layout.as_ref().and_then(|l| l.plan.converts.get(n)).and_then(|c| c.before);
    for &k in &topo.order {
        for (_, c) in io.converts.iter().filter(|(n, _)| before(*n) == Some(k) && io.convert_read(*n)) {
            c.encode(&ctx.queue, &io.color, cpass);
        }
        let groups = io.copy_groups.get(k).filter(|g| g.iter().any(Option::is_some));
        let converts = io.off_converts.get(k).filter(|c| c.iter().any(Option::is_some));
        match (groups, converts, &io.layout) {
            // Switched off: an input copied into each output (see `bind_copies`).
            (None, None, _) | (_, _, None) => effects[k].encode(cpass, info),
            (groups, converts, Some(layout)) => {
                for (o, group) in groups.into_iter().flatten().enumerate() {
                    if let Some(group) = group {
                        let format = effects[k].output(o).format();
                        ctx.mips.encode_copy(&ctx.device, format, group, layout.sizes[k][o], cpass);
                    }
                }
                for (_, c) in converts.into_iter().flatten().flatten() {
                    c.encode(&ctx.queue, &io.color, cpass);
                }
            }
        }
        for chain in io.node_mips.get(k).into_iter().flatten().flatten() {
            chain.encode(&ctx.device, &ctx.mips, cpass);
        }
    }
    for (_, c) in io.converts.iter().filter(|(n, _)| before(*n).is_none()) {
        c.encode(&ctx.queue, &io.color, cpass);
    }
}

/// [`run`] for frames already on the GPU: the conversion passes read the input plane
/// textures and write the output plane textures directly, and everything is recorded
/// into `enc` without being submitted or waited for (the caller submits it, with
/// whatever synchronisation the frames need, before the next call).
pub(crate) fn run_gpu(
    effects: &mut [Effect],
    topo: &Topology,
    io: &mut FrameIo,
    inputs: &[GpuFrame],
    outs: &[GpuFrame],
    info: Option<&FrameInfo>,
    enc: &mut wgpu::CommandEncoder,
) -> Result<(), Error> {
    let bypass = info.is_none();
    if !bypass {
        for fx in effects.iter_mut() {
            // Already reported when set through a graph; the last good shaders keep running.
            if let Err(e) = fx.sync_exprs() {
                eprintln!("gpufx: {e}; keeping the previous expressions");
            }
        }
    }
    for (i, f) in inputs.iter().enumerate() {
        f.check(&format!("input {i}"), false)?;
    }
    for (k, out) in outs.iter().enumerate() {
        out.check(&if outs.len() == 1 { "output".to_string() } else { format!("output {k}") }, true)?;
    }
    let desc = |f: &GpuFrame| Desc { format: f.format, width: f.width, height: f.height, premultiplied: f.color.premultiplied };
    let ins: Vec<Desc> = inputs.iter().map(desc).collect();
    let out_descs: Vec<Desc> = outs.iter().map(desc).collect();
    let t0 = std::time::Instant::now();
    io.frame_ins = inputs.iter().map(|f| f.planes.clone()).collect();
    io.frame_outs = outs.iter().map(|f| f.planes.first().cloned()).collect();
    let prepared = prepare(effects, topo, io, &ins, &out_descs, bypass, true);
    if let Some(f) = inputs.first() {
        io.color = f.color;
    }
    io.frame_ins.clear();
    io.frame_outs.clear();
    prepared?;
    if crate::profile::enabled() {
        let ctx = effects[0].program.ctx.clone();
        let prof = io.prof.get_or_insert_with(|| {
            let label = effects.iter().map(|fx| fx.package().manifest.name.clone()).collect::<Vec<_>>().join("|");
            crate::profile::Profiler::new(&ctx.device, &ctx.queue, label)
        });
        prof.cpu(crate::profile::Cpu::Prepare, t0.elapsed());
    }
    // The pooled textures stay borrowed until the caller submitted `enc`.
    let res = record_gpu(effects, topo, io, inputs, outs, info, enc);
    if res.is_err() {
        io.release();
    }
    res
}

fn record_gpu(
    effects: &mut [Effect],
    topo: &Topology,
    io: &mut FrameIo,
    inputs: &[GpuFrame],
    outs: &[GpuFrame],
    info: Option<&FrameInfo>,
    enc: &mut wgpu::CommandEncoder,
) -> Result<(), Error> {
    let bypass = info.is_none();
    let ctx = effects[0].program.ctx.clone();
    let (device, queue, conv) = (&ctx.device, &ctx.queue, &ctx.conv);
    let t0 = std::time::Instant::now();
    if io.gpu_outputs.len() != outs.len()
        || io.gpu_outputs.iter().zip(outs.iter()).any(|(slot, o)| slot.key != (o.format, o.width, o.height))
    {
        io.gpu_outputs = outs.iter().map(|o| GpuOutputSlot::new(device, o.format, o.width, o.height)).collect();
        io.allocations += 1;
    }
    let mut direct = vec![false; io.inputs.len()];
    for (i, (slot, f)) in io.inputs.iter_mut().zip(inputs).enumerate() {
        if slot.key.direct {
            // Read in place: the effects reading it are bound to this frame below.
            slot.read_in_place(&f.planes);
            direct[i] = true;
        } else {
            io.frame_binds += slot.use_gpu_frame(device, queue, conv, &f.planes, &f.color) as usize;
        }
    }
    let direct_out = io.layout.as_ref().map(|l| l.direct_out.clone()).unwrap_or_default();
    if !bypass {
        for &k in &topo.order {
            let reads = topo.node_inputs[k].iter().any(|s| matches!(*s, Source::Input(i) if direct[i]));
            let writes: Vec<Option<&wgpu::Texture>> =
                direct_out.get(k).into_iter().flatten().map(|j| j.map(|j| &outs[j].planes[0])).collect();
            if reads || writes.iter().any(Option::is_some) {
                let plan = &io.layout.as_ref().expect("planned before").plan;
                let sources = effect_inputs(effects, topo, io, plan, k);
                io.frame_binds += effects[k].rebind(&sources.iter().collect::<Vec<_>>(), &writes)? as usize;
            }
        }
        io.bind_copies(effects, topo)?;
    }
    for (k, out) in outs.iter().enumerate() {
        if !bypass && direct_out.iter().flatten().any(|d| *d == Some(k)) {
            // Written by the effect itself: no conversion pass.
            io.gpu_outputs[k].unbind();
            continue;
        }
        let src = if bypass {
            let pad = io.out_pad(effects, topo, k);
            let desc = |width, height| Desc { format: out.format, width, height, premultiplied: false };
            let ins: Vec<Desc> = inputs.iter().map(|f| desc(f.width, f.height)).collect();
            check_bypass_pad(&ins, &desc(out.width, out.height), pad)?;
            Source::Input(pad)
        } else {
            topo.outputs[k]
        };
        if !bypass && io.layout.as_ref().is_some_and(|l| l.planar_out[k]) {
            // Written straight from the planes of the effect output.
            let sources = source_planes(effects, &io.inputs, src);
            io.frame_binds += io.gpu_outputs[k].bind_planes(device, queue, conv, &sources, &out.planes, &out.color)? as usize;
            continue;
        }
        let tex = if bypass { source_texture(effects, &io.inputs, src) } else { output_texture(effects, io, k, src) };
        io.frame_binds += io.gpu_outputs[k].bind(device, queue, conv, &tex, &out.planes, &out.color)? as usize;
    }
    let t1 = std::time::Instant::now();
    match &io.prof {
        Some(prof) if prof.timed() => {
            // Profiled: one pass per span, each with its timestamps.
            use crate::profile::{COPY_IN, COPY_OUT, EFFECTS};
            let desc = |span| wgpu::ComputePassDescriptor { label: Some("gpufx"), timestamp_writes: prof.writes(span) };
            encode_inputs(effects, io, inputs.len(), info, &mut enc.begin_compute_pass(&desc(COPY_IN)));
            encode_nodes(effects, topo, io, info, &mut enc.begin_compute_pass(&desc(EFFECTS)));
            let mut cpass = enc.begin_compute_pass(&desc(COPY_OUT));
            for slot in &io.gpu_outputs {
                slot.encode(conv, &mut cpass)?;
            }
        }
        _ => {
            let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("gpufx"), timestamp_writes: None });
            encode_effects(effects, topo, io, inputs.len(), info, &mut cpass);
            for slot in &io.gpu_outputs {
                slot.encode(conv, &mut cpass)?;
            }
        }
    }
    if let Some(prof) = &mut io.prof {
        // Before `finish`, which may wait for the timestamps of an earlier frame.
        prof.cpu(crate::profile::Cpu::Bind, t1 - t0);
        prof.cpu(crate::profile::Cpu::Record, t1.elapsed());
        prof.finish(enc);
    }
    Ok(())
}

/// A label of a statement: `[x]` by position, or `[name=x]` naming the input or output of
/// the effect it goes with.
#[derive(Debug, Clone)]
struct Label {
    name: Option<String>,
    label: String,
}

/// One package of a statement and the labels written right after it.
struct ItemSpec<'a> {
    text: &'a str,
    outputs: Vec<Label>,
}

/// One `[in]...a.zip[x]|b.zip[out]...` statement of a graph description. Labels left out
/// are empty until [`EffectGraph::parse`] binds them.
struct NodeSpec<'a> {
    statement: &'a str,
    inputs: Vec<Label>,
    items: Vec<ItemSpec<'a>>,
}

impl NodeSpec<'_> {
    /// `split` or `null`, the node's only item.
    fn split(&self) -> Option<&str> {
        match self.items.as_slice() {
            [item] if matches!(item.text, "split" | "null") => Some(item.text),
            _ => None,
        }
    }
}

fn graph_err(msg: impl Into<String>) -> Error {
    Error::Graph(msg.into())
}

/// Byte offset of the first `c` in `s` outside `'...'` quotes and not escaped by `\`
/// (a `\` escapes only a character of [`ESCAPED`]; before others it is a plain `\`).
fn find_unquoted(s: &str, c: u8) -> Option<usize> {
    let bytes = s.as_bytes();
    let (mut quoted, mut i) = (false, 0);
    while i < bytes.len() {
        let b = bytes[i];
        match b {
            b'\\' if !quoted && bytes.get(i + 1).is_some_and(|n| ESCAPED.as_bytes().contains(n)) => i += 1,
            b'\\' if !quoted => {}
            b'\'' => quoted = !quoted,
            _ if b == c && !quoted => return Some(i),
            _ => {}
        }
        i += 1;
    }
    None
}

/// `s` cut at every `c` outside quotes and not escaped (see [`find_unquoted`]).
fn split_unquoted(mut s: &str, c: u8) -> Vec<&str> {
    let mut parts = Vec::new();
    while let Some(i) = find_unquoted(s, c) {
        parts.push(&s[..i]);
        s = &s[i + 1..];
    }
    parts.push(s);
    parts
}

/// Characters `\` escapes in a chain or graph; before any other it is a plain `\` (Windows paths).
const ESCAPED: &str = "\\':&;|=[]";

/// Removes the escapes and quotes of an inline value: `\:` is `:` (see [`ESCAPED`]),
/// `'...'` is taken as it is.
fn unescape(s: &str, item: &str) -> Result<String, Error> {
    let mut out = String::with_capacity(s.len());
    let (mut quoted, mut chars) = (false, s.chars().peekable());
    while let Some(c) = chars.next() {
        match c {
            '\'' => quoted = !quoted,
            '\\' if !quoted => match chars.next_if(|n| ESCAPED.contains(*n)) {
                Some(n) => out.push(n),
                None => out.push('\\'),
            },
            c => out.push(c),
        }
    }
    if quoted {
        return Err(graph_err(format!("unclosed `'` in `{item}`")));
    }
    Ok(out)
}

/// Inline options of an effect: `key=value` pairs in the order they were written.
pub type InlineOptions = Vec<(String, String)>;

/// Keys an effect takes inline besides its parameters.
const NODE_KEYS: [&str; 3] = ["enable", "bypass", "outputs"];

/// Splits one effect of a chain or graph node, `path=key=value:key=value`, into its path
/// and options, without escapes and quotes. Options are separated by `:` (as in FFmpeg) or `&`
/// (no `:` needed inside an FFmpeg option value). `\` escapes the next character (one of
/// [`ESCAPED`]; before others it stays, for Windows paths) and `'...'` quotes, so values may hold `:`, `;`, `|`, `[`, `]` and `=`. Keys are named (parameter
/// names, `enable`, `bypass`) or positional: values without `key=` come first and take the
/// parameters in manifest order (`scale.zip=1280&-2`). Positional values are returned with
/// an empty key, named once the effect is open. A key given twice fails.
pub fn parse_effect_item(item: &str) -> Result<(String, InlineOptions), Error> {
    let item = item.trim();
    let (path, rest) = match find_unquoted(item, b'=') {
        Some(i) => (&item[..i], Some(&item[i + 1..])),
        None => (item, None),
    };
    let path = unescape(path.trim(), item)?;
    let mut options = InlineOptions::new();
    for option in
        rest.map(|r| split_unquoted(r, b':').into_iter().flat_map(|o| split_unquoted(o, b'&')).collect::<Vec<_>>()).unwrap_or_default()
    {
        let option = option.trim();
        let Some(eq) = find_unquoted(option, b'=') else {
            // A positional value: named later, by the manifest `params` order.
            if option.is_empty() {
                return Err(graph_err(format!("empty option in `{item}`")));
            }
            if options.iter().any(|(k, _)| !k.is_empty()) {
                return Err(graph_err(format!(
                    "effect `{path}`: positional value `{option}` after a named key (positional values come first)"
                )));
            }
            options.push((String::new(), unescape(option, item)?));
            continue;
        };
        let key = unescape(option[..eq].trim(), item)?;
        let value = unescape(option[eq + 1..].trim(), item)?;
        if key.is_empty() {
            return Err(graph_err(format!("`{option}` in `{item}` has no key")));
        }
        if options.iter().any(|(k, _)| *k == key) {
            return Err(graph_err(format!("effect `{path}`: key `{key}` given twice")));
        }
        options.push((key, value));
    }
    Ok((path, options))
}

/// Names the positional values of `options` (empty keys, first) after the parameters of
/// `fx` in manifest order; `enable` and `bypass` are never positional.
fn name_positional(path: &str, fx: &Effect, options: &mut InlineOptions) -> Result<(), Error> {
    let defs = fx.params.defs();
    let count = options.iter().take_while(|(k, _)| k.is_empty()).count();
    if count > defs.len() {
        return Err(graph_err(format!(
            "effect `{path}`: {count} positional values, but it has {} parameter{}",
            defs.len(),
            if defs.len() == 1 { "" } else { "s" }
        )));
    }
    for (option, def) in options.iter_mut().zip(defs).take(count) {
        option.0 = def.name.clone();
    }
    for (i, (key, _)) in options.iter().enumerate() {
        if options[..i].iter().any(|(k, _)| k == key) {
            return Err(graph_err(format!("effect `{path}`: key `{key}` given twice")));
        }
    }
    Ok(())
}

/// Fails when an option of the effect opened from `path` is not one of its parameters,
/// `enable` or `bypass` (`0` or `auto`).
fn check_options(path: &str, fx: &Effect, options: &InlineOptions) -> Result<(), Error> {
    for (key, value) in options {
        if key == "bypass" && value != "0" && value != "auto" {
            return Err(graph_err(format!("effect `{path}`: bypass={value}, bypass is 0 or auto")));
        }
        if key == "outputs" && value.parse::<u32>().is_err() {
            return Err(graph_err(format!("effect `{path}`: outputs={value}, outputs is the number of copies of its repeated output")));
        }
        let optional = fx.package().optional_outputs();
        if optional.contains(&key.as_str()) {
            if value != "on" && value != "off" {
                return Err(graph_err(format!("effect `{path}`: {key}={value}, the optional output `{key}` is on or off")));
            }
            continue;
        }
        if !NODE_KEYS.contains(&key.as_str()) && !fx.params.defs().iter().any(|d| d.name == *key) {
            let known: Vec<&str> = fx
                .params
                .defs()
                .iter()
                .map(|d| d.name.as_str())
                .chain(NODE_KEYS.into_iter().filter(|k| *k != "outputs" || fx.package().repeated_output().is_some()))
                .chain(optional.iter().copied())
                .collect();
            return Err(graph_err(format!("effect `{path}` has no parameter `{key}` (keys: {})", known.join(", "))));
        }
    }
    Ok(())
}

/// Sets the parameters whose inline values are constants; expressions (`t/2`) are left to
/// the caller, which reads them back with [`EffectGraph::inline_options`].
fn apply_constants(fx: &mut Effect, options: &InlineOptions) {
    for (key, value) in options {
        if !NODE_KEYS.contains(&key.as_str()) {
            let _ = fx.params.set_str(key, value);
        }
    }
}

/// `[label]` or `[name=label]` lists at the start of `rest`, which is advanced past them.
fn parse_labels(rest: &mut &str, statement: &str) -> Result<Vec<Label>, Error> {
    let mut labels = Vec::new();
    loop {
        let s = rest.trim_start();
        let Some(inner) = s.strip_prefix('[') else {
            *rest = s;
            return Ok(labels);
        };
        let end = inner.find(']').ok_or_else(|| graph_err(format!("unclosed `[` in `{statement}`")))?;
        let text = inner[..end].trim();
        let (name, label) = match text.split_once('=') {
            Some((n, l)) => (Some(n.trim()), l.trim()),
            None => (None, text),
        };
        let plain = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
        if !plain(label) || name.is_some_and(|n| !plain(n)) {
            return Err(graph_err(format!(
                "bad label `[{}]` in `{statement}`: use letters, digits, `_` or `-` (`.` would clash with `label.param`), or `[name=label]`",
                &inner[..end]
            )));
        }
        labels.push(Label { name: name.map(String::from), label: label.to_string() });
        *rest = &inner[end + 1..];
    }
}

fn parse_spec(text: &str) -> Result<Vec<NodeSpec<'_>>, Error> {
    let mut nodes = Vec::new();
    for statement in split_unquoted(text, b';').into_iter().map(str::trim).filter(|s| !s.is_empty()) {
        let mut rest = statement;
        let inputs = parse_labels(&mut rest, statement)?;
        let mut items = Vec::new();
        for (n, part) in split_unquoted(rest, b'|').into_iter().enumerate() {
            if n > 0 && part.trim_start().starts_with('[') {
                return Err(graph_err(format!(
                    "`{statement}`: input labels go at the start of a statement, not after `|`; write `[{}]...` as a statement of its own",
                    part.trim_start()[1..].split(']').next().unwrap_or("")
                )));
            }
            let end = find_unquoted(part, b'[').unwrap_or(part.len());
            let text = part[..end].trim();
            let mut after = &part[end..];
            let outputs = parse_labels(&mut after, statement)?;
            if !after.trim().is_empty() {
                return Err(graph_err(format!("unexpected `{}` after the output labels of `{statement}`", after.trim())));
            }
            if text.is_empty() {
                return Err(graph_err(format!("`{statement}` names no effect")));
            }
            items.push(ItemSpec { text, outputs });
        }
        nodes.push(NodeSpec { statement, inputs, items });
    }
    if nodes.is_empty() {
        return Err(graph_err("the graph is empty"));
    }
    Ok(nodes)
}

/// The input pad a label names (`[0]`, `[1]`...), if it is a number.
fn pad_label(label: &str) -> Option<Result<usize, Error>> {
    if !label.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(match label.parse::<usize>() {
        Ok(i) if i.to_string() == label && i < 64 => Ok(i),
        _ => Err(graph_err(format!("input pad label `[{label}]`: write it as a number from 0 to 63 without leading zeros"))),
    })
}

/// An effect opened for a graph: its parameter label, the effect and its inline options.
type Opened = (String, Effect, InlineOptions);

/// Opens the packages of a node, `a.zip=key=value[x]|b.zip`, in order. Only the first may
/// take more than one input.
fn open_items(
    items: &[ItemSpec],
    statement: &str,
    open: &mut impl FnMut(&str) -> Result<(String, Effect), Error>,
) -> Result<Vec<Opened>, Error> {
    let mut opened: Vec<Opened> = Vec::new();
    for item in items {
        let (path, mut options) = parse_effect_item(item.text)?;
        let (label, mut fx) = open(&path)?;
        name_positional(&path, &fx, &mut options)?;
        check_options(&path, &fx, &options)?;
        // `outputs=N` (the copies of a repeated output) and `<name>=off` (an optional output),
        // fixed when the graph is built: they set the outputs of the package.
        let mut count = None;
        if let Some(i) = options.iter().position(|(k, _)| k == "outputs") {
            let (_, value) = options.remove(i);
            count = Some(value.parse::<u32>().map_err(|_| {
                graph_err(format!("effect `{path}`: outputs={value}, outputs is the number of copies of its repeated output"))
            })?);
        }
        let optional: Vec<String> = fx.package().optional_outputs().into_iter().map(String::from).collect();
        let mut off = Vec::new();
        options.retain(|(k, v)| {
            let switch = optional.contains(k);
            if switch && v == "off" {
                off.push(k.clone());
            }
            !switch
        });
        if count.is_some() || !off.is_empty() {
            let package = fx.package().with_outputs(count, &off).map_err(|e| graph_err(format!("effect `{path}`: {e}")))?;
            fx = Effect::new(fx.program.ctx.clone(), package)?;
        }
        apply_constants(&mut fx, &options);
        if !opened.is_empty() && fx.input_count() != 1 {
            return Err(graph_err(format!(
                "`{path}` takes {} inputs; only the first effect of `{statement}` may take more than one",
                fx.input_count()
            )));
        }
        opened.push((label, fx, options));
    }
    if opened.is_empty() {
        return Err(graph_err(format!("`{statement}` names no package")));
    }
    Ok(opened)
}

enum NodeKind {
    /// `split` or `null`: the outputs are the input itself.
    Split,
    /// Effects of an `a.zip|b.zip` node, by index.
    Effects(Vec<usize>),
}

/// What writes a label: output `o` of effect `k`, or the `split`/`null` of statement `n`.
#[derive(Clone, Copy)]
enum Producer {
    Node(usize, usize),
    Split(usize),
}

/// Effects wired as a directed acyclic graph and run in one GPU submission. Effects
/// write the size of their first input; edges stay on the GPU in pooled textures.
pub struct EffectGraph {
    effects: Vec<Effect>,
    labels: Vec<String>,
    topo: Topology,
    /// Pixel format each effect input from another effect sees, as two filters in a row
    /// would negotiate it (`None` for input pads). Frames stay RGBA on the GPU; only the
    /// rules are checked.
    links: Vec<Vec<Option<String>>>,
    input_names: Vec<String>,
    input_formats: Vec<Vec<String>>,
    output_names: Vec<String>,
    output_formats: Vec<Vec<String>>,
    /// Output label of each effect node of a graph and its effects, for `label.param`.
    nodes: Vec<(String, Vec<usize>)>,
    /// (effect, parameter) of every entry of `param_names`.
    params: Vec<(usize, usize)>,
    param_names: Vec<String>,
    /// Inline options of each effect (see [`EffectGraph::inline_options`]).
    options: Vec<InlineOptions>,
    /// "chain" or "graph", in messages.
    what: &'static str,
    io: FrameIo,
    /// Wrappers and copies of the frames of the GPU frame APIs (see `stage.rs`).
    pub(crate) interop: crate::stage::Interop,
}

impl EffectGraph {
    /// Builds a graph from its description:
    /// `[0]split[a][b]; [a]gaussian-blur.zip[ba]; [b]grayscale.zip|vignette.zip[gb]; [ba][gb]crossfade.zip[out]`,
    /// or simply `a.zip=key=value|b.zip`.
    ///
    /// Statements are separated by `;`. Each reads labels, runs a node and names its
    /// outputs. `[0]`, `[1]`... are the input pads; every pad up to the highest must be
    /// read. Every other label is written once and read at most once (`split` it to read
    /// it twice); labels nobody reads are the outputs of the graph, in the order they are
    /// written. A node is `split` (any number of outputs, two when unlabelled, no copy),
    /// `null` (one output, no copy), or packages chained with `|`, which take as many
    /// labels as the first package has inputs and write one; each package may carry
    /// inline options (see [`parse_effect_item`]).
    ///
    /// As in an FFmpeg filtergraph, labels may be left out: a statement without input
    /// labels reads the input pads no label names, the lowest first (as many as the first
    /// package has inputs; one for `split` and `null`), and a statement without output
    /// labels writes outputs of the graph. A description that is one statement without
    /// labels is a chain: its pads take the input names of the first package's manifest
    /// and its output is `default`, as one FFmpeg filter.
    ///
    /// `open` loads a package from its text and returns its parameter label (the package
    /// file name, used in parameter names such as `vignette.strength`) and the effect.
    /// All effects must share one GPU context.
    pub fn parse(text: &str, mut open: impl FnMut(&str) -> Result<(String, Effect), Error>) -> Result<Self, Error> {
        let mut specs = parse_spec(text)?;
        if let [spec] = specs.as_slice() {
            if spec.inputs.is_empty() && spec.items.iter().all(|i| i.outputs.is_empty()) && spec.split().is_none() {
                let (effects, options): (Vec<_>, Vec<_>) = open_items(&spec.items, spec.statement, &mut open)?
                    .into_iter()
                    .map(|(label, fx, options)| ((label, fx), options))
                    .unzip();
                let mut graph = Self::linear(effects)?;
                graph.options = options;
                return Ok(graph);
            }
        }

        let mut kinds = Vec::with_capacity(specs.len());
        let mut options = Vec::new();
        let mut effects = Vec::new();
        let mut labels = Vec::new();
        for spec in &specs {
            kinds.push(match spec.split() {
                Some(body) => {
                    if spec.inputs.iter().chain(&spec.items[0].outputs).any(|l| l.name.is_some()) {
                        return Err(graph_err(format!("`{body}` takes plain labels, not `[name=label]`")));
                    }
                    NodeKind::Split
                }
                None => {
                    let mut ks = Vec::new();
                    for (label, fx, item_options) in open_items(&spec.items, spec.statement, &mut open)? {
                        ks.push(effects.len());
                        effects.push(fx);
                        labels.push(label);
                        options.push(item_options);
                    }
                    NodeKind::Effects(ks)
                }
            });
        }

        // Input labels by name, `[src=0][bg=m]x.zip`: put in the input order of the first
        // effect. A repeated input takes as many pads as `<name>0`, `<name>1`... are named.
        for (spec, kind) in specs.iter_mut().zip(&kinds) {
            let NodeKind::Effects(ks) = kind else { continue };
            let named = spec.inputs.iter().filter(|l| l.name.is_some()).count();
            if named == 0 {
                continue;
            }
            let k = ks[0];
            if named != spec.inputs.len() {
                return Err(graph_err(format!("`{}`: use either positional labels or `[name=label]` for its inputs, not both", labels[k])));
            }
            if let Some(base) = effects[k].package().repeated_input().map(String::from) {
                let pads = spec
                    .inputs
                    .iter()
                    .filter(|l| {
                        l.name
                            .as_deref()
                            .and_then(|n| n.strip_prefix(base.as_str()))
                            .is_some_and(|d| !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()))
                    })
                    .count();
                let fixed = effects[k].package().template_inputs() - 1;
                for i in 0..pads {
                    if !spec.inputs.iter().any(|l| l.name.as_deref() == Some(format!("{base}{i}").as_str())) {
                        return Err(graph_err(format!(
                            "`{}` names {pads} `{base}` inputs: they go from `{base}0` to `{base}{}`",
                            labels[k],
                            pads - 1
                        )));
                    }
                }
                if pads > 0 && fixed + pads != effects[k].input_count() {
                    let package = effects[k]
                        .package()
                        .with_input_count(pads as u32)
                        .map_err(|e| graph_err(format!("`{}` names {pads} `{base}` inputs: {e}", labels[k])))?;
                    let mut rebuilt = Effect::new(effects[k].program.ctx.clone(), package)?;
                    apply_constants(&mut rebuilt, &options[k]);
                    effects[k] = rebuilt;
                }
            }
            let m = &effects[k].package().manifest;
            let mut placed: Vec<Option<Label>> = vec![None; m.inputs.len()];
            for l in &spec.inputs {
                let name = l.name.as_deref().expect("named");
                let Some(i) = m.inputs.iter().position(|d| d.name == name) else {
                    let known: Vec<&str> = m.inputs.iter().map(|d| d.name.as_str()).collect();
                    return Err(graph_err(format!("`{}` has no input `{name}` (inputs: {})", labels[k], known.join(", "))));
                };
                if placed[i].is_some() {
                    return Err(graph_err(format!("input `{name}` of `{}` is given two labels", labels[k])));
                }
                placed[i] = Some(Label { name: None, label: l.label.clone() });
            }
            if let Some(i) = placed.iter().position(Option::is_none) {
                return Err(graph_err(format!("input `{}` of `{}` has no label", m.inputs[i].name, labels[k])));
            }
            spec.inputs = placed.into_iter().flatten().collect();
        }

        // Labels left out: inputs read the pads no label names, in order; outputs are
        // outputs of the graph, under names no statement uses.
        let named_pads: HashSet<usize> =
            specs.iter().flat_map(|s| &s.inputs).filter_map(|l| pad_label(&l.label).and_then(Result::ok)).collect();
        let used: HashSet<String> =
            specs.iter().flat_map(|s| s.inputs.iter().chain(s.items.iter().flat_map(|i| &i.outputs))).map(|l| l.label.clone()).collect();
        let mut next_pad = 0;
        for (spec, kind) in specs.iter_mut().zip(&kinds) {
            if spec.inputs.is_empty() {
                let wanted = match kind {
                    NodeKind::Split => 1,
                    NodeKind::Effects(ks) => effects[ks[0]].input_count(),
                };
                for _ in 0..wanted {
                    while named_pads.contains(&next_pad) {
                        next_pad += 1;
                    }
                    spec.inputs.push(Label { name: None, label: next_pad.to_string() });
                    next_pad += 1;
                }
            }
        }
        let mut next_out = 0;
        let mut fresh = || loop {
            let label = format!("out{next_out}");
            next_out += 1;
            if !used.contains(&label) {
                break label;
            }
        };
        let specs = specs;

        // A repeated input (hstack, vstack) takes every label the node reads, as FFmpeg's
        // hstack takes its inputs: the package is compiled again for that count.
        for (spec, kind) in specs.iter().zip(&kinds) {
            let NodeKind::Effects(ks) = kind else { continue };
            let k = ks[0];
            let fx = &effects[k];
            if !fx.package().has_repeated_input() || fx.input_count() == spec.inputs.len() {
                continue;
            }
            // The repeated input takes the labels after the fixed inputs before it.
            let pads = spec.inputs.len().saturating_sub(fx.package().template_inputs() - 1);
            let package = fx
                .package()
                .with_input_count(pads as u32)
                .map_err(|e| graph_err(format!("`{}` reads {} labels: {e}", labels[k], spec.inputs.len())))?;
            let mut rebuilt = Effect::new(fx.program.ctx.clone(), package)?;
            apply_constants(&mut rebuilt, &options[k]);
            effects[k] = rebuilt;
        }

        // Output labels. The labels after an effect name its outputs from the first, or by
        // name (`[matte=m]`). In a chain the first output without a label goes on to the
        // next effect; a last effect without labels writes outputs of the graph; any other
        // output without a label is dropped (FFmpeg would refuse it).
        let mut producers: HashMap<String, Producer> = HashMap::new();
        let mut defined: Vec<String> = Vec::new();
        let mut define = |label: String, p: Producer, defined: &mut Vec<String>| -> Result<(), Error> {
            if pad_label(&label).is_some() {
                return Err(graph_err(format!("`[{label}]` names an input pad; output labels must not be numbers")));
            }
            if producers.insert(label.clone(), p).is_some() {
                return Err(graph_err(format!("label `[{label}]` is written twice")));
            }
            defined.push(label);
            Ok(())
        };
        let mut chain_links: Vec<(usize, Source)> = Vec::new();
        let mut nodes = Vec::new();
        for (n, (spec, kind)) in specs.iter().zip(&kinds).enumerate() {
            let ins = spec.inputs.len();
            match kind {
                NodeKind::Split => {
                    let body = spec.items[0].text;
                    if ins != 1 {
                        return Err(graph_err(format!("`{body}` reads one label, got {ins}")));
                    }
                    let mut outs: Vec<String> = spec.items[0].outputs.iter().map(|l| l.label.clone()).collect();
                    if outs.is_empty() {
                        outs = (0..if body == "split" { 2 } else { 1 }).map(|_| fresh()).collect();
                    }
                    if body == "null" && outs.len() != 1 {
                        return Err(graph_err(format!("`null` writes one label, got {}", outs.len())));
                    }
                    for l in outs {
                        define(l, Producer::Split(n), &mut defined)?;
                    }
                }
                NodeKind::Effects(ks) => {
                    let fx = &effects[ks[0]];
                    if fx.input_count() != ins {
                        return Err(graph_err(format!("`{}` takes {} inputs, the node gives it {ins}", labels[ks[0]], fx.input_count())));
                    }
                    let mut written = Vec::new();
                    for (t, &k) in ks.iter().enumerate() {
                        let item = &spec.items[t];
                        let m = &effects[k].package().manifest;
                        let n_out = m.outputs.len();
                        let named = item.outputs.iter().filter(|l| l.name.is_some()).count();
                        if named != 0 && named != item.outputs.len() {
                            return Err(graph_err(format!("`{}`: use either positional labels or `[name=label]`, not both", labels[k])));
                        }
                        let mut assigned: Vec<bool> = vec![false; n_out];
                        let mut mine: Vec<(String, usize)> = Vec::new();
                        if named == 0 {
                            if item.outputs.len() > n_out {
                                return Err(graph_err(format!(
                                    "`{}` writes {n_out} output{} ({}), got {} labels{}",
                                    labels[k],
                                    if n_out == 1 { "" } else { "s" },
                                    m.output_names(),
                                    item.outputs.len(),
                                    if n_out == 1 { "; split it to use it twice" } else { "" }
                                )));
                            }
                            for (o, l) in item.outputs.iter().enumerate() {
                                mine.push((l.label.clone(), o));
                            }
                        } else {
                            for l in &item.outputs {
                                let name = l.name.as_deref().expect("named");
                                let Some(o) = m.output_index(name) else {
                                    return Err(graph_err(format!(
                                        "`{}` has no output `{name}` (outputs: {})",
                                        labels[k],
                                        m.output_names()
                                    )));
                                };
                                if mine.iter().any(|&(_, x)| x == o) {
                                    return Err(graph_err(format!("output `{name}` of `{}` is given two labels", labels[k])));
                                }
                                mine.push((l.label.clone(), o));
                            }
                        }
                        for &(_, o) in &mine {
                            assigned[o] = true;
                        }
                        if let Some(&next) = ks.get(t + 1) {
                            let Some(o) = assigned.iter().position(|a| !a) else {
                                return Err(graph_err(format!(
                                    "`{}`: every output has a label, so none goes on to `{}`",
                                    labels[k], labels[next]
                                )));
                            };
                            chain_links.push((next, Source::Node(k, o)));
                        } else if item.outputs.is_empty() {
                            mine = (0..n_out).map(|o| (fresh(), o)).collect();
                        }
                        for (l, o) in mine {
                            written.push(l.clone());
                            define(l, Producer::Node(k, o), &mut defined)?;
                        }
                    }
                    for l in written {
                        nodes.push((l, ks.clone()));
                    }
                }
            }
        }

        let mut readers: HashSet<&str> = HashSet::new();
        let mut nb_inputs = 0;
        for spec in &specs {
            for label in &spec.inputs {
                let label = label.label.as_str();
                match pad_label(label) {
                    Some(pad) => nb_inputs = nb_inputs.max(pad? + 1),
                    None if !producers.contains_key(label) => {
                        return Err(graph_err(format!("label `[{label}]` is read but never written")))
                    }
                    None => {}
                }
                if !readers.insert(label) {
                    return Err(graph_err(format!("label `[{label}]` is read twice; split it: `[{label}]split[{label}1][{label}2]`")));
                }
            }
        }
        if nb_inputs == 0 {
            return Err(graph_err("the graph reads no input pad (`[0]`)"));
        }
        if let Some(pad) = (0..nb_inputs).find(|p| !readers.contains(p.to_string().as_str())) {
            return Err(graph_err(format!("input pad `[{pad}]` is not read (pads [0] to [{}] must all be)", nb_inputs - 1)));
        }

        // Labels resolve to a pad or an effect output; split and null are no node of their own.
        fn resolve(label: &str, specs: &[NodeSpec], producers: &HashMap<String, Producer>, depth: usize) -> Result<Source, Error> {
            if let Some(pad) = pad_label(label) {
                return Ok(Source::Input(pad?));
            }
            match producers[label] {
                Producer::Node(k, o) => Ok(Source::Node(k, o)),
                Producer::Split(_) if depth > specs.len() => Err(graph_err(format!("the graph has a cycle through `[{label}]`"))),
                Producer::Split(n) => resolve(&specs[n].inputs[0].label, specs, producers, depth + 1),
            }
        }
        let mut node_inputs = vec![Vec::new(); effects.len()];
        for (spec, kind) in specs.iter().zip(&kinds) {
            if let NodeKind::Effects(ks) = kind {
                node_inputs[ks[0]] = spec.inputs.iter().map(|l| resolve(&l.label, &specs, &producers, 0)).collect::<Result<_, _>>()?;
            }
        }
        for (k, src) in chain_links {
            node_inputs[k] = vec![src];
        }
        let outputs: Vec<(String, Source)> = defined
            .iter()
            .filter(|l| !readers.contains(l.as_str()))
            .map(|l| Ok((l.to_string(), resolve(l, &specs, &producers, 0)?)))
            .collect::<Result<_, Error>>()?;
        if outputs.is_empty() {
            return Err(graph_err("the graph has no output: every label it writes is read again"));
        }
        if effects.is_empty() {
            return Err(graph_err("the graph runs no effect"));
        }

        // Topological order (Kahn), in statement order among the ready effects.
        let mut order = Vec::with_capacity(effects.len());
        let mut done = vec![false; effects.len()];
        while order.len() < effects.len() {
            let ready = (0..effects.len()).find(|&k| {
                !done[k] && node_inputs[k].iter().all(|s| matches!(*s, Source::Input(_)) || matches!(*s, Source::Node(j, _) if done[j]))
            });
            let Some(k) = ready else {
                let mut stuck: Vec<String> =
                    nodes.iter().filter(|(_, ks)| ks.iter().any(|&k| !done[k])).map(|(l, _)| format!("[{l}]")).collect();
                stuck.dedup();
                return Err(graph_err(format!("the graph has a cycle through {}", stuck.join(", "))));
            };
            done[k] = true;
            order.push(k);
        }

        let topo = Topology { nb_inputs, node_inputs, order, outputs: outputs.iter().map(|o| o.1).collect() };
        let input_names = (0..nb_inputs).map(|i| format!("in{i}")).collect();
        let output_names = outputs.into_iter().map(|o| o.0).collect();
        let mut graph = Self::from_parts(
            effects.into_iter().zip(labels).map(|(fx, l)| (l, fx)).collect(),
            topo,
            input_names,
            output_names,
            nodes,
            "graph",
        )?;
        graph.options = options;
        Ok(graph)
    }

    /// Inline options of every effect, by effect index (`blur.zip=radius=8:enable=gt(t,1)`):
    /// parameter values, `enable` and `bypass` as written. Constant parameter values are
    /// already set; the caller evaluates the rest.
    pub fn inline_options(&self) -> &[InlineOptions] {
        &self.options
    }

    /// Effects run one after the other, as if each fed the next through its own filter:
    /// the inputs are those of the first effect, named as in its manifest. Each effect
    /// hands its first output on; the outputs are those of the last effect: one is named
    /// `default`, several take their manifest names.
    fn linear(effects: Vec<(String, Effect)>) -> Result<Self, Error> {
        let first = &effects[0].1;
        let nb_inputs = first.input_count();
        let input_names = first.package().manifest.inputs.iter().map(|d| d.name.clone()).collect();
        let n = effects.len();
        let mut node_inputs = vec![(0..nb_inputs).map(Source::Input).collect::<Vec<_>>()];
        node_inputs.extend((1..n).map(|k| vec![Source::Node(k - 1, 0)]));
        let last = &effects[n - 1].1.package().manifest;
        let outputs = (0..last.outputs.len()).map(|o| Source::Node(n - 1, o)).collect();
        let output_names =
            if last.outputs.len() == 1 { vec!["default".to_string()] } else { last.outputs.iter().map(|o| o.name.clone()).collect() };
        let topo = Topology { nb_inputs, node_inputs, order: (0..n).collect(), outputs };
        Self::from_parts(effects, topo, input_names, output_names, Vec::new(), "chain")
    }

    pub(crate) fn from_parts(
        effects: Vec<(String, Effect)>,
        topo: Topology,
        input_names: Vec<String>,
        output_names: Vec<String>,
        nodes: Vec<(String, Vec<usize>)>,
        what: &'static str,
    ) -> Result<Self, Error> {
        let (labels, mut effects): (Vec<String>, Vec<Effect>) = effects.into_iter().unzip();
        let ctx = &effects[0].program.ctx;
        for (k, fx) in effects.iter().enumerate() {
            if !Arc::ptr_eq(&fx.program.ctx, ctx) {
                return Err(Error::Unsupported(format!("effect {k} (`{}`) runs on another GPU device", labels[k])));
            }
        }
        // Outputs nobody reads are dropped, with the passes only they need.
        for (k, fx) in effects.iter_mut().enumerate() {
            let used: Vec<bool> = (0..fx.output_count()).map(|o| topo.used(k, o)).collect();
            if !used.contains(&true) {
                return Err(Error::Graph(format!("no output of `{}` is used", labels[k])));
            }
            fx.set_used_outputs(&used);
        }
        // Effects pass RGBA textures to each other; inputs and outputs take any format the
        // GPU converts.
        let links: Vec<Vec<Option<String>>> = topo
            .node_inputs
            .iter()
            .map(|ins| ins.iter().map(|src| matches!(src, Source::Node(..)).then(|| "rgba".to_string())).collect())
            .collect();
        let input_formats = vec![Vec::new(); topo.nb_inputs];
        let output_formats = vec![crate::manifest::default_output_formats(); topo.outputs.len()];

        let mut params = Vec::new();
        let mut param_names = Vec::new();
        for (k, fx) in effects.iter().enumerate() {
            for (i, def) in fx.params.defs().iter().enumerate() {
                params.push((k, i));
                param_names.push(if effects.len() == 1 {
                    def.name.clone()
                } else if labels.iter().filter(|l| **l == labels[k]).count() == 1 && labels[k].parse::<usize>().is_err() {
                    format!("{}.{}", labels[k], def.name)
                } else {
                    format!("{k}.{}", def.name)
                });
            }
        }
        let nb_effects = effects.len();
        Ok(EffectGraph {
            effects,
            labels,
            topo,
            links,
            input_names,
            input_formats,
            output_names,
            output_formats,
            nodes,
            options: vec![Vec::new(); nb_effects],
            params,
            param_names,
            what,
            io: FrameIo::default(),
            interop: Default::default(),
        })
    }

    /// The graph is a chain: one statement without labels (see [`EffectGraph::parse`]).
    pub fn is_chain(&self) -> bool {
        self.what == "chain"
    }

    /// Effects in the order they were given (statement order for a parsed graph).
    pub fn effects(&self) -> &[Effect] {
        &self.effects
    }

    pub fn labels(&self) -> &[String] {
        &self.labels
    }

    /// Where every input of effect `k` comes from.
    pub fn effect_inputs(&self, k: usize) -> &[Source] {
        &self.topo.node_inputs[k]
    }

    /// Effects in execution order.
    pub fn order(&self) -> &[usize] {
        &self.topo.order
    }

    pub fn input_count(&self) -> usize {
        self.topo.nb_inputs
    }

    /// Names of the input pads: `in0`, `in1`... for a graph, the manifest input names of
    /// the first effect for a chain (one statement without labels).
    pub fn input_names(&self) -> &[String] {
        &self.input_names
    }

    /// Pixel formats input pad `i` accepts: those every effect reading it accepts. Empty
    /// accepts anything.
    pub fn input_formats(&self, i: usize) -> &[String] {
        &self.input_formats[i]
    }

    pub fn output_count(&self) -> usize {
        self.topo.outputs.len()
    }

    /// Some effect sizes an output in its shader (`gpufx_output_size`): sizes then need
    /// the GPU (not the noop device).
    pub fn has_size_functions(&self) -> bool {
        self.effects.iter().any(|fx| fx.program.has_size_functions())
    }

    /// Labels of the outputs, in the order they are written.
    pub fn output_names(&self) -> &[String] {
        &self.output_names
    }

    /// Pixel formats output `k` may have, in order of preference.
    pub fn output_formats(&self, k: usize) -> &[String] {
        &self.output_formats[k]
    }

    pub fn output_source(&self, k: usize) -> Source {
        self.topo.outputs[k]
    }

    /// The input pad whose size (and, in FFmpeg, frame rate and aspect ratio) output `k`
    /// has: effects write the size of their first input.
    pub fn output_pad(&self, k: usize) -> usize {
        self.topo.pad_of(self.topo.outputs[k])
    }

    /// Size of output `k` for these input pad sizes: the size of [`Self::output_pad`],
    /// unless an effect on the way stacks its inputs (the `size` of a manifest output). Fails when
    /// the sizes break a size rule or the output is larger than the GPU allows.
    pub fn output_size(&self, k: usize, pads: &[(u32, u32)]) -> Result<(u32, u32), Error> {
        if k >= self.topo.outputs.len() {
            return Err(Error::Unsupported(format!("the {} has no output {k}", self.what)));
        }
        if pads.len() != self.topo.nb_inputs {
            return Err(Error::Unsupported(format!("the {} takes {} input(s), got {}", self.what, self.topo.nb_inputs, pads.len())));
        }
        let sizes = node_sizes(&self.effects, &self.topo, pads)?;
        Ok(source_size(self.topo.outputs[k], pads, &sizes))
    }

    /// Full names of every parameter: `name` for a single effect, else `label.name`, or
    /// `index.name` when two effects share a label.
    pub fn param_names(&self) -> &[String] {
        &self.param_names
    }

    /// Finds a parameter by its full name, by `label.name`, by `index.name` (0 based), by
    /// `node.name` where node is the output label of a graph node (`[ba]`), or, when only
    /// one effect has it, by its bare name. A prefix made of digits is always an index.
    pub fn find_param(&self, name: &str) -> Result<usize, Error> {
        if let Some(i) = self.param_names.iter().position(|n| n == name) {
            return Ok(i);
        }
        // `outputs=N` sets the pads of the graph: it cannot change once it is built (no param
        // takes the name, see `NODE_OPTIONS`).
        if name == "outputs" || name.rsplit_once('.').is_some_and(|(_, p)| p == "outputs") {
            return Err(Error::Param(format!(
                "`{name}`: outputs=N is fixed when the {} is built (it sets the output pads); give it inline, e.g. `effect.zip=outputs=3`",
                self.what
            )));
        }
        // `<output>=off` too: it sets the pads (an output name is never a param name).
        let last = name.rsplit_once('.').map_or(name, |(_, p)| p);
        if self.effects.iter().any(|fx| fx.package().optional_outputs().contains(&last)) {
            return Err(Error::Param(format!(
                "`{name}`: the optional output `{last}` is switched on or off when the {} is built (it sets the output pads); give it inline, e.g. `effect.zip={last}=off`",
                self.what
            )));
        }
        let find = |k: usize, param: &str| self.params.iter().position(|&(e, p)| e == k && self.effects[e].params.defs()[p].name == param);
        if let Some((prefix, param)) = name.split_once('.') {
            let effects = self.node_effects(prefix, param)?;
            let owners: Vec<usize> = effects.iter().filter_map(|&k| find(k, param)).collect();
            return match owners.as_slice() {
                [i] => Ok(*i),
                [] if effects.len() == 1 => Err(Error::Param(format!("effect `{}` has no parameter `{param}`", self.labels[effects[0]]))),
                [] => Err(Error::Param(format!("node `{prefix}` has no parameter `{param}`"))),
                _ => Err(Error::Param(format!(
                    "several effects of node `{prefix}` have a parameter `{param}`: {}",
                    owners.iter().map(|&i| self.param_names[i].as_str()).collect::<Vec<_>>().join(", ")
                ))),
            };
        }
        let owners: Vec<usize> = (0..self.effects.len()).filter_map(|k| find(k, name)).collect();
        match owners.as_slice() {
            [i] => Ok(*i),
            [] => Err(Error::Param(format!("no effect of the {} has a parameter `{name}`", self.what))),
            _ => Err(Error::Param(format!(
                "several effects have a parameter `{name}`: {}",
                owners.iter().map(|&i| self.param_names[i].as_str()).collect::<Vec<_>>().join(", ")
            ))),
        }
    }

    /// The effects a name prefix stands for, as in `prefix.param`: a package label naming
    /// one effect, an index (0 based; digits are always an index), or the output label of
    /// a graph node (every effect of its statement). `param` only goes in messages.
    fn node_effects(&self, prefix: &str, param: &str) -> Result<Vec<usize>, Error> {
        let what = self.what;
        let effects: Vec<usize> = match prefix.parse::<usize>() {
            Ok(k) if k < self.effects.len() => vec![k],
            Ok(_) => Vec::new(),
            Err(_) => {
                let matches: Vec<usize> = (0..self.labels.len()).filter(|&k| self.labels[k] == prefix).collect();
                if matches.len() > 1 {
                    return Err(Error::Param(format!(
                        "`{prefix}` names {} effects of the {what}; use the index, e.g. `{}.{param}`",
                        matches.len(),
                        matches[0]
                    )));
                }
                if matches.is_empty() {
                    self.nodes.iter().find(|(l, _)| l == prefix).map(|(_, ks)| ks.clone()).unwrap_or_default()
                } else {
                    matches
                }
            }
        };
        if effects.is_empty() {
            let mut known = self.labels.clone();
            known.extend(self.nodes.iter().map(|(l, _)| l.clone()));
            return Err(Error::Param(format!("the {what} has no effect `{prefix}` (effects: {})", known.join(", "))));
        }
        Ok(effects)
    }

    /// The effects `node.enable` switches, by the prefixes of [`EffectGraph::find_param`]:
    /// `label`, `index` or a graph node's output label. An empty `node` (a bare `enable`)
    /// is the effect of a graph holding only one.
    pub fn find_node(&self, node: &str) -> Result<Vec<usize>, Error> {
        if node.is_empty() {
            if self.effects.len() == 1 {
                return Ok(vec![0]);
            }
            return Err(Error::Param(format!(
                "the {} runs {} effects: say which one `enable` switches, e.g. `0.enable`",
                self.what,
                self.effects.len()
            )));
        }
        self.node_effects(node, "enable")
    }

    /// Switches effect `k` on or off. An effect switched off passes an input (its first
    /// unless [`EffectGraph::set_node_bypass`] picks another)
    /// through, which must have its size: nothing is planned or bound
    /// again, so this is cheap enough to do on every frame.
    pub fn set_node_enabled(&mut self, k: usize, on: bool) -> Result<(), Error> {
        if k >= self.effects.len() {
            return Err(Error::Param(format!("the {} has no effect {k}", self.what)));
        }
        if self.io.enabled.len() != self.effects.len() {
            self.io.enabled = vec![true; self.effects.len()];
        }
        self.io.enabled[k] = on;
        Ok(())
    }

    /// Picks the input every output of effect `k` passes through when switched off
    /// (without it, each output passes the input its manifest `bypass` names, the first by
    /// default). Any input may be chosen; when it has another size than an output,
    /// processing fails while the effect is off.
    pub fn set_node_bypass(&mut self, k: usize, input: usize) -> Result<(), Error> {
        let Some(inputs) = self.topo.node_inputs.get(k) else {
            return Err(Error::Param(format!("the {} has no effect {k}", self.what)));
        };
        if input >= inputs.len() {
            return Err(Error::Param(format!(
                "bypass {input} of effect {k} ({}): it has {} input{}",
                self.labels[k],
                inputs.len(),
                if inputs.len() == 1 { "" } else { "s" }
            )));
        }
        if self.io.bypass.len() != self.effects.len() {
            self.io.bypass = vec![None; self.effects.len()];
        }
        self.io.bypass[k] = Some(input);
        Ok(())
    }

    /// The input output `o` of effect `k` passes through when the effect is switched off:
    /// the one [`EffectGraph::set_node_bypass`] picked, else its manifest `bypass`.
    pub fn node_bypass(&self, k: usize, o: usize) -> usize {
        self.io.bypass(&self.effects, k, o)
    }

    /// Picks the input pad every output passes when the whole graph is bypassed (a
    /// frame processed without frame info: the filter disabled, or every effect off).
    pub fn set_bypass_pad(&mut self, pad: BypassPad) -> Result<(), Error> {
        if let BypassPad::Pad(p) = pad {
            if p >= self.topo.nb_inputs {
                return Err(Error::Param(format!("bypass {p}: the {} has {} inputs", self.what, self.topo.nb_inputs)));
            }
        }
        self.io.bypass_pad = pad;
        Ok(())
    }

    /// The input pad output `k` passes when the whole graph is bypassed, by the choice of
    /// [`EffectGraph::set_bypass_pad`].
    pub fn bypass_pad(&self, k: usize) -> usize {
        self.io.out_pad(&self.effects, &self.topo, k)
    }

    /// Whether effect `k` runs (see [`EffectGraph::set_node_enabled`]).
    pub fn node_enabled(&self, k: usize) -> bool {
        self.io.enabled(k)
    }

    /// Every effect is switched off: the outputs are their input pads, so a caller may
    /// pass the frames through as when the filter is disabled.
    pub fn all_nodes_disabled(&self) -> bool {
        (0..self.effects.len()).all(|k| !self.io.enabled(k))
    }

    /// Parameter `index` of `param_names` as (block, name inside its effect).
    fn param(&mut self, index: usize) -> Result<(&mut ParamBlock, String), Error> {
        let &(k, p) = self.params.get(index).ok_or_else(|| Error::Param(format!("no parameter {index}")))?;
        let block = &mut self.effects[k].params;
        let name = block.defs()[p].name.clone();
        Ok((block, name))
    }

    /// Numbers a parameter takes (1 for a scalar, 2 to 4 for a vector or a color, 0 for an
    /// expression parameter), by index of `param_names`.
    pub fn param_components(&self, index: usize) -> Result<usize, Error> {
        let &(k, p) = self.params.get(index).ok_or_else(|| Error::Param(format!("no parameter {index}")))?;
        Ok(self.effects[k].params.defs()[p].kind.components())
    }

    /// Sets a parameter (any name `find_param` takes) from text.
    pub fn set_param_str(&mut self, name: &str, text: &str) -> Result<(), Error> {
        let index = self.find_param(name)?;
        let (block, name) = self.param(index)?;
        block.set_str(&name, text)?;
        // An expression is compiled now, so a bad one fails here (sendcmd) and not mid-stream.
        if block.expr(&name).is_some() {
            let k = self.params[index].0;
            self.effects[k].sync_exprs()?;
        }
        Ok(())
    }

    /// Sets the first components of a parameter (any name `find_param` takes).
    pub fn set_param(&mut self, name: &str, values: &[f64]) -> Result<(), Error> {
        let (block, name) = self.param(self.find_param(name)?)?;
        block.set(&name, values)
    }

    /// Checks one stream per input pad against the rules of every effect: an effect
    /// reading another sees that effect's size (the size of its first input) and the
    /// format negotiated between them. A chain given the wrong number of streams fails
    /// as its first effect would.
    pub fn check_inputs(&self, streams: &[StreamInfo]) -> Result<(), Error> {
        if streams.len() != self.topo.nb_inputs && self.what == "chain" {
            return self.effects[0].package().manifest.check_inputs(streams);
        }
        if streams.len() != self.topo.nb_inputs {
            return Err(Error::Unsupported(format!("the {} takes {} input(s), got {}", self.what, self.topo.nb_inputs, streams.len())));
        }
        check_nodes(&self.effects, &self.topo, Some(&self.links), streams)
    }

    /// GPU memory the graph would hold for these input pad sizes, without allocating it:
    /// the pooled pass textures (the peak number alive at once) and their bytes.
    /// `deep`: frames above 8 bits (`rgba16float` textures).
    pub fn memory_plan(&self, sizes: &[(u32, u32)], deep: bool) -> Result<(usize, u64), Error> {
        if sizes.len() != self.topo.nb_inputs {
            return Err(Error::Unsupported(format!("the {} takes {} input(s), got {}", self.what, self.topo.nb_inputs, sizes.len())));
        }
        let (_, mips) = mip_sources(&self.effects, &self.topo);
        let none: Vec<Vec<Option<usize>>> = self.effects.iter().map(|fx| vec![None; fx.output_count()]).collect();
        let plan = plan(
            &self.effects,
            &self.topo,
            sizes,
            &node_sizes(&self.effects, &self.topo, sizes)?,
            &mips,
            &none,
            &vec![PixelLayout::Rgba; self.topo.nb_inputs],
            &vec![false; self.topo.outputs.len()],
            deep,
        )?;
        Ok((plan.slots.len(), plan.bytes(deep, self.effects[0].program.ctx.plane_f16)))
    }

    /// GPU memory held for the current frames; zero before the first one.
    pub fn memory(&self) -> MemoryStats {
        self.io.memory
    }

    /// Runs the graph on RGBA8 images, one per input pad, writing one image per output.
    pub fn process(&mut self, inputs: &[Image], outs: Vec<ImageMut>, info: &FrameInfo) -> Result<(), Error> {
        let frames: Vec<Frame> = inputs.iter().map(|&i| i.into()).collect();
        let mut outs: Vec<FrameMut> = outs.into_iter().map(Into::into).collect();
        self.process_frames(&frames, &mut outs, info)
    }

    /// Runs the graph on frames in any [`PixelFormat`], converted on the GPU. Output `k`
    /// must have the size of input [`EffectGraph::output_pad`]`(k)`.
    pub fn process_frames(&mut self, inputs: &[Frame], outs: &mut [FrameMut], info: &FrameInfo) -> Result<(), Error> {
        run(&mut self.effects, &self.topo, &mut self.io, inputs, outs, Some(info))
    }

    /// Writes every output without running the effects, as a disabled filter: output `k`
    /// is input [`EffectGraph::output_pad`]`(k)` converted to its format. `inputs` may
    /// hold only the first pads, as long as every output's pad is given.
    pub fn convert(&mut self, inputs: &[Frame], outs: &mut [FrameMut]) -> Result<(), Error> {
        run(&mut self.effects, &self.topo, &mut self.io, inputs, outs, None)
    }

    /// Runs the graph on frames already on the GPU (textures of this graph's device),
    /// recording every pass into `enc`. Nothing is submitted: the caller submits `enc`
    /// (and synchronises with whoever else uses the textures) before the next call, which
    /// rewrites the uniforms. Output `k` must have the size of input
    /// [`EffectGraph::output_pad`]`(k)`. Without `info` the effects are bypassed as in
    /// [`EffectGraph::convert`]. Bind groups of the frame textures are made per call
    /// (the textures of a frame pool change from frame to frame); the pooled textures
    /// are reused as for CPU frames. They are borrowed from the context pool until
    /// [`EffectGraph::release_frame`] or the next call: call it right after submitting
    /// `enc`, so other graphs on the device can use them.
    pub fn encode_gpu(
        &mut self,
        inputs: &[GpuFrame],
        outs: &[GpuFrame],
        info: Option<&FrameInfo>,
        enc: &mut wgpu::CommandEncoder,
    ) -> Result<(), Error> {
        run_gpu(&mut self.effects, &self.topo, &mut self.io, inputs, outs, info, enc)
    }

    /// Gives the pooled textures of the last [`EffectGraph::encode_gpu`] back to the
    /// context pool. Only once its encoder was submitted (or dropped): later submissions
    /// of other graphs reuse them.
    pub fn release_frame(&mut self) {
        self.io.release();
    }

    /// Lets [`EffectGraph::encode_gpu`] read straight RGBA8 input frames in place, with
    /// no copy, when the graph is not deep and nothing wants their mip chain: the input
    /// textures then need `TEXTURE_BINDING` usage only. [`EffectGraph::process_vulkan`]
    /// does this; D3D12 frames keep the copies.
    #[doc(hidden)]
    pub fn allow_direct_gpu(&mut self) {
        self.io.direct_gpu = true;
    }

    /// Adds `d` to a CPU span of the profile, when profiling (see [`crate::profile`]).
    #[cfg_attr(not(any(windows, all(unix, not(target_vendor = "apple")))), allow(dead_code))]
    pub(crate) fn profile_cpu(&mut self, span: crate::profile::Cpu, d: std::time::Duration) {
        if let Some(prof) = &mut self.io.prof {
            prof.cpu(span, d);
        }
    }

    /// The device the graph runs on.
    pub fn context(&self) -> &Arc<crate::GpuContext> {
        self.effects[0].program.context()
    }

    /// Copies the parameter values of `other`, a graph opened from the same description
    /// (on another device, say).
    pub fn copy_params_from(&mut self, other: &EffectGraph) -> Result<(), Error> {
        if self.effects.len() != other.effects.len() || self.param_names != other.param_names {
            return Err(Error::Param("the graphs differ".into()));
        }
        for (a, b) in self.effects.iter_mut().zip(&other.effects) {
            a.params = b.params.clone();
        }
        self.io.enabled = other.io.enabled.clone();
        self.io.bypass = other.io.bypass.clone();
        self.io.bypass_pad = other.io.bypass_pad;
        Ok(())
    }

    /// How many times frame textures, buffers or bind groups were (re)made: once per new
    /// size or format, never per frame. For tests and diagnostics.
    pub fn allocations(&self) -> usize {
        self.io.allocations
    }

    /// How many times bindings of GPU frame textures were made. The frames of a pool come
    /// back in turn and reuse theirs, so this stops growing once each was seen. For tests.
    #[doc(hidden)]
    pub fn frame_binds(&self) -> usize {
        self.io.frame_binds
    }

    /// How many layout converts (between `pixel_layout`s) the current frames run, not
    /// counting those standing for the copies of effects switched off. For tests.
    #[doc(hidden)]
    pub fn layout_converts(&self) -> usize {
        self.io.converts.iter().filter(|(n, _)| self.io.convert_read(*n)).count()
    }

    /// How many frame conversions to or from RGBA the current frames run: input slots
    /// converting to RGBA and outputs converting from it, not the inputs and outputs loaded
    /// or written straight from planes, nor those read or written in place. For tests.
    #[doc(hidden)]
    pub fn rgba_conversions(&self) -> usize {
        let io = &self.io;
        io.inputs.iter().filter(|s| s.converts_to_rgba()).count()
            + io.outputs.iter().filter(|s| !s.is_planar()).count()
            + io.gpu_outputs.iter().filter(|s| s.is_bound() && !s.is_planar()).count()
    }

    /// The pixel format output `k` is written in: `out_format` when given (the caller's
    /// choice, e.g. FFmpeg's `out_format` option), else `first_input` (the format of the
    /// first input frame) when it is of the `pixel_layout` of the output, else that layout's
    /// default ([`PixelFormat::default_of`]: `nv12` for `yuv420`, `gray` for `y`, `rgba`
    /// for `rgba`, ...). An output with planes in a format of its layout is written straight
    /// from its planes; any other format goes through RGBA.
    pub fn output_default_format(&self, k: usize, out_format: Option<&str>, first_input: Option<&str>) -> Result<PixelFormat, Error> {
        if k >= self.topo.outputs.len() {
            return Err(Error::Unsupported(format!("the {} has no output {k}", self.what)));
        }
        let parse = |name: &str| {
            PixelFormat::from_name(name).ok_or_else(|| Error::Unsupported(format!("pixel format `{name}` is not converted on the GPU")))
        };
        if let Some(name) = out_format {
            return parse(name);
        }
        let layout = match self.topo.outputs[k] {
            Source::Node(j, o) => self.effects[j].package().manifest.outputs[o].pixel_layout,
            Source::Input(_) => PixelLayout::Rgba,
        };
        if let Some(f) = first_input.and_then(PixelFormat::from_name) {
            if f.pixel_layout() == layout {
                return Ok(f);
            }
        }
        Ok(PixelFormat::default_of(layout))
    }
}

impl crate::stage::GpuStage for EffectGraph {
    fn context(&self) -> &Arc<crate::GpuContext> {
        EffectGraph::context(self)
    }

    fn interop(&mut self) -> &mut crate::stage::Interop {
        &mut self.interop
    }

    fn encode_gpu(
        &mut self,
        inputs: &[GpuFrame],
        outs: &[GpuFrame],
        info: Option<&FrameInfo>,
        enc: &mut wgpu::CommandEncoder,
    ) -> Result<(), Error> {
        EffectGraph::encode_gpu(self, inputs, outs, info, enc)
    }

    fn release_frame(&mut self) {
        EffectGraph::release_frame(self);
    }

    fn allow_direct_gpu(&mut self) {
        EffectGraph::allow_direct_gpu(self);
    }

    fn profile_cpu(&mut self, span: crate::profile::Cpu, d: std::time::Duration) {
        EffectGraph::profile_cpu(self, span, d);
    }
}

#[cfg(test)]
mod tests {
    use super::split_unquoted;

    #[test]
    fn backslash_escapes_only_special_characters() {
        // A `\` before a non-special character is literal, so Windows paths split on `|`.
        assert_eq!(split_unquoted(r"C:\fx\a.zip|C:\fx\b.zip", b'|'), [r"C:\fx\a.zip", r"C:\fx\b.zip"]);
        assert_eq!(split_unquoted(r"C:\fx\\|b.zip", b'|'), [r"C:\fx\\", "b.zip"]);
        // An escaped separator does not split.
        assert_eq!(split_unquoted(r"a\|b|c", b'|'), [r"a\|b", "c"]);
    }

    #[test]
    fn options_split_at_colon_and_ampersand() {
        let (path, options) = super::parse_effect_item(r"fx.zip=a=1&b=t/2:c=x\&y").unwrap();
        assert_eq!(path, "fx.zip");
        let pairs: Vec<(&str, &str)> = options.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        assert_eq!(pairs, [("a", "1"), ("b", "t/2"), ("c", "x&y")]);
    }
}
