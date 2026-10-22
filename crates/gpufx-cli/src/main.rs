//! `gpufx` command line: inspect, pack and test effect packages without FFmpeg.

use std::path::Path;
use std::process::ExitCode;

use gpufx_core::manifest::SizeRule;
use gpufx_core::{Backend, Effect, EffectGraph, FrameInfo, GpuContext, Image, ImageMut, Package, StreamInfo};

const USAGE: &str = "\
usage:
  gpufx info  <package>
  gpufx check <package> [--backend ...]   compile every shader and report errors
  gpufx pack [--precompile] <dir> <out.zip>
             --precompile adds D3D12 shaders, used when GPUFX_TRUST_PRECOMPILED=1
  gpufx run  <graph> -i <in.png> [-i <in2.png>...] -o <out.png>
             [--backend auto|vulkan|dx12|metal] [--time seconds]
             the graph is written as for the FFmpeg filter, with one output: a package
             with parameters, a chain or a labelled graph:
             gpufx run 'vignette.zip=strength=0.3:color=#ff8800' -i in.png -o out.png
             gpufx run 'grayscale.zip|vignette.zip' -i in.png -o out.png
             gpufx run '[0][1]crossfade.zip=progress=0.5' -i a.png -i b.png -o out.png
  gpufx ai-interp --model <rife.zip> --frame0 <a.png> --frame1 <b.png> [--t 0.5] -o <out.png>
             [--backend ...] [--bench N] [--profile]
             frame interpolation with a gpufx-nn package (see docs/NN_MODEL_FORMAT.md);
             --bench times N more frames on the GPU, --profile prints the time per kind of op";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("info") if args.len() == 2 => info(&args[1]),
        Some("check") if args.len() >= 2 => check(&args[1], &args[2..]),
        Some("pack") if args.len() == 3 => pack(Path::new(&args[1]), Path::new(&args[2]), false),
        Some("pack") if args.len() == 4 && args[1] == "--precompile" => pack(Path::new(&args[2]), Path::new(&args[3]), true),
        Some("run") if args.len() >= 2 => run(&args[1], &args[2..]),
        Some("ai-interp") => ai_interp(&args[1..]),
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

fn info(path: &str) -> Result<(), String> {
    let pkg = Package::open(path).map_err(|e| e.to_string())?;
    let m = &pkg.manifest;
    println!("{} ({}) {}", m.name, m.id, m.version);
    if !m.description.is_empty() {
        println!("  {}", m.description);
    }
    println!("used for: {}", m.used_for.join(", "));
    println!("inputs:");
    for i in &m.inputs {
        println!("  {} {}", i.name, i.description);
        if !i.formats.is_empty() {
            println!("    formats: {}", i.formats.join(", "));
        }
        for (what, rule) in [("width", &i.width), ("height", &i.height)] {
            if let Some(r) = rule {
                println!("    {what}: {}", describe(r));
            }
        }
        if i.same_size {
            println!("    same size as the first input");
        }
    }
    println!("outputs:");
    for o in &m.outputs {
        println!("  {}: formats {}", o.name, o.formats.join(", "));
    }
    println!("params:");
    for p in &m.params {
        let default = p.default.as_ref().map(|d| d.to_string()).unwrap_or_else(|| "0".into());
        let range = match (p.min, p.max) {
            (Some(a), Some(b)) => format!(" [{a}..{b}]"),
            _ => String::new(),
        };
        println!("  {} : {:?} = {default}{range}  {}", p.name, p.kind, p.description);
        if !p.enum_values().is_empty() {
            let values: Vec<String> = p.enum_values().iter().map(|(n, x)| format!("{n}={x}")).collect();
            println!("      values: {}", values.join(", "));
        }
    }
    println!("groups (the first matching the device runs):");
    for (g, group) in m.groups.iter().enumerate() {
        println!("  {}: requires {}, {} pass(es)", m.group_label(g), group.requires.describe(), group.passes.len());
    }
    Ok(())
}

fn describe(r: &SizeRule) -> String {
    let mut parts = Vec::new();
    if let Some(v) = r.min {
        parts.push(format!(">= {v}"));
    }
    if let Some(v) = r.max {
        parts.push(format!("<= {v}"));
    }
    if let Some(v) = r.multiple_of {
        parts.push(format!("multiple of {v}"));
    }
    parts.join(", ")
}

/// FFmpeg name of the pixel format a decoded image has, for the manifest input rules.
fn pix_fmt(img: &image::DynamicImage) -> Option<&'static str> {
    use image::ColorType::*;
    Some(match img.color() {
        L8 => "gray",
        La8 => "ya8",
        Rgb8 => "rgb24",
        Rgba8 => "rgba",
        L16 => "gray16be",
        La16 => "ya16be",
        Rgb16 => "rgb48be",
        Rgba16 => "rgba64be",
        _ => return None,
    })
}

