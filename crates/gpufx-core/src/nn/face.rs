//! [`FaceDetector`]: a single shot face detector (YuNet) on gpufx-nn.
//!
//! A face detector package (`gpufx_ai_tracking`, see `packages/gpufx_ai_tracking/yunet-2023mar/README.md`) is one
//! gpufx-nn model whose `io.json` (kind `tracking`, role `face_detector`) says how to feed it and read it. The
//! frame is scaled so its long side is `input_size`, padded with zeros to a multiple of `multiple`, run on the GPU,
//! and the raw class, objectness and box maps of each stride are read back and decoded on the CPU, then
//! non-maximum suppression keeps the best of overlapping boxes.
//!
//! Written from the YuNet paper and the description in the model's README; no detector code was copied.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use serde::Deserialize;

use super::{NnModel, NnPlan, Precision};
use crate::runtime::{GpuContext, Image};
use crate::Error;

/// The output maps of one stride.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct FaceHead {
    pub stride: u32,
    /// 1 channel class logits.
    pub cls: String,
    /// 1 channel objectness logits.
    pub obj: String,
    /// 4 channels: centre offset in cells (x, y) and log size in cells (w, h).
    pub bbox: String,
}

/// The `io.json` of a face detector package.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct FaceConfig {
    pub kind: String,
    pub role: String,
    pub inputs: HashMap<String, String>,
    /// `bgr` or `rgb`, values in [0, 255].
    pub channels: String,
    /// The long side of the model input, pixels.
    pub input_size: u32,
    /// The input sides are padded up to a multiple of it.
    pub multiple: u32,
    pub heads: Vec<FaceHead>,
    pub score_threshold: f32,
    pub nms_threshold: f32,
}

impl FaceConfig {
    fn parse(io: &serde_json::Value) -> Result<Self, Error> {
        let c: FaceConfig = serde_json::from_value(io.clone()).map_err(|e| Error::Package(format!("io.json: {e}")))?;
        if c.kind != "tracking" || c.role != "face_detector" {
            return Err(Error::Package("io.json: not a face detector (kind tracking, role face_detector)".into()));
        }
        if !c.inputs.contains_key("image") || !matches!(c.channels.as_str(), "bgr" | "rgb") {
            return Err(Error::Package("io.json: needs inputs.image and channels bgr or rgb".into()));
        }
        if c.input_size == 0 || c.multiple == 0 || !c.input_size.is_multiple_of(c.multiple) || c.heads.is_empty() {
            return Err(Error::Package("io.json: bad input_size, multiple or heads".into()));
        }
        if c.heads.iter().any(|h| h.stride == 0 || !c.multiple.is_multiple_of(h.stride)) {
            return Err(Error::Package("io.json: each stride must divide multiple".into()));
        }
        let unit = |v: f32| (0.0..=1.0).contains(&v);
        if !unit(c.score_threshold) || !unit(c.nms_threshold) {
            return Err(Error::Package("io.json: score_threshold and nms_threshold must be in [0, 1]".into()));
        }
        Ok(c)
    }
}

/// A face found in a frame: its top left corner and size in frame pixels, and its score (0 to 1).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FaceBox {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    pub score: f32,
}

/// Intersection over union of two boxes; 0 when either is empty.
pub fn iou(a: &FaceBox, b: &FaceBox) -> f32 {
    let ix = ((a.x + a.w).min(b.x + b.w) - a.x.max(b.x)).max(0.0);
    let iy = ((a.y + a.h).min(b.y + b.h) - a.y.max(b.y)).max(0.0);
    let inter = ix * iy;
    let union = a.w * a.h + b.w * b.h - inter;
    if union > 0.0 {
        inter / union
    } else {
        0.0
    }
}

/// Non-maximum suppression: the boxes by falling score, each kept unless it overlaps a kept one by more than
/// `threshold` (IoU).
pub fn nms(mut boxes: Vec<FaceBox>, threshold: f32) -> Vec<FaceBox> {
    boxes.retain(|b| b.score.is_finite() && b.w > 0.0 && b.h > 0.0);
    boxes.sort_by(|a, b| b.score.total_cmp(&a.score));
    let mut kept: Vec<FaceBox> = Vec::new();
    for b in boxes {
        if kept.iter().all(|k| iou(&b, k) <= threshold) {
            kept.push(b);
        }
    }
    kept
}

fn sigmoid(x: f32) -> f32 {
    1.0 / (1.0 + (-x).exp())
}

