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
    if f0.w != f1.w || f0.h != f1.h {
        return fail("frames differ in size");
    }
    let io = &model.io;
    if io["kind"] != "frame_interp" {
        return fail("io.json is not a frame_interp description");
    }
    let name = |k: &str| io["inputs"][k].as_str().map(String::from).ok_or_else(|| crate::Error(format!("io.json has no inputs.{k}")));
    let out_name = io["output"].as_str().ok_or_else(|| crate::Error("io.json has no output".into()))?;
    let mult = io["pad_multiple"].as_u64().unwrap_or(1).max(1) as usize;
    let clamp = [io["output_clamp"][0].as_f64().unwrap_or(0.0) as f32, io["output_clamp"][1].as_f64().unwrap_or(1.0) as f32];
    let (wp, hp) = (f0.w.div_ceil(mult) * mult, f0.h.div_ceil(mult) * mult);

    let mut inputs = HashMap::new();
    inputs.insert(name("frame0")?, to_planes(f0, wp, hp));
    inputs.insert(name("frame1")?, to_planes(f1, wp, hp));
    inputs.insert(name("timestep")?, Tensor::filled(1, hp, wp, t));
    let mut outputs = model.run(inputs)?;
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
