//! `gpufx-nnconv`: converts neural network models to gpufx-nn packages.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use gpufx_nnconv::reference::Reference;
use gpufx_nnconv::{convert_ncnn, frames, Package};

const USAGE: &str = "\
usage:
  gpufx-nnconv ncnn --param <model.param> --bin <model.bin> --io <io.json>
                    [--license <file>] [--name <name>] -o <out.zip|out_dir>
             converts an ncnn model to a gpufx-nn package: model.json, weights.bin,
             io.json (copied as given) and LICENSE. -o ending in .zip writes a zip,
             anything else a directory. The name defaults to the output file stem.
  gpufx-nnconv run-ref --model <pkg.zip|dir> --frame0 <a.png> --frame1 <b.png> [--t 0.5] -o <out.png>
             dev tool: interpolates with the CPU reference executor (slow, golden semantics).
  gpufx-nnconv psnr <a.png> <b.png>
             dev tool: prints the PSNR in dB between two images.";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("ncnn") => ncnn(&args[1..]),
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
    let (mut param, mut bin, mut io, mut license, mut name, mut out) = (None, None, None, None, None, None);
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let slot = match flag.as_str() {
            "--param" => &mut param,
            "--bin" => &mut bin,
            "--io" => &mut io,
            "--license" => &mut license,
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
    let package = Package::new(&converted, read(&io)?, license).map_err(|e| e.to_string())?;
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

fn run_ref(args: &[String]) -> Result<(), String> {
    let (mut model, mut f0, mut f1, mut t, mut out) = (None, None, None, None, None);
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let slot = match flag.as_str() {
            "--model" => &mut model,
            "--frame0" => &mut f0,
            "--frame1" => &mut f1,
            "--t" => &mut t,
            "-o" => &mut out,
            _ => return Err(USAGE.to_string()),
        };
        *slot = Some(it.next().ok_or_else(|| format!("{flag} needs a value"))?.clone());
    }
    let (Some(model), Some(f0), Some(f1), Some(out)) = (model, f0, f1, out) else { return Err(USAGE.to_string()) };
    let t: f32 = t.as_deref().unwrap_or("0.5").parse().map_err(|e| format!("--t: {e}"))?;
    let reference = Reference::load(Path::new(&model)).map_err(|e| format!("{model}: {e}"))?;
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