/// The boxes of one stride above `threshold`, in model input pixels: `cls`, `obj` are `h * w` logits, `bbox`
/// `4 * h * w`.
pub fn decode(stride: u32, w: u32, h: u32, cls: &[f32], obj: &[f32], bbox: &[f32], threshold: f32) -> Vec<FaceBox> {
    let n = (w * h) as usize;
    let s = stride as f32;
    let mut out = Vec::new();
    if cls.len() < n || obj.len() < n || bbox.len() < 4 * n {
        return out;
    }
    for i in 0..n {
        let score = (sigmoid(cls[i]) * sigmoid(obj[i])).clamp(0.0, 1.0).sqrt();
        if score.is_nan() || score < threshold {
            continue;
        }
        let (r, c) = ((i / w as usize) as f32, (i % w as usize) as f32);
        let cx = (c + bbox[i]) * s;
        let cy = (r + bbox[n + i]) * s;
        let bw = bbox[2 * n + i].exp() * s;
        let bh = bbox[3 * n + i].exp() * s;
        out.push(FaceBox { x: cx - bw / 2.0, y: cy - bh / 2.0, w: bw, h: bh, score });
    }
    out
}

/// The model input for a `w` x `h` frame: the scale to it and the padded input size.
pub fn input_layout(cfg: &FaceConfig, w: u32, h: u32) -> (f32, u32, u32) {
    let long = w.max(h).max(1) as f32;
    let scale = cfg.input_size as f32 / long;
    let side = |v: u32| (((v as f32 * scale).round() as u32).max(1)).div_ceil(cfg.multiple) * cfg.multiple;
    (scale, side(w), side(h))
}

/// A face detector on the GPU. Not thread safe.
pub struct FaceDetector {
    model: NnModel,
    config: FaceConfig,
    /// The plan of the last input size.
    plan: Option<((u32, u32), NnPlan)>,
}

impl FaceDetector {
    /// Loads a face detector package from a `.zip` or a directory.
    pub fn open(ctx: Arc<GpuContext>, path: impl AsRef<Path>) -> Result<Self, Error> {
        let files = crate::package::read_files(path.as_ref())?;
        Self::from_files(ctx, &files)
    }

    /// A detector from the files of its package.
    pub fn from_files(ctx: Arc<GpuContext>, files: &HashMap<String, Vec<u8>>) -> Result<Self, Error> {
        let get = |n: &str| files.get(n).map(Vec::as_slice);
        let model = get("model.json").ok_or_else(|| crate::used_for::wrong_kind(files, "model.json"))?;
        let weights = get("weights.bin").ok_or_else(|| Error::Package("missing weights.bin".into()))?;
        let io = get("io.json").ok_or_else(|| Error::Package("missing io.json".into()))?;
        let model = NnModel::from_parts_with(ctx, model, weights, Some(io), Precision::F32)?;
        crate::used_for::check(model.name(), model.used_for(), crate::used_for::AI_TRACKING)?;
        crate::used_for::check_kind(model.name(), &model.io, crate::used_for::AI_TRACKING)?;
        let config = FaceConfig::parse(&model.io)?;
        if !model.inputs().contains(&config.inputs["image"]) {
            return Err(Error::Package(format!("io.json: the model has no input \"{}\"", config.inputs["image"])));
        }
        for h in &config.heads {
            for o in [&h.cls, &h.obj, &h.bbox] {
                if !model.outputs().contains(o) {
                    return Err(Error::Package(format!("io.json: the model has no output \"{o}\"")));
                }
            }
        }
        Ok(FaceDetector { model, config, plan: None })
    }

    pub fn config(&self) -> &FaceConfig {
        &self.config
    }

    fn plan(&mut self, iw: u32, ih: u32) -> Result<&NnPlan, Error> {
        if self.plan.as_ref().is_none_or(|(s, _)| *s != (iw, ih)) {
            let input = self.config.inputs["image"].clone();
            let plan = self.model.plan(&[(input.as_str(), [3, ih, iw])])?;
            for h in &self.config.heads {
                let (sw, sh) = (iw / h.stride, ih / h.stride);
                for (o, c) in [(&h.cls, 1), (&h.obj, 1), (&h.bbox, 4)] {
                    let v = plan.tensor(o).expect("model output");
                    if (v.c, v.h, v.w) != (c, sh, sw) {
                        return Err(Error::Package(format!(
                            "output \"{o}\" is {} x {} x {}, stride {} wants {c} x {sh} x {sw}",
                            v.c, v.h, v.w, h.stride
                        )));
                    }
                }
            }
            self.plan = Some(((iw, ih), plan));
        }
        Ok(&self.plan.as_ref().expect("made").1)
    }

