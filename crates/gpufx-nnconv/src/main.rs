//! `gpufx-nnconv`: converts neural network models to gpufx-nn packages.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use gpufx_nnconv::bundle::{Bundle, VariantFiles};
use gpufx_nnconv::reference::Reference;
use gpufx_nnconv::{convert_ncnn, frames, Package};

const USAGE: &str = "\
usage:
  gpufx-nnconv ncnn --param <model.param> --bin <model.bin> --io <io.json>
                    [--license <file>] [--readme <file>] [--name <name>]
                    -o <out.zip|out_dir>
             converts an ncnn model to a gpufx-nn package: model.json, weights.bin,
             io.json (copied as given), README.md (--readme, else a minimal generated
             one) and LICENSE. -o ending in .zip writes a zip,
             anything else a directory. The name defaults to the output file stem.
  gpufx-nnconv bundle --variant <dir>=<pkg.zip|dir> [--variant ...]
                      [--license <file>] [--readme <file>] [--name <name>]
                      -o <out.zip|out_dir>
             bundles several scale variants of one model family into one package:
             package.json, LICENSE, README.md and one directory per variant. Each
             variant's scale and kind come from its io.json; all must share a kind and
             have distinct scales.
  gpufx-nnconv run-ref --model <pkg.zip|dir> --frame0 <a.png> --frame1 <b.png> [--t 0.5] -o <out.png>
             dev tool: interpolates with the CPU reference executor (slow, golden semantics).
  gpufx-nnconv run-ref --model <pkg.zip|dir> --input <in.png> [--scale N] -o <out.png>
             dev tool: upscales a super_resolution package (--scale picks a bundle variant).
  gpufx-nnconv psnr <a.png> <b.png>
             dev tool: prints the PSNR in dB between two images.";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("ncnn") => ncnn(&args[1..]),
        Some("bundle") => bundle(&args[1..]),
        Some("run-ref") => run_ref(&args[1..]),
        Some("psnr") => psnr(&args[1..]),
        _ => Err(USAGE.to_string()),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

fn ncnn(args: &[String]) -> Result<(), String> {
    let (mut param, mut bin, mut io, mut license, mut readme, mut name, mut out) = (None, None, None, None, None, None, None);
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let slot = match flag.as_str() {
            "--param" => &mut param,
            "--bin" => &mut bin,
            "--io" => &mut io,
            "--license" => &mut license,
            "--readme" => &mut readme,
            "--name" => &mut name,
            "-o" => &mut out,
            _ => return Err(USAGE.to_string()),
        };
        *slot = Some(it.next().ok_or_else(|| format!("{flag} needs a value"))?.clone());
    }
    let (Some(param), Some(bin), Some(io), Some(out)) = (param, bin, io, out) else { return Err(USAGE.to_string()) };
    let out = PathBuf::from(out);
    let name = name.unwrap_or_else(|| out.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default());

    let read = |p: &str| std::fs::read(p).map_err(|e| format!("{p}: {e}"));
    let param_text = String::from_utf8(read(&param)?).map_err(|e| format!("{param}: {e}"))?;
    let converted = convert_ncnn(&param_text, &read(&bin)?, &name).map_err(|e| format!("{param}: {e}"))?;
    let license = license.as_deref().map(read).transpose()?;
    let readme = readme.as_deref().map(read).transpose()?;
    let package = Package::new(&converted, read(&io)?, license, readme).map_err(|e| e.to_string())?;
    package.write(&out).map_err(|e| format!("{}: {e}", out.display()))?;
    summary(&converted, &out);
    Ok(())
}

fn summary(c: &gpufx_nnconv::Converted, out: &Path) {
    let mut counts: Vec<(&str, usize)> = Vec::new();
    for op in &c.model.ops {
        match counts.iter_mut().find(|(k, _)| *k == op.op) {
            Some((_, n)) => *n += 1,
            None => counts.push((op.op, 1)),
        }
    }
    let ops: Vec<String> = counts.iter().map(|(k, n)| format!("{k} {n}")).collect();
    println!("{}: {} ops ({}), weights {} bytes", out.display(), c.model.ops.len(), ops.join(", "), c.weights.len());
}

