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