    /// Runs the model on an input tensor (`3 x ih x iw`, as the model takes it) and returns the raw maps by
    /// output name: for tests and for callers that prepare the input themselves.
    pub fn run_raw(&mut self, input: &[f32], iw: u32, ih: u32) -> Result<HashMap<String, Vec<f32>>, Error> {
        let name = self.config.inputs["image"].clone();
        let heads = self.config.heads.clone();
        let plan = self.plan(iw, ih)?;
        plan.write_input(&name, input)?;
        plan.run()?;
        let mut maps = HashMap::new();
        for h in &heads {
            for o in [&h.cls, &h.obj, &h.bbox] {
                maps.insert(o.clone(), plan.read(o)?);
            }
        }
        Ok(maps)
    }

    /// The boxes in input pixels of the raw maps of an `iw` x `ih` input, above `threshold`, before NMS.
    pub fn decode_raw(&self, maps: &HashMap<String, Vec<f32>>, iw: u32, ih: u32, threshold: f32) -> Vec<FaceBox> {
        let mut boxes = Vec::new();
        for h in &self.config.heads {
            let (Some(cls), Some(obj), Some(bbox)) = (maps.get(&h.cls), maps.get(&h.obj), maps.get(&h.bbox)) else { continue };
            boxes.extend(decode(h.stride, iw / h.stride, ih / h.stride, cls, obj, bbox, threshold));
        }
        boxes
    }

    /// The faces of `img` (RGBA) with the package's thresholds.
    pub fn detect(&mut self, img: &Image) -> Result<Vec<FaceBox>, Error> {
        let (s, n) = (self.config.score_threshold, self.config.nms_threshold);
        self.detect_with(img, s, n)
    }

    /// The faces of `img` (RGBA, frame pixels) scoring at least `score_threshold`, after NMS at `nms_threshold`.
    pub fn detect_with(&mut self, img: &Image, score_threshold: f32, nms_threshold: f32) -> Result<Vec<FaceBox>, Error> {
        let (w, h) = (img.width, img.height);
        if w == 0
            || h == 0
            || (img.stride as usize) < w as usize * 4
            || img.data.len() < img.stride as usize * (h as usize - 1) + w as usize * 4
        {
            return Err(Error::Frame("image buffer is too small".into()));
        }
        let (scale, iw, ih) = input_layout(&self.config, w, h);
        let input = resize_input(img, scale, iw, ih, self.config.channels == "bgr");
        let maps = self.run_raw(&input, iw, ih)?;
        let boxes = self.decode_raw(&maps, iw, ih, score_threshold);
        Ok(nms(boxes, nms_threshold)
            .into_iter()
            .map(|b| FaceBox { x: b.x / scale, y: b.y / scale, w: b.w / scale, h: b.h / scale, score: b.score })
            .collect())
    }
}