fn bundle(args: &[String]) -> Result<(), String> {
    let (mut variants, mut license, mut readme, mut name, mut out): (Vec<String>, _, _, _, _) = (Vec::new(), None, None, None, None);
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--variant" => variants.push(it.next().ok_or_else(|| format!("{flag} needs a value"))?.clone()),
            "--license" => license = Some(it.next().ok_or("--license needs a value")?.clone()),
            "--readme" => readme = Some(it.next().ok_or("--readme needs a value")?.clone()),
            "--name" => name = Some(it.next().ok_or("--name needs a value")?.clone()),
            "-o" => out = Some(it.next().ok_or("-o needs a value")?.clone()),
            _ => return Err(USAGE.to_string()),
        }
    }
    let Some(out) = out else { return Err(USAGE.to_string()) };
    if variants.is_empty() {
        return Err(USAGE.to_string());
    }
    let out = PathBuf::from(out);
    let name = name.unwrap_or_else(|| out.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default());
    let read = |p: &str| std::fs::read(p).map_err(|e| format!("{p}: {e}"));

    let mut inputs = Vec::new();
    for v in &variants {
        let (dir, src) = v.split_once('=').ok_or_else(|| format!("--variant must be <dir>=<pkg>, found \"{v}\""))?;
        let files = VariantFiles::load(Path::new(src)).map_err(|e| format!("{src}: {e}"))?;
        inputs.push((dir.to_string(), files));
    }
    let license = license.as_deref().map(read).transpose()?;
    let readme = readme.as_deref().map(read).transpose()?;
    let bundle = Bundle::new(&name, inputs, license, readme).map_err(|e| e.to_string())?;
    bundle.write(&out).map_err(|e| format!("{}: {e}", out.display()))?;
    println!("{}: bundle with {} variant(s)", out.display(), variants.len());
    Ok(())
}

fn run_ref(args: &[String]) -> Result<(), String> {
    let (mut model, mut f0, mut f1, mut t, mut input, mut scale, mut out) = (None, None, None, None, None, None, None);
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let slot = match flag.as_str() {
            "--model" => &mut model,
            "--frame0" => &mut f0,
            "--frame1" => &mut f1,
            "--t" => &mut t,
            "--input" => &mut input,
            "--scale" => &mut scale,
            "-o" => &mut out,
            _ => return Err(USAGE.to_string()),
        };
        *slot = Some(it.next().ok_or_else(|| format!("{flag} needs a value"))?.clone());
    }
    let (Some(model), Some(out)) = (model, out) else { return Err(USAGE.to_string()) };
    let scale: Option<u64> = scale.as_deref().map(|s| s.parse()).transpose().map_err(|e| format!("--scale: {e}"))?;

    if let Some(input) = input {
        let reference = Reference::load_variant(Path::new(&model), scale).map_err(|e| format!("{model}: {e}"))?;
        let img = frames::load_png(Path::new(&input)).map_err(|e| e.to_string())?;
        let start = std::time::Instant::now();
        let res = frames::upscale(&reference, &img).map_err(|e| e.to_string())?;
        println!("{}x{} -> {}x{}: {:.2}s", img.w, img.h, res.w, res.h, start.elapsed().as_secs_f64());
        return frames::save_png(Path::new(&out), &res).map_err(|e| e.to_string());
    }

    let (Some(f0), Some(f1)) = (f0, f1) else { return Err(USAGE.to_string()) };
    let t: f32 = t.as_deref().unwrap_or("0.5").parse().map_err(|e| format!("--t: {e}"))?;
    let reference = Reference::load_variant(Path::new(&model), scale).map_err(|e| format!("{model}: {e}"))?;
    let a = frames::load_png(Path::new(&f0)).map_err(|e| e.to_string())?;
    let b = frames::load_png(Path::new(&f1)).map_err(|e| e.to_string())?;
    let start = std::time::Instant::now();
    let res = frames::interpolate(&reference, &a, &b, t).map_err(|e| e.to_string())?;
    println!("{}x{} t={t}: {:.2}s", res.w, res.h, start.elapsed().as_secs_f64());
    frames::save_png(Path::new(&out), &res).map_err(|e| e.to_string())
}

fn psnr(args: &[String]) -> Result<(), String> {
    let [a, b] = args else { return Err(USAGE.to_string()) };
    let a = frames::load_png(Path::new(a)).map_err(|e| e.to_string())?;
    let b = frames::load_png(Path::new(b)).map_err(|e| e.to_string())?;
    println!("{:.3} dB", frames::psnr(&a, &b).map_err(|e| e.to_string())?);
    Ok(())
}
