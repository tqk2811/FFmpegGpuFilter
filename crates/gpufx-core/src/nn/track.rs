//! [`NanoTrack`]: a Siamese single object tracker (NanoTrack V2 and others of its shape) on gpufx-nn.
//!
//! A tracker package (`gpufx_ai_tracking`, see `packages/gpufx_ai_tracking/*/README.md`) holds `tracker.json`
//! and two gpufx-nn models: `backbone/` (crop to features) and `head/` (template features and search features
//! to class scores and box sides). The first frame's box gives the template: a square crop around it with some
//! context, resized to `template_size` and run through the backbone once. Each next frame is cropped around the
//! last box at about twice that span, resized to `search_size`, run through the backbone and the head, and the
//! best cell of the score map (after the size and aspect penalty and the cosine window of SiamBAN) gives the new
//! box. Cropping (`track_crop.wgsl`), the networks and the box decoding (`track_decode.wgsl`) run on the GPU;
//! only the decoded cells (8 values each) are read back.
//!
//! Written from the NanoTrack and SiamBAN papers and the public description of the models; no tracker code
//! was copied.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use serde::Deserialize;

use super::kernels::{compute_pipeline, storage_entry, uniform_entry, PARAM_SLOT};
use super::plan::read_buffer;
use super::{NnModel, NnPlan, Precision};
use crate::runtime::{GpuContext, Image};
use crate::Error;

/// `tracker.json` of a tracker package.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct TrackerConfig {
    pub format: String,
    pub version: u32,
    pub kind: String,
    /// The folders of the two models in the package.
    pub backbone: String,
    pub head: String,
    /// The side of the template crop and of the search crop, pixels.
    pub template_size: u32,
    pub search_size: u32,
    /// Search crop pixels per score cell.
    pub stride: u32,
    /// `bgr` or `rgb`: the channel order the backbone takes (values in [0, 255]).
    pub channels: String,
    /// The context around the box in the template crop, as a part of the box's width plus height.
    pub context_amount: f32,
    /// How much the cosine window counts against the score, 0 to 1.
    pub window_influence: f32,
    /// How hard a change of size or aspect is penalised.
    pub penalty_k: f32,
    /// How much of the found size the box takes per frame (times the score), 0 to 1.
    pub size_rate: f32,
}

impl TrackerConfig {
    fn parse(bytes: &[u8]) -> Result<Self, Error> {
        let c: TrackerConfig = serde_json::from_slice(bytes).map_err(|e| Error::Package(format!("tracker.json: {e}")))?;
        if c.format != "gpufx-nn-tracker" || c.version != 1 || c.kind != "siamese" {
            return Err(Error::Package("tracker.json: not a gpufx-nn-tracker version 1 of kind siamese".into()));
        }
        let simple = |d: &str| !d.is_empty() && d != "." && d != ".." && !d.contains(['/', '\\', ':']);
        if !simple(&c.backbone) || !simple(&c.head) {
            return Err(Error::Package("tracker.json: the model folders must be simple names".into()));
        }
        if c.template_size == 0 || c.search_size < c.template_size || c.stride == 0 || !matches!(c.channels.as_str(), "bgr" | "rgb") {
            return Err(Error::Package("tracker.json: bad sizes, stride or channels".into()));
        }
        let unit = |v: f32| (0.0..=1.0).contains(&v);
        if !unit(c.window_influence)
            || !unit(c.size_rate)
            || c.context_amount.is_nan()
            || c.context_amount < 0.0
            || c.penalty_k.is_nan()
            || c.penalty_k < 0.0
        {
            return Err(Error::Package("tracker.json: window_influence and size_rate must be in [0, 1]".into()));
        }
        Ok(c)
    }
}

/// A box in frame pixels: its centre (pixel centres are whole numbers) and size.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TrackRect {
    pub cx: f32,
    pub cy: f32,
    pub w: f32,
    pub h: f32,
}

/// What one tracker step found.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TrackFound {
    /// The new box.
    pub rect: TrackRect,
    /// The object probability of the chosen cell, 0 to 1: how sure the step is.
    pub score: f32,
}

/// The smallest box side the tracker keeps, pixels.
const MIN_SIDE: f32 = 4.0;