/// The model input of `img`: scaled by `scale` bilinearly (half-pixel centres, clamped to the frame), padded
/// with zeros to `iw` x `ih`, planes in BGR (or RGB) order, values in [0, 255].
fn resize_input(img: &Image, scale: f32, iw: u32, ih: u32, bgr: bool) -> Vec<f32> {
    let (w, h) = (img.width as usize, img.height as usize);
    let (iw, ih) = (iw as usize, ih as usize);
    let (rw, rh) = (((w as f32 * scale).round() as usize).clamp(1, iw), ((h as f32 * scale).round() as usize).clamp(1, ih));
    let mut out = vec![0f32; 3 * iw * ih];
    let order: [usize; 3] = if bgr { [2, 1, 0] } else { [0, 1, 2] };
    let px = |x: usize, y: usize, c: usize| f32::from(img.data[y * img.stride as usize + x * 4 + c]);
    let (sx_k, sy_k) = (w as f32 / rw as f32, h as f32 / rh as f32);
    for y in 0..rh {
        let sy = ((y as f32 + 0.5) * sy_k - 0.5).clamp(0.0, (h - 1) as f32);
        let y0 = sy.floor() as usize;
        let y1 = (y0 + 1).min(h - 1);
        let ay = sy - y0 as f32;
        for x in 0..rw {
            let sx = ((x as f32 + 0.5) * sx_k - 0.5).clamp(0.0, (w - 1) as f32);
            let x0 = sx.floor() as usize;
            let x1 = (x0 + 1).min(w - 1);
            let ax = sx - x0 as f32;
            for (plane, &c) in order.iter().enumerate() {
                let top = px(x0, y0, c) * (1.0 - ax) + px(x1, y0, c) * ax;
                let bottom = px(x0, y1, c) * (1.0 - ax) + px(x1, y1, c) * ax;
                out[(plane * ih + y) * iw + x] = top * (1.0 - ay) + bottom * ay;
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b(x: f32, y: f32, w: f32, h: f32, score: f32) -> FaceBox {
        FaceBox { x, y, w, h, score }
    }

    fn config() -> FaceConfig {
        FaceConfig::parse(&serde_json::json!({"kind":"tracking","role":"face_detector","inputs":{"image":"in0"},"channels":"bgr",
            "input_size":640,"multiple":32,"heads":[{"stride":8,"cls":"a","obj":"b","bbox":"c"}],"score_threshold":0.6,"nms_threshold":0.3}))
        .unwrap()
    }

    #[test]
    fn io_json_is_checked() {
        let c = config();
        assert_eq!((c.input_size, c.multiple), (640, 32));
        let mut bad = serde_json::json!({"kind":"tracking","role":"face_detector","inputs":{"image":"in0"},"channels":"bgr",
            "input_size":640,"multiple":32,"heads":[{"stride":64,"cls":"a","obj":"b","bbox":"c"}],"score_threshold":0.6,"nms_threshold":0.3});
        assert!(FaceConfig::parse(&bad).is_err(), "a stride that does not divide multiple");
        bad["heads"][0]["stride"] = 8.into();
        bad["role"] = "tracker".into();
        assert!(FaceConfig::parse(&bad).is_err());
    }

    #[test]
    fn iou_of_boxes() {
        assert_eq!(iou(&b(0.0, 0.0, 10.0, 10.0, 1.0), &b(0.0, 0.0, 10.0, 10.0, 1.0)), 1.0);
        assert_eq!(iou(&b(0.0, 0.0, 10.0, 10.0, 1.0), &b(20.0, 0.0, 10.0, 10.0, 1.0)), 0.0);
        let half = iou(&b(0.0, 0.0, 10.0, 10.0, 1.0), &b(5.0, 0.0, 10.0, 10.0, 1.0));
        assert!((half - 50.0 / 150.0).abs() < 1e-6);
        assert_eq!(iou(&b(0.0, 0.0, 0.0, 0.0, 1.0), &b(0.0, 0.0, 0.0, 0.0, 1.0)), 0.0);
    }

    #[test]
    fn nms_keeps_the_best_of_overlapping_boxes() {
        let kept = nms(
            vec![
                b(1.0, 0.0, 10.0, 10.0, 0.7),
                b(0.0, 0.0, 10.0, 10.0, 0.9),
                b(30.0, 0.0, 10.0, 10.0, 0.8),
                b(0.0, 0.0, 10.0, 10.0, f32::NAN),
            ],
            0.3,
        );
        assert_eq!(kept, vec![b(0.0, 0.0, 10.0, 10.0, 0.9), b(30.0, 0.0, 10.0, 10.0, 0.8)]);
    }

    #[test]
    fn decode_places_cells() {
        // a 2 x 2 map at stride 8: only cell (1, 0) scores, box centred half a cell right, 2 cells wide
        let (w, h) = (2, 2);
        let cls = vec![-10.0, -10.0, 10.0, -10.0];
        let obj = vec![10.0; 4];
        let mut bbox = vec![0.0; 16];
        bbox[2] = 0.5; // x offset of cell 2
        bbox[8 + 2] = 2f32.ln(); // log width
        let found = decode(8, w, h, &cls, &obj, &bbox, 0.5);
        assert_eq!(found.len(), 1);
        let f = found[0];
        // centre (0 + 0.5) * 8 = 4, (1 + 0) * 8 = 8; size 16 x 8
        assert!(
            (f.x - (4.0 - 8.0)).abs() < 1e-4 && (f.y - 4.0).abs() < 1e-4 && (f.w - 16.0).abs() < 1e-4 && (f.h - 8.0).abs() < 1e-4,
            "{f:?}"
        );
        assert!(f.score > 0.99);
    }

    #[test]
    fn layout_scales_the_long_side() {
        let c = config();
        let (s, w, h) = input_layout(&c, 640, 360);
        assert_eq!((s, w, h), (1.0, 640, 384));
        let (s, w, h) = input_layout(&c, 1920, 1080);
        assert!((s - 1.0 / 3.0).abs() < 1e-6);
        assert_eq!((w, h), (640, 384));
        assert_eq!(input_layout(&c, 360, 640).1, 384);
    }
}
