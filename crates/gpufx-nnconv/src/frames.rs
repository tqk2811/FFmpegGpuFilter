//! Dev helpers around the reference executor: PNG io, the RIFE frame interpolation pre/post processing
//! described by `io.json`, and PSNR.

use std::collections::HashMap;
use std::path::Path;

use crate::reference::{Reference, Tensor};
use crate::{fail, Result};

/// An 8 bit RGB image, interleaved.
pub struct Rgb8 {
    pub w: usize,
    pub h: usize,
    pub data: Vec<u8>,
}

pub fn load_png(path: &Path) -> Result<Rgb8> {
    let img = image::open(path).map_err(|e| crate::Error(format!("{}: {e}", path.display())))?.to_rgb8();
    Ok(Rgb8 { w: img.width() as usize, h: img.height() as usize, data: img.into_raw() })
}

pub fn save_png(path: &Path, img: &Rgb8) -> Result<()> {
    let buf =
        image::RgbImage::from_raw(img.w as u32, img.h as u32, img.data.clone()).ok_or_else(|| crate::Error("bad image size".into()))?;
    buf.save(path).map_err(|e| crate::Error(format!("{}: {e}", path.display())))
}

/// PSNR in dB over all channels (infinite for identical images).
pub fn psnr(a: &Rgb8, b: &Rgb8) -> Result<f64> {
    if a.w != b.w || a.h != b.h {
        return fail(format!("image sizes differ: {}x{} and {}x{}", a.w, a.h, b.w, b.h));
    }
    let sum: f64 = a.data.iter().zip(&b.data).map(|(&x, &y)| (x as f64 - y as f64).powi(2)).sum();
    let mse = sum / a.data.len() as f64;
    Ok(if mse == 0.0 { f64::INFINITY } else { 10.0 * (255.0f64 * 255.0 / mse).log10() })
}

/// Border reflection matching the ncnn `realesrgan_preproc` shader: `src = abs(i)` then
/// `(n-1) - abs(src - (n-1))`, i.e. mirror without repeating the edge pixel (OpenCV `BORDER_REFLECT_101`).
/// Folded with period `2n - 2` so a pad wider than the image stays in range.
fn reflect101(i: isize, n: usize) -> usize {
    if n <= 1 {
        return 0;
    }
    let period = 2 * (n as isize - 1);
    let m = i.rem_euclid(period);
    (if m < n as isize { m } else { period - m }) as usize
}

/// RGB 0..1, planar, padded by `pad` on every border. `replicate` repeats the edge pixel,
/// `reflect` mirrors without repeating it (ncnn's realesrgan preprocessing).
fn to_planes_padded(img: &Rgb8, pad: usize, replicate: bool) -> Tensor {
    let (w, h) = (img.w + 2 * pad, img.h + 2 * pad);
    let mut t = Tensor::zeros(3, h, w);
    for c in 0..3 {
        for y in 0..h {
            let sy = if replicate {
                (y as isize - pad as isize).clamp(0, img.h as isize - 1) as usize
            } else {
                reflect101(y as isize - pad as isize, img.h)
            };
            for x in 0..w {
                let sx = if replicate {
                    (x as isize - pad as isize).clamp(0, img.w as isize - 1) as usize
                } else {
                    reflect101(x as isize - pad as isize, img.w)
                };
                t.data[c * h * w + y * w + x] = img.data[(sy * img.w + sx) * 3 + c] as f32 / 255.0;
            }
        }
    }
    t
}

/// Upscales one image with the CPU reference executor, following the `super_resolution` io.json of the
/// package: pad by `tile_pad` with `pad_mode` (`reflect`, else replicate), run, crop the `scale * tile_pad` border, clamp to `output_clamp`,
/// `*255 + 0.5` truncated. The whole image is run at once (no tiling needed in the reference).
pub fn upscale(model: &Reference, img: &Rgb8) -> Result<Rgb8> {
    let io = &model.io;
    if io["kind"] != "super_resolution" {
        return fail("io.json is not a super_resolution description");
    }
    let in_name = io["inputs"]["image"].as_str().ok_or_else(|| crate::Error("io.json has no inputs.image".into()))?.to_string();
    let out_name = io["output"].as_str().ok_or_else(|| crate::Error("io.json has no output".into()))?;
    let scale = io["scale"].as_u64().ok_or_else(|| crate::Error("io.json has no integer scale".into()))? as usize;
    if scale == 0 {
        return fail("io.json scale must be positive");
    }
    let tile_pad = io["tile_pad"].as_u64().unwrap_or(0) as usize;
    let clamp = [io["output_clamp"][0].as_f64().unwrap_or(0.0) as f32, io["output_clamp"][1].as_f64().unwrap_or(1.0) as f32];
    let replicate = io["pad_mode"].as_str() != Some("reflect");

    let mut inputs = HashMap::new();
    inputs.insert(in_name, to_planes_padded(img, tile_pad, replicate));
    let mut outputs = model.run(inputs)?;
    let Some(out) = outputs.remove(out_name) else { return fail(format!("no output \"{out_name}\"")) };
    let (ow, oh) = (img.w * scale, img.h * scale);
    let (crop_x, crop_y) = (tile_pad * scale, tile_pad * scale);
    if out.c != 3 || out.h < oh + crop_y || out.w < ow + crop_x {
        return fail(format!("output is {}x{}x{}, expected at least 3x{}x{}", out.c, out.h, out.w, oh + crop_y, ow + crop_x));
    }
    let mut data = vec![0u8; ow * oh * 3];
    for c in 0..3 {
        for y in 0..oh {
            for x in 0..ow {
                let v = out.data[c * out.h * out.w + (y + crop_y) * out.w + (x + crop_x)].clamp(clamp[0], clamp[1]);
                data[(y * ow + x) * 3 + c] = (v * 255.0 + 0.5).floor().clamp(0.0, 255.0) as u8;
            }
        }
    }
    Ok(Rgb8 { w: ow, h: oh, data })
}