fn check(path: &str, args: &[String]) -> Result<(), String> {
    let backend = match args {
        [] => Backend::Auto,
        [flag, b] if flag == "--backend" => b.parse().map_err(|e: gpufx_core::Error| e.to_string())?,
        _ => return Err(USAGE.to_string()),
    };
    let pkg = Package::open(path).map_err(|e| e.to_string())?;
    let ctx = GpuContext::new(backend).map_err(|e| e.to_string())?;
    let device = ctx.description();
    // With pass groups, the passes of the group chosen for the device.
    let passes = Effect::new(ctx, pkg).map_err(|e| e.to_string())?.package().manifest.passes.len();
    println!("ok: {passes} pass(es) compiled on {device}");
    Ok(())
}

fn pack(dir: &Path, out: &Path, precompile: bool) -> Result<(), String> {
    let compiled = Package::pack(dir, out, precompile).map_err(|e| e.to_string())?;
    if precompile {
        println!("wrote {} with {compiled} D3D12 shader(s)", out.display());
    } else {
        println!("wrote {}", out.display());
    }
    Ok(())
}

fn run(text: &str, args: &[String]) -> Result<(), String> {
    let mut inputs = Vec::new();
    let mut output = None;
    let mut backend = Backend::Auto;
    let mut time = 0.0;
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let mut value = || it.next().cloned().ok_or_else(|| format!("{flag} needs a value\n{USAGE}"));
        match flag.as_str() {
            "-i" => inputs.push(value()?),
            "-o" => output = Some(value()?),
            "--backend" => backend = value()?.parse().map_err(|e: gpufx_core::Error| e.to_string())?,
            "--time" => time = value()?.parse().map_err(|_| "--time needs a number".to_string())?,
            _ => return Err(format!("unknown argument {flag}\n{USAGE}")),
        }
    }
    let output = output.ok_or_else(|| format!("missing -o\n{USAGE}"))?;

    let ctx = GpuContext::new(backend).map_err(|e| e.to_string())?;
    eprintln!("device: {}", ctx.description());
    let mut graph = EffectGraph::parse(text, |path| {
        let pkg = Package::open(path)?;
        let name = Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| path.to_string());
        let label = name.strip_suffix(".zip").or_else(|| name.strip_suffix(".ZIP")).unwrap_or(&name).to_string();
        Ok((label, Effect::new(ctx.clone(), pkg)?))
    })
    .map_err(|e| e.to_string())?;
    if graph.output_count() != 1 {
        return Err(format!("the graph has {} outputs ({}); run writes one", graph.output_count(), graph.output_names().join(", ")));
    }
    // Constants are set by parse; expression values are set here.
    let options: Vec<(usize, String, String)> = graph
        .inline_options()
        .iter()
        .enumerate()
        .flat_map(|(k, list)| list.iter().map(move |(key, value)| (k, key.clone(), value.clone())))
        .collect();
    for (k, key, value) in options {
        if key == "enable" || key == "bypass" {
            return Err(format!("{key}= switches effects over time in the FFmpeg filter; run renders one frame"));
        }
        graph.set_param_str(&format!("{k}.{key}"), &value).map_err(|e| e.to_string())?;
    }
    let decoded: Vec<image::DynamicImage> =
        inputs.iter().map(|p| image::open(p).map_err(|e| format!("{p}: {e}"))).collect::<Result<_, _>>()?;
    let streams: Vec<StreamInfo> =
        decoded.iter().map(|i| StreamInfo { format: pix_fmt(i), width: i.width(), height: i.height() }).collect();
    graph.check_inputs(&streams).map_err(|e| e.to_string())?;
    let images: Vec<image::RgbaImage> = decoded.iter().map(|i| i.to_rgba8()).collect();
    let views: Vec<Image> =
        images.iter().map(|i| Image { data: i.as_raw(), width: i.width(), height: i.height(), stride: i.width() * 4 }).collect();
    if views.is_empty() {
        return Err("need at least one -i".into());
    }
    let pads: Vec<(u32, u32)> = views.iter().map(|v| (v.width, v.height)).collect();
    let (w, h) = graph.output_size(0, &pads).map_err(|e| e.to_string())?;
    let mut out = vec![0u8; (w * h * 4) as usize];
    let start = std::time::Instant::now();
    graph
        .process(&views, vec![ImageMut { data: &mut out, width: w, height: h, stride: w * 4 }], &FrameInfo::new(time, 0))
        .map_err(|e| e.to_string())?;
    eprintln!("processed {w}x{h} in {:.1} ms", start.elapsed().as_secs_f64() * 1e3);
    image::RgbaImage::from_raw(w, h, out).expect("sized above").save(&output).map_err(|e| e.to_string())?;
    Ok(())
}