/// A Siamese tracker on the GPU. Not thread safe; one per tracked object.
pub struct NanoTrack {
    ctx: Arc<GpuContext>,
    config: TrackerConfig,
    template_plan: NnPlan,
    search_plan: NnPlan,
    head_plan: NnPlan,
    backbone_input: String,
    backbone_output: String,
    /// The head inputs: template features, search features.
    head_inputs: [String; 2],
    /// Names of the head outputs: class scores (2 channels) and box sides (4 channels).
    cls: String,
    loc: String,
    score_size: u32,
    crop_layout: wgpu::BindGroupLayout,
    crop_pipeline: wgpu::ComputePipeline,
    decode_pipeline: wgpu::ComputePipeline,
    decode_group: wgpu::BindGroup,
    decode_params: wgpu::Buffer,
    decoded: wgpu::Buffer,
    readback: wgpu::Buffer,
    /// The frame, one u32 per pixel, and its capacity in pixels.
    frame: Option<(wgpu::Buffer, u64)>,
    state: Option<TrackRect>,
}

fn part_model(ctx: &Arc<GpuContext>, files: &HashMap<String, Vec<u8>>, dir: &str) -> Result<NnModel, Error> {
    let get = |n: &str| files.get(&format!("{dir}/{n}")).map(Vec::as_slice);
    let model = get("model.json").ok_or_else(|| Error::Package(format!("missing {dir}/model.json")))?;
    let weights = get("weights.bin").ok_or_else(|| Error::Package(format!("missing {dir}/weights.bin")))?;
    let m = NnModel::from_parts_with(ctx.clone(), model, weights, get("io.json"), Precision::F32)?;
    crate::used_for::check(m.name(), m.used_for(), crate::used_for::AI_TRACKING)?;
    crate::used_for::check_kind(m.name(), &m.io, crate::used_for::AI_TRACKING)?;
    Ok(m)
}

fn params_buffer(device: &wgpu::Device, label: &str) -> wgpu::Buffer {
    device.create_buffer(&wgpu::BufferDescriptor {
        label: Some(label),
        size: PARAM_SLOT,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    })
}

fn words(values: &[u32]) -> Vec<u8> {
    values.iter().flat_map(|v| v.to_le_bytes()).collect()
}

impl NanoTrack {
    /// Loads a tracker package from a `.zip` or a directory.
    pub fn open(ctx: Arc<GpuContext>, path: impl AsRef<Path>) -> Result<Self, Error> {
        let files = crate::package::read_files(path.as_ref())?;
        Self::from_files(ctx, &files)
    }