/// RGB 0..1, planar, zero padded right and bottom to `w_padded x h_padded`.
fn to_planes(img: &Rgb8, w_padded: usize, h_padded: usize) -> Tensor {
    let mut t = Tensor::zeros(3, h_padded, w_padded);
    for c in 0..3 {
        for y in 0..img.h {
            for x in 0..img.w {
                t.data[c * h_padded * w_padded + y * w_padded + x] = img.data[(y * img.w + x) * 3 + c] as f32 / 255.0;
            }
        }
    }
    t
}

/// Interpolates between two frames at time `t` in (0, 1) following the `frame_interp` io.json of the package:
/// pad to `pad_multiple`, run, crop, clamp to `output_clamp`, `*255 + 0.5` truncated.
pub fn interpolate(model: &Reference, f0: &Rgb8, f1: &Rgb8, t: f32) -> Result<Rgb8> {
    interpolate_with(model, f0, f1, t, &[])
}

/// `pad_multiple` of io.json at the parameter values `params` (the others at their defaults): a number, or
/// `ceil(mul * param ^ pow)`.
pub fn pad_multiple(model: &Reference, params: &[(&str, f32)]) -> Result<usize> {
    let v = &model.io["pad_multiple"];
    if !v.is_object() {
        return Ok(v.as_u64().unwrap_or(1).max(1) as usize);
    }
    let Some(name) = v["param"].as_str() else { return fail("io.json: pad_multiple has no \"param\"") };
    let Some(p) = model.params.iter().find(|p| p.name == name) else {
        return fail(format!("io.json: pad_multiple names param \"{name}\" the model does not declare"));
    };
    let x = params.iter().rev().find(|(n, _)| *n == name).map_or(p.default, |&(_, x)| x) as f64;
    let m = (v["mul"].as_f64().unwrap_or(1.0) * x.powf(v["pow"].as_f64().unwrap_or(1.0))).ceil();
    if !m.is_finite() || !(1.0..=4096.0).contains(&m) {
        return fail(format!("io.json: pad_multiple {m} at {name} = {x} is not in [1, 4096]"));
    }
    Ok(m as usize)
}

/// [`interpolate`] with model parameter values.
pub fn interpolate_with(model: &Reference, f0: &Rgb8, f1: &Rgb8, t: f32, params: &[(&str, f32)]) -> Result<Rgb8> {
    if f0.w != f1.w || f0.h != f1.h {
        return fail("frames differ in size");
    }
    let io = &model.io;
    if io["kind"] != "frame_interp" {
        return fail("io.json is not a frame_interp description");
    }
    let name = |k: &str| io["inputs"][k].as_str().map(String::from).ok_or_else(|| crate::Error(format!("io.json has no inputs.{k}")));
    let out_name = io["output"].as_str().ok_or_else(|| crate::Error("io.json has no output".into()))?;
    let mult = pad_multiple(model, params)?;
    let clamp = [io["output_clamp"][0].as_f64().unwrap_or(0.0) as f32, io["output_clamp"][1].as_f64().unwrap_or(1.0) as f32];
    let (wp, hp) = (f0.w.div_ceil(mult) * mult, f0.h.div_ceil(mult) * mult);

    let mut inputs = HashMap::new();
    inputs.insert(name("frame0")?, to_planes(f0, wp, hp));
    inputs.insert(name("frame1")?, to_planes(f1, wp, hp));
    inputs.insert(name("timestep")?, Tensor::filled(1, hp, wp, t));
    let mut outputs = model.run_with(inputs, params)?;
    let Some(out) = outputs.remove(out_name) else { return fail(format!("no output \"{out_name}\"")) };
    if out.c != 3 || out.h != hp || out.w != wp {
        return fail(format!("output is {}x{}x{}, expected 3x{hp}x{wp}", out.c, out.h, out.w));
    }
    let mut data = vec![0u8; f0.w * f0.h * 3];
    for c in 0..3 {
        for y in 0..f0.h {
            for x in 0..f0.w {
                let v = out.data[c * hp * wp + y * wp + x].clamp(clamp[0], clamp[1]);
                data[(y * f0.w + x) * 3 + c] = (v * 255.0 + 0.5).floor().clamp(0.0, 255.0) as u8;
            }
        }
    }
    Ok(Rgb8 { w: f0.w, h: f0.h, data })
}