fn ai_interp(args: &[String]) -> Result<(), String> {
    let (mut model, mut frame0, mut frame1, mut output) = (None, None, None, None);
    let mut backend = Backend::Auto;
    let (mut t, mut bench, mut profile) = (0.5f32, 0u32, false);
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let mut value = || it.next().cloned().ok_or_else(|| format!("{flag} needs a value\n{USAGE}"));
        match flag.as_str() {
            "--model" => model = Some(value()?),
            "--frame0" => frame0 = Some(value()?),
            "--frame1" => frame1 = Some(value()?),
            "-o" => output = Some(value()?),
            "--t" => t = value()?.parse().map_err(|_| "--t needs a number".to_string())?,
            "--bench" => bench = value()?.parse().map_err(|_| "--bench needs a count".to_string())?,
            "--profile" => profile = true,
            "--backend" => backend = value()?.parse().map_err(|e: gpufx_core::Error| e.to_string())?,
            _ => return Err(format!("unknown argument {flag}\n{USAGE}")),
        }
    }
    let missing = |what: &str| format!("missing {what}\n{USAGE}");
    let (model, frame0, frame1, output) = (
        model.ok_or_else(|| missing("--model"))?,
        frame0.ok_or_else(|| missing("--frame0"))?,
        frame1.ok_or_else(|| missing("--frame1"))?,
        output.ok_or_else(|| missing("-o"))?,
    );
    if !(t > 0.0 && t < 1.0) {
        return Err("--t must be in (0, 1)".into());
    }
    let ctx = GpuContext::new(backend).map_err(|e| e.to_string())?;
    eprintln!("device: {}", ctx.description());
    let start = std::time::Instant::now();
    let nn = gpufx_core::nn::NnModel::load(ctx, &model).map_err(|e| e.to_string())?;
    eprintln!(
        "loaded {} ({:.1} MB of weights) in {:.0} ms",
        nn.name(),
        nn.weight_bytes() as f64 / 1e6,
        start.elapsed().as_secs_f64() * 1e3
    );
    let mut interp = gpufx_core::nn::FrameInterp::new(std::sync::Arc::new(nn)).map_err(|e| e.to_string())?;
    let load = |p: &str| image::open(p).map(|i| i.to_rgba8()).map_err(|e| format!("{p}: {e}"));
    let (a, b) = (load(&frame0)?, load(&frame1)?);
    fn view(i: &image::RgbaImage) -> Image<'_> {
        Image { data: i.as_raw(), width: i.width(), height: i.height(), stride: i.width() * 4 }
    }
    let start = std::time::Instant::now();
    let out = interp.interpolate(&view(&a), &view(&b), t).map_err(|e| e.to_string())?;
    let first = start.elapsed().as_secs_f64() * 1e3;
    let plan = interp.plan().expect("a frame was given");
    eprintln!(
        "{}x{}: first frame {first:.1} ms (plan, upload, readback), {} dispatches, {} tensor buffers, {:.1} MB",
        a.width(),
        a.height(),
        plan.dispatch_count(),
        plan.buffer_count(),
        plan.tensor_bytes() as f64 / 1e6
    );
    image::RgbaImage::from_raw(a.width(), a.height(), out).expect("sized by interpolate").save(&output).map_err(|e| e.to_string())?;
    if bench > 0 {
        interp.bench(2, t).map_err(|e| e.to_string())?;
        let ms = interp.bench(bench, t).map_err(|e| e.to_string())?;
        eprintln!("bench: {ms:.2} ms/frame over {bench} frames ({:.1} fps)", 1e3 / ms);
    }
    if profile {
        let prof = interp.plan().expect("a frame was given").profile(10).map_err(|e| e.to_string())?;
        let total: f64 = prof.by_kind.iter().map(|r| r.1).sum();
        eprintln!("profile (each dispatch alone, 10 runs):");
        for (op, ms, n) in &prof.by_kind {
            eprintln!("  {op:<14} {ms:8.2} ms  {:5.1}%  {n} dispatches", 100.0 * ms / total);
        }
        eprintln!("  {:<14} {total:8.2} ms", "total");
        let mut slow = prof.dispatches.clone();
        slow.sort_by(|a, b| b.1.total_cmp(&a.1));
        eprintln!("slowest dispatches:");
        for (what, ms) in slow.iter().take(std::env::var("GPUFX_NN_TOP").ok().and_then(|v| v.parse().ok()).unwrap_or(12)) {
            eprintln!("  {ms:7.2} ms  {what}");
        }
    }
    Ok(())
}