    /// A tracker from the files of its package (paths relative to the package root, `/` separated).
    pub fn from_files(ctx: Arc<GpuContext>, files: &HashMap<String, Vec<u8>>) -> Result<Self, Error> {
        let config = TrackerConfig::parse(files.get("tracker.json").ok_or_else(|| Error::Package("missing tracker.json".into()))?)?;
        let backbone = part_model(&ctx, files, &config.backbone)?;
        let head = part_model(&ctx, files, &config.head)?;
        let one_input = |m: &NnModel, what: &str| match (m.inputs(), m.outputs()) {
            ([i], [o]) => Ok((i.clone(), o.clone())),
            _ => Err(Error::Package(format!("the {what} model must have one input and one output"))),
        };
        let (bin, bout) = one_input(&backbone, "backbone")?;
        let (t, s) = (config.template_size, config.search_size);
        let template_plan = backbone.plan(&[(bin.as_str(), [3, t, t])])?;
        let search_plan = backbone.plan(&[(bin.as_str(), [3, s, s])])?;
        let zf = template_plan.tensor(&bout).expect("backbone output");
        let xf = search_plan.tensor(&bout).expect("backbone output");
        let [hz, hx] = match head.inputs() {
            [a, b] => [a.clone(), b.clone()],
            _ => return Err(Error::Package("the head model must have two inputs: template and search features".into())),
        };
        let head_plan = head.plan(&[(hz.as_str(), [zf.c, zf.h, zf.w]), (hx.as_str(), [xf.c, xf.h, xf.w])])?;
        let mut cls = None;
        let mut loc = None;
        for o in head.outputs() {
            let v = head_plan.tensor(o).expect("head output");
            match v.c {
                2 => cls = Some((o.clone(), v)),
                4 => loc = Some((o.clone(), v)),
                _ => {}
            }
        }
        let (Some((cls, cv)), Some((loc, lv))) = (cls, loc) else {
            return Err(Error::Package("the head model must give 2 channel class scores and 4 channel box sides".into()));
        };
        if cv.h != cv.w || lv.h != cv.h || lv.w != cv.w {
            return Err(Error::Package("the class scores and box sides of the head must be one square size".into()));
        }
        let score_size = cv.h;
        let device = &ctx.device;
        let cache = ctx.shader_cache.as_deref();
        let layout = |label, entries: &[wgpu::BindGroupLayoutEntry]| {
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some(label), entries })
        };
        let pl = |l: &wgpu::BindGroupLayout| {
            device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("gpufx nn track"),
                bind_group_layouts: &[Some(l)],
                immediate_size: 0,
            })
        };
        let crop_entries = [uniform_entry(0), storage_entry(1, true), storage_entry(2, false)];
        let crop_layout = layout("gpufx nn track crop", &crop_entries);
        let crop_pipeline = compute_pipeline(
            device,
            cache,
            "gpufx nn track crop",
            &pl(&crop_layout),
            &crop_entries,
            include_str!("track_crop.wgsl").into(),
        );
        let decode_entries = [uniform_entry(0), storage_entry(1, true), storage_entry(2, true), storage_entry(3, false)];
        let decode_layout = layout("gpufx nn track decode", &decode_entries);
        let decode_pipeline = compute_pipeline(
            device,
            cache,
            "gpufx nn track decode",
            &pl(&decode_layout),
            &decode_entries,
            include_str!("track_decode.wgsl").into(),
        );
        let cells = u64::from(score_size * score_size);
        let decoded = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx nn track decoded"),
            size: cells * 8 * 4,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let readback = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx nn track readback"),
            size: cells * 8 * 4,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let decode_params = params_buffer(device, "gpufx nn track decode params");
        let decode_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("gpufx nn track decode"),
            layout: &decode_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &decode_params,
                        offset: 0,
                        size: wgpu::BufferSize::new(PARAM_SLOT),
                    }),
                },
                wgpu::BindGroupEntry { binding: 1, resource: head_plan.buffer(cv.slot).as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: head_plan.buffer(lv.slot).as_entire_binding() },
                wgpu::BindGroupEntry { binding: 3, resource: decoded.as_entire_binding() },
            ],
        });
        Ok(NanoTrack {
            ctx: ctx.clone(),
            config,
            template_plan,
            search_plan,
            head_plan,
            backbone_input: bin,
            backbone_output: bout,
            head_inputs: [hz, hx],
            cls,
            loc,
            score_size,
            crop_layout,
            crop_pipeline,
            decode_pipeline,
            decode_group,
            decode_params,
            decoded,
            readback,
            frame: None,
            state: None,
        })
    }

    pub fn config(&self) -> &TrackerConfig {
        &self.config
    }

    /// The side of the score map.
    pub fn score_size(&self) -> u32 {
        self.score_size
    }

    /// The box after the last step; `None` before [`NanoTrack::init`].
    pub fn rect(&self) -> Option<TrackRect> {
        self.state
    }

    /// Puts the tracker's box back to `rect` (kept from [`NanoTrack::rect`]), keeping the template: a caller that
    /// deems a step of [`NanoTrack::update`] lost uses it so the next search starts where the object was last seen.
    /// Does nothing before [`NanoTrack::init`].
    pub fn set_rect(&mut self, rect: TrackRect) {
        if self.state.is_some() {
            self.state = Some(rect);
        }
    }

    /// Uploads `img` and returns its mean colour (the pad of the crops).
    fn upload(&mut self, img: &Image) -> Result<[f32; 3], Error> {
        let (w, h) = (img.width as usize, img.height as usize);
        if w == 0 || h == 0 || (img.stride as usize) < w * 4 || img.data.len() < img.stride as usize * (h - 1) + w * 4 {
            return Err(Error::Frame("image buffer is too small".into()));
        }
        let mut packed = Vec::with_capacity(w * h * 4);
        let mut sum = [0u64; 3];
        for y in 0..h {
            let row = &img.data[y * img.stride as usize..][..w * 4];
            for px in row.as_chunks::<4>().0 {
                sum[0] += u64::from(px[0]);
                sum[1] += u64::from(px[1]);
                sum[2] += u64::from(px[2]);
            }
            packed.extend_from_slice(row);
        }
        let pixels = (w * h) as u64;
        let device = &self.ctx.device;
        if self.frame.as_ref().is_none_or(|(_, cap)| *cap < pixels) {
            let buffer = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("gpufx nn track frame"),
                size: pixels * 4,
                usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            self.frame = Some((buffer, pixels));
        }
        self.ctx.queue.write_buffer(&self.frame.as_ref().expect("made").0, 0, &packed);
        Ok(sum.map(|s| s as f32 / pixels as f32))
    }

    /// Records the crop of the frame uploaded last: a square of side `span` frame pixels centred on (`cx`, `cy`)
    /// (rounded to whole pixels as the models were trained), resized to the input of `plan`.
    #[allow(clippy::too_many_arguments)]
    fn encode_crop(&self, enc: &mut wgpu::CommandEncoder, img: &Image, pad: [f32; 3], cx: f32, cy: f32, span: f32, template: bool) {
        let span = span.round().max(1.0);
        let c = ((span + 1.0) / 2.0).floor();
        let x0 = (cx - c + 0.5).floor();
        let y0 = (cy - c + 0.5).floor();
        let (plan, size) =
            if template { (&self.template_plan, self.config.template_size) } else { (&self.search_plan, self.config.search_size) };
        let input = plan.tensor(&self.backbone_input).expect("backbone input");
        let bgr = (self.config.channels == "bgr") as u32;
        let p = words(&[
            img.width,
            img.height,
            size,
            input.offset,
            x0.to_bits(),
            y0.to_bits(),
            span.to_bits(),
            bgr,
            pad[0].to_bits(),
            pad[1].to_bits(),
            pad[2].to_bits(),
        ]);
        let device = &self.ctx.device;
        // one params buffer per crop: a template crop and a search crop may be recorded before a submit
        let params = params_buffer(device, "gpufx nn track crop params");
        self.ctx.queue.write_buffer(&params, 0, &p);
        let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("gpufx nn track crop"),
            layout: &self.crop_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &params,
                        offset: 0,
                        size: wgpu::BufferSize::new(PARAM_SLOT),
                    }),
                },
                wgpu::BindGroupEntry { binding: 1, resource: self.frame.as_ref().expect("uploaded").0.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: plan.buffer(input.slot).as_entire_binding() },
            ],
        });
        let mut pass = enc.begin_compute_pass(&Default::default());
        pass.set_pipeline(&self.crop_pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.dispatch_workgroups(size.div_ceil(16), size.div_ceil(16), 1);
    }

    /// The template crop of `img` around `rect` (3 x template_size², values in [0, 255]): for tests.
    pub fn template_crop(&mut self, img: &Image, rect: TrackRect) -> Result<Vec<f32>, Error> {
        let pad = self.upload(img)?;
        let span = self.template_span(rect);
        let mut enc = self.ctx.device.create_command_encoder(&Default::default());
        self.encode_crop(&mut enc, img, pad, rect.cx, rect.cy, span, true);
        self.ctx.queue.submit([enc.finish()]);
        self.template_plan.read(&self.backbone_input)
    }

    fn template_span(&self, rect: TrackRect) -> f32 {
        let context = self.config.context_amount * (rect.w + rect.h);
        ((rect.w + context) * (rect.h + context)).sqrt()
    }

    /// Starts tracking `rect` of `img`: the template features.
    pub fn init(&mut self, img: &Image, rect: TrackRect) -> Result<(), Error> {
        if !(rect.w > 0.0 && rect.h > 0.0 && rect.cx.is_finite() && rect.cy.is_finite()) {
            return Err(Error::Frame("the box to track is empty".into()));
        }
        let pad = self.upload(img)?;
        let span = self.template_span(rect);
        let device = self.ctx.device.clone();
        let mut enc = device.create_command_encoder(&Default::default());
        self.encode_crop(&mut enc, img, pad, rect.cx, rect.cy, span, true);
        {
            let mut pass = enc.begin_compute_pass(&Default::default());
            self.template_plan.encode(&mut pass);
        }
        self.ctx.queue.submit([enc.finish()]);
        self.state = Some(rect);
        Ok(())
    }

    /// Follows the box into `img`.
    pub fn update(&mut self, img: &Image) -> Result<TrackFound, Error> {
        let rect = self.state.ok_or_else(|| Error::Frame("the tracker has no box: call init first".into()))?;
        let pad = self.upload(img)?;
        let cfg = self.config.clone();
        let sz = self.template_span(rect);
        let scale = cfg.template_size as f32 / sz;
        let span = sz * cfg.search_size as f32 / cfg.template_size as f32;
        let device = self.ctx.device.clone();
        let mut enc = device.create_command_encoder(&Default::default());
        self.encode_crop(&mut enc, img, pad, rect.cx, rect.cy, span, false);
        {
            let mut pass = enc.begin_compute_pass(&Default::default());
            self.search_plan.encode(&mut pass);
        }
        // The template features stay in the template plan's output; the head plan may reuse the buffer of its
        // inputs for later tensors, so they are copied in again for every run.
        let zf = self.template_plan.tensor(&self.backbone_output).expect("backbone output");
        let hz = self.head_plan.tensor(&self.head_inputs[0]).expect("head input");
        enc.copy_buffer_to_buffer(
            self.template_plan.buffer(zf.slot),
            u64::from(zf.offset) * 4,
            self.head_plan.buffer(hz.slot),
            u64::from(hz.offset) * 4,
            u64::from(zf.len()) * 4,
        );
        let xf = self.search_plan.tensor(&self.backbone_output).expect("backbone output");
        let hx = self.head_plan.tensor(&self.head_inputs[1]).expect("head input");
        enc.copy_buffer_to_buffer(
            self.search_plan.buffer(xf.slot),
            u64::from(xf.offset) * 4,
            self.head_plan.buffer(hx.slot),
            u64::from(hx.offset) * 4,
            u64::from(xf.len()) * 4,
        );
        let cv = self.head_plan.tensor(&self.cls).expect("class scores");
        let lv = self.head_plan.tensor(&self.loc).expect("box sides");
        let p = words(&[
            self.score_size,
            cv.offset,
            lv.offset,
            (cfg.stride as f32).to_bits(),
            ((cfg.search_size / 2) as f32).to_bits(),
            (rect.w * scale).to_bits(),
            (rect.h * scale).to_bits(),
            cfg.window_influence.to_bits(),
            cfg.penalty_k.to_bits(),
        ]);
        self.ctx.queue.write_buffer(&self.decode_params, 0, &p);
        {
            let mut pass = enc.begin_compute_pass(&Default::default());
            self.head_plan.encode(&mut pass);
        }
        {
            let mut pass = enc.begin_compute_pass(&Default::default());
            pass.set_pipeline(&self.decode_pipeline);
            pass.set_bind_group(0, &self.decode_group, &[]);
            pass.dispatch_workgroups((self.score_size * self.score_size).div_ceil(64), 1, 1);
        }
        enc.copy_buffer_to_buffer(&self.decoded, 0, &self.readback, 0, self.decoded.size());
        self.ctx.queue.submit([enc.finish()]);
        let cells: Vec<f32> =
            read_buffer(&device, &self.readback, |b| b.as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect())?;
        let found = choose(&cells, rect, scale, &cfg, img.width as f32, img.height as f32);
        self.state = Some(found.rect);
        Ok(found)
    }
}