#[cfg(test)]
mod tests {
    use super::reflect101;

    #[test]
    fn reflect101_mirrors_without_edge_repeat() {
        let row: Vec<usize> = (-3..6).map(|i| reflect101(i, 3)).collect();
        assert_eq!(row, [1, 2, 1, 0, 1, 2, 1, 0, 1]);
    }

    #[test]
    fn reflect101_pad_wider_than_image_stays_in_range() {
        // a 10 px pad on a 3 px or 1 px side used to wrap to a huge index and panic
        for n in [1usize, 2, 3] {
            for i in -10..(n as isize + 10) {
                assert!(reflect101(i, n) < n, "i={i} n={n}");
            }
        }
    }
}

/// The model size `(w, h)` of a `w x h` frame for a `matting` io.json `size` (see `MatteSize` in gpufx-core):
/// `short_side` scales the short side to `short_side` and rounds each side to the nearest multiple of `multiple`
/// (at least one); `fixed` is `width x height`.
pub fn matte_size(io: &serde_json::Value, w: usize, h: usize) -> Result<(usize, usize)> {
    let s = &io["size"];
    let get = |k: &str| s[k].as_u64().filter(|v| *v > 0).map(|v| v as usize).ok_or_else(|| crate::Error(format!("io.json size.{k}")));
    match s["mode"].as_str() {
        Some("fixed") => Ok((get("width")?, get("height")?)),
        Some("short_side") => {
            let multiple = if s.get("multiple").is_some() { get("multiple")? } else { 1 };
            let k = get("short_side")? as f64 / w.min(h).max(1) as f64;
            let side = |v: usize| (((v as f64 * k) / multiple as f64).round() as usize).max(1) * multiple;
            Ok((side(w), side(h)))
        }
        _ => fail("io.json size.mode must be \"short_side\" or \"fixed\""),
    }
}

/// The source taps of output pixel `d` of a bilinear resize from `i` to `o` pixels: half-pixel centres, clamped
/// (`(x0, x1, weight of x1)`), in f32 as the shaders compute them.
fn bilinear_tap(d: usize, i: usize, o: usize) -> (usize, usize, f32) {
    let s = ((d as f32 + 0.5) * i as f32 / o as f32 - 0.5).clamp(0.0, (i - 1) as f32);
    let x0 = s.floor();
    (x0 as usize, (x0 as usize + 1).min(i - 1), s - x0)
}

/// The model input of a `matting` package for `img`: resized to the model size (bilinear, half-pixel centres,
/// no antialias), RGB in [0, 1], then `(v - mean) / std`.
pub fn matte_input(io: &serde_json::Value, img: &Rgb8) -> Result<Tensor> {
    let (mw, mh) = matte_size(io, img.w, img.h)?;
    let triple = |k: &str, d: f32| -> [f32; 3] {
        let a = &io[k];
        [0, 1, 2].map(|i| a[i].as_f64().map_or(d, |v| v as f32))
    };
    let (mean, std) = (triple("mean", 0.0), triple("std", 1.0));
    let mut t = Tensor::zeros(3, mh, mw);
    let px = |x: usize, y: usize, c: usize| img.data[(y * img.w + x) * 3 + c] as f32 / 255.0;
    for y in 0..mh {
        let (y0, y1, fy) = bilinear_tap(y, img.h, mh);
        for x in 0..mw {
            let (x0, x1, fx) = bilinear_tap(x, img.w, mw);
            for c in 0..3 {
                let top = px(x0, y0, c) + (px(x1, y0, c) - px(x0, y0, c)) * fx;
                let bot = px(x0, y1, c) + (px(x1, y1, c) - px(x0, y1, c)) * fx;
                t.data[(c * mh + y) * mw + x] = (top + (bot - top) * fy - mean[c]) * (1.0 / std[c]);
            }
        }
    }
    Ok(t)
}

/// The alpha matte of `img` at the model size with the CPU reference executor, following the `matting` io.json
/// of the package: [`matte_input`], run, then `matte.type` (`alpha` clamped, `sigmoid`, or `softmax` over the
/// channels at `matte.channel`). Returns `(mw, mh, alpha)`.
pub fn matte(model: &Reference, img: &Rgb8) -> Result<(usize, usize, Vec<f32>)> {
    let io = &model.io;
    if io["kind"] != "matting" {
        return fail("io.json is not a matting description");
    }
    let in_name = io["inputs"]["image"].as_str().ok_or_else(|| crate::Error("io.json has no inputs.image".into()))?.to_string();
    let out_name = io["output"].as_str().ok_or_else(|| crate::Error("io.json has no output".into()))?;
    let x = matte_input(io, img)?;
    let (mw, mh) = (x.w, x.h);
    let mut inputs = HashMap::new();
    inputs.insert(in_name, x);
    let mut outputs = model.run(inputs)?;
    let Some(out) = outputs.remove(out_name) else { return fail(format!("no output \"{out_name}\"")) };
    if out.w != mw || out.h != mh {
        return fail(format!("output is {}x{}, the matte must be the model size {mw}x{mh}", out.w, out.h));
    }
    let ch = io["matte"]["channel"].as_u64().unwrap_or(0) as usize;
    if ch >= out.c {
        return fail(format!("matte channel {ch} of an output of {} channels", out.c));
    }
    let plane = mw * mh;
    let at = |k: usize, i: usize| out.data[k * plane + i];
    let alpha = (0..plane)
        .map(|i| {
            let a = match io["matte"]["type"].as_str() {
                Some("sigmoid") => 1.0 / (1.0 + (-at(ch, i)).exp()),
                Some("softmax") => {
                    let m = (0..out.c).map(|k| at(k, i)).fold(f32::NEG_INFINITY, f32::max);
                    let s: f32 = (0..out.c).map(|k| (at(k, i) - m).exp()).sum();
                    (at(ch, i) - m).exp() / s
                }
                _ => at(ch, i),
            };
            a.clamp(0.0, 1.0)
        })
        .collect();
    Ok((mw, mh, alpha))
}

/// A matte resized to `dw x dh` the way `FrameMatte::draw` does: bilinear, half-pixel centres, clamped.
pub fn resize_matte(alpha: &[f32], mw: usize, mh: usize, dw: usize, dh: usize) -> Vec<f32> {
    let mut out = vec![0.0; dw * dh];
    for y in 0..dh {
        let (y0, y1, fy) = bilinear_tap(y, mh, dh);
        for x in 0..dw {
            let (x0, x1, fx) = bilinear_tap(x, mw, dw);
            let a = |x: usize, y: usize| alpha[y * mw + x];
            let top = a(x0, y0) + (a(x1, y0) - a(x0, y0)) * fx;
            let bot = a(x0, y1) + (a(x1, y1) - a(x0, y1)) * fx;
            out[y * dw + x] = top + (bot - top) * fy;
        }
    }
    out
}

/// Intersection over union of two mattes thresholded at 0.5 (1 when both are empty).
pub fn matte_iou(a: &[f32], b: &[f32]) -> f64 {
    let (mut i, mut u) = (0usize, 0usize);
    for (x, y) in a.iter().zip(b) {
        let (p, q) = (*x >= 0.5, *y >= 0.5);
        i += (p && q) as usize;
        u += (p || q) as usize;
    }
    if u == 0 {
        1.0
    } else {
        i as f64 / u as f64
    }
}

#[cfg(test)]
mod matte_tests {
    use super::*;

    #[test]
    fn matte_sizes_and_taps() {
        let io = serde_json::json!({"size": {"mode": "short_side", "short_side": 512, "multiple": 32}});
        assert_eq!(matte_size(&io, 1920, 1080).unwrap(), (896, 512));
        assert_eq!(matte_size(&io, 640, 480).unwrap(), (672, 512));
        let fixed = serde_json::json!({"size": {"mode": "fixed", "height": 144, "width": 256}});
        assert_eq!(matte_size(&fixed, 7, 9).unwrap(), (256, 144));
        // halving: output pixel 0 is the mean of input 0 and 1; same size is a copy
        assert_eq!(bilinear_tap(0, 4, 2), (0, 1, 0.5));
        assert_eq!(bilinear_tap(3, 4, 4), (3, 3, 0.0));
        assert_eq!(resize_matte(&[0.0, 1.0], 2, 1, 4, 1), [0.0, 0.25, 0.75, 1.0]);
        assert_eq!(matte_iou(&[0.9, 0.1, 0.6], &[0.8, 0.7, 0.2]), 1.0 / 3.0);
    }
}