/// The new box from the decoded cells (8 values each, see `track_decode.wgsl`): the cell of the best windowed
/// score; its centre moves the box, its size moves the box's size by `size_rate` times its score.
fn choose(cells: &[f32], rect: TrackRect, scale: f32, cfg: &TrackerConfig, fw: f32, fh: f32) -> TrackFound {
    let best = cells
        .as_chunks::<8>()
        .0
        .iter()
        .enumerate()
        .filter(|(_, c)| c.iter().all(|v| v.is_finite()))
        .max_by(|a, b| a.1[0].total_cmp(&b.1[0]))
        .map(|(i, _)| i);
    let Some(best) = best else { return TrackFound { rect, score: 0.0 } };
    let c = &cells[best * 8..][..8];
    let (x1, y1, x2, y2) = (c[4], c[5], c[6], c[7]);
    let center = (cfg.search_size / 2) as f32;
    let dx = ((x1 + x2) / 2.0 - center) / scale;
    let dy = ((y1 + y2) / 2.0 - center) / scale;
    let lr = c[1] * cfg.size_rate;
    let w = (x2 - x1) / scale * lr + rect.w * (1.0 - lr);
    let h = (y2 - y1) / scale * lr + rect.h * (1.0 - lr);
    let rect = TrackRect {
        cx: (rect.cx + dx).clamp(0.0, (fw - 1.0).max(0.0)),
        cy: (rect.cy + dy).clamp(0.0, (fh - 1.0).max(0.0)),
        // a frame narrower than MIN_SIDE: the side is MIN_SIDE (`clamp` panics when min > max)
        w: w.clamp(MIN_SIDE, fw.max(MIN_SIDE)),
        h: h.clamp(MIN_SIDE, fh.max(MIN_SIDE)),
    };
    TrackFound { rect, score: c[2] }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> TrackerConfig {
        TrackerConfig::parse(
            br#"{"format":"gpufx-nn-tracker","version":1,"kind":"siamese","backbone":"backbone","head":"head","template_size":127,
            "search_size":255,"stride":16,"channels":"bgr","context_amount":0.5,"window_influence":0.455,"penalty_k":0.055,"size_rate":0.37}"#,
        )
        .unwrap()
    }

    #[test]
    fn tracker_json_is_checked() {
        let c = config();
        assert_eq!((c.template_size, c.search_size, c.stride), (127, 255, 16));
        assert!(TrackerConfig::parse(br#"{"format":"gpufx-nn-tracker","version":2}"#).is_err());
        let bad = serde_json::to_vec(&serde_json::json!({"format":"gpufx-nn-tracker","version":1,"kind":"siamese","backbone":"../x","head":"head",
            "template_size":127,"search_size":255,"stride":16,"channels":"bgr","context_amount":0.5,"window_influence":0.455,"penalty_k":0.055,"size_rate":0.37})).unwrap();
        assert!(TrackerConfig::parse(&bad).is_err());
    }

    #[test]
    fn the_best_cell_moves_the_box() {
        let c = config();
        let rect = TrackRect { cx: 100.0, cy: 80.0, w: 40.0, h: 20.0 };
        let scale = 2.0;
        // two cells: a weak one and a strong one 32 crop pixels right of the centre, box 80 x 40 crop pixels
        let mut cells = vec![0.1, 0.1, 0.1, 0.0, 117.0, 117.0, 137.0, 137.0];
        cells.extend([0.9, 1.0, 0.95, 0.0, 119.0, 107.0, 199.0, 147.0]);
        let f = choose(&cells, rect, scale, &c, 640.0, 360.0);
        assert_eq!(f.score, 0.95);
        assert!((f.rect.cx - 116.0).abs() < 1e-4 && (f.rect.cy - 80.0).abs() < 1e-4, "{:?}", f.rect);
        // same size found: the size stays
        assert!((f.rect.w - 40.0).abs() < 1e-4 && (f.rect.h - 20.0).abs() < 1e-4);
        let nan = vec![f32::NAN; 8];
        assert_eq!(choose(&nan, rect, scale, &c, 640.0, 360.0).score, 0.0, "no finite cell: the box stays");
        // a frame smaller than MIN_SIDE does not panic
        let tiny = choose(&cells, rect, scale, &c, 2.0, 0.5);
        assert!(tiny.rect.w == MIN_SIDE && tiny.rect.h == MIN_SIDE && tiny.rect.cx <= 1.0 && tiny.rect.cy == 0.0, "{:?}", tiny.rect);
    }
}
