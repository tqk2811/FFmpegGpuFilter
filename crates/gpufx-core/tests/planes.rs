//! Effects with a `pixel_layout` other than `rgba` in graphs: the layout converts the core
//! inserts between sources and effect inputs of other layouts (none between effects of
//! the same layout), pooled plane textures, odd sizes, outputs switched off and textures
//! between passes, and frames loaded and written straight as planes. Tests that need a device are skipped
//! when none can be created.

mod common;

use std::path::PathBuf;
use std::sync::Arc;

use gpufx_core::{
    ColorInfo, Effect, EffectGraph, Error, Frame, FrameInfo, FrameMut, GpuContext, GpuFrame, Image, ImageMut, Matrix, Package, PixelFormat,
    Range,
};

fn gpu() -> Option<Arc<GpuContext>> {
    static CTX: std::sync::OnceLock<Option<Arc<GpuContext>>> = std::sync::OnceLock::new();
    CTX.get_or_init(|| match GpuContext::new(common::backend()) {
        Ok(ctx) => Some(ctx),
        Err(e) => {
            eprintln!("skipping: {e}");
            None
        }
    })
    .clone()
}

fn wgsl(body: &str) -> String {
    format!("@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) {{\n    if (!gpufx_in_bounds(id)) {{ return; }}\n    let p = id.xy;\n    {body}\n}}\n")
}

/// Copies the planes of input `src` into output k (`K` in the body).
fn copy_planes(input: &str, k: &str, alpha: bool) -> String {
    let a = if alpha { format!("\n    gpufx_write{k}_a(p, textureLoad(in_{input}_a, p, 0).r);") } else { String::new() };
    format!(
        "gpufx_write{k}_y(p, textureLoad(in_{input}_y, p, 0).r);{a}\n    let s = gpufx_chroma_scale{k}();\n    \
         if (all(p % s == vec2u(0u))) {{ gpufx_write{k}_uv(p / s, textureLoad(in_{input}_uv, p / s, 0).rg); }}"
    )
}

/// Test packages written to a temporary directory, removed when dropped.
struct Packages(PathBuf);

impl Packages {
    fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let pkgs = Packages(std::env::temp_dir().join(format!("gpufx-planes-{}-{n}", std::process::id())));
        std::fs::remove_dir_all(&pkgs.0).ok();
        // Copies in one layout: yuv420, yuv444, yuva420.
        for (name, layout, alpha) in [("id420", "yuv420", false), ("id444", "yuv444", false), ("ida420", "yuva420", true)] {
            pkgs.add(
                name,
                &format!(
                    r#"{{"id":"t.{name}","name":"{name}","api":1,"used_for":["gpufx"],"inputs":[{{"name":"src","pixel_layout":"{layout}"}}],"outputs":[{{"name":"out","pixel_layout":"{layout}"}}],"groups":[{{"passes":[{{"shader":"a.wgsl"}}]}}]}}"#
                ),
                &[("a.wgsl", wgsl(&copy_planes("src", "", alpha)))],
            );
        }
        // A plain RGBA copy.
        pkgs.add(
            "idrgba",
            r#"{"id":"t.idrgba","name":"idrgba","api":1,"used_for":["gpufx"],"groups":[{"passes":[{"shader":"a.wgsl"}]}]}"#,
            &[("a.wgsl", wgsl("gpufx_write(id, textureLoad(src, vec2i(p), 0));"))],
        );
        // The luma of a yuv420 input as a `y` output.
        pkgs.add(
            "luma",
            r#"{"id":"t.luma","name":"luma","api":1,"used_for":["gpufx"],"inputs":[{"name":"src","pixel_layout":"yuv420"}],"outputs":[{"name":"out","pixel_layout":"y"}],"groups":[{"passes":[{"shader":"a.wgsl"}]}]}"#,
            &[("a.wgsl", wgsl("gpufx_write_y(p, textureLoad(in_src_y, p, 0).r);"))],
        );
        // Two passes through a yuv420 texture between them.
        pkgs.add(
            "twopass",
            r#"{"id":"t.twopass","name":"twopass","api":1,"used_for":["gpufx"],"inputs":[{"name":"src","pixel_layout":"yuv420"}],"outputs":[{"name":"out","pixel_layout":"yuv420"}],"intermediates":[{"name":"tmp","pixel_layout":"yuv420"}],"groups":[{"passes":[{"shader":"a.wgsl","inputs":["src"],"outputs":["tmp"]},{"shader":"b.wgsl","inputs":["tmp"],"outputs":["out"]}]}]}"#,
            &[("a.wgsl", wgsl(&copy_planes("src", "", false))), ("b.wgsl", wgsl(&copy_planes("tmp", "", false)))],
        );
        // A yuv420 copy and an optional `y` matte; off, the matte writes its stand-in.
        pkgs.add(
            "keyed",
            r#"{"id":"t.keyed","name":"keyed","api":1,"used_for":["gpufx"],"inputs":[{"name":"src","pixel_layout":"yuv420"}],"outputs":[{"name":"color","pixel_layout":"yuv420"},{"name":"matte","pixel_layout":"y","optional":true}],"groups":[{"passes":[{"shader":"a.wgsl","outputs":["color","matte"]}]}]}"#,
            &[("a.wgsl", wgsl(&format!("{}\n    gpufx_write1_y(p, 1.0);", copy_planes("src", "", false))))],
        );
        // Two yuv420 inputs, the first one copied.
        pkgs.add(
            "pick420",
            r#"{"id":"t.pick420","name":"pick420","api":1,"used_for":["gpufx"],"inputs":[{"name":"a","pixel_layout":"yuv420"},{"name":"b","pixel_layout":"yuv420"}],"outputs":[{"name":"out","pixel_layout":"yuv420"}],"groups":[{"passes":[{"shader":"a.wgsl"}]}]}"#,
            &[("a.wgsl", wgsl(&copy_planes("a", "", false)))],
        );
        pkgs
    }

    fn add(&self, name: &str, manifest: &str, files: &[(&str, String)]) {
        let dir = self.0.join(name);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("manifest.json"), manifest).unwrap();
        for (f, text) in files {
            std::fs::write(dir.join(f), text).unwrap();
        }
    }

    fn graph(&self, ctx: &Arc<GpuContext>, text: &str) -> Result<EffectGraph, Error> {
        EffectGraph::parse(text, |path| {
            let name = path.trim_end_matches(".zip");
            Ok((name.to_string(), Effect::new(ctx.clone(), Package::open(self.0.join(name))?)?))
        })
    }
}

impl Drop for Packages {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).ok();
    }
}

/// An image whose colour is constant over each 2x2 block (so 4:2:0 keeps it), alpha 255.
fn blocks(w: u32, h: u32) -> Vec<u8> {
    (0..w * h)
        .flat_map(|i| {
            let (x, y) = (i % w / 2, i / w / 2);
            [(40 + x * 50 % 180) as u8, (60 + y * 70 % 170) as u8, (200 - (x + y) * 30 % 150) as u8, 255]
        })
        .collect()
}

/// Any colour per pixel, alpha varying.
fn gradient(w: u32, h: u32) -> Vec<u8> {
    (0..w * h)
        .flat_map(|i| [(i % w * 23 + 20) as u8, (i / w * 31 + 10) as u8, (i * 7 % 200 + 30) as u8, (100 + i * 13 % 150) as u8])
        .collect()
}

fn run(g: &mut EffectGraph, input: &[u8], w: u32, h: u32) -> Vec<Vec<u8>> {
    let mut outs = vec![vec![0u8; (w * h * 4) as usize]; g.output_count()];
    let targets = outs.iter_mut().map(|o| ImageMut { data: o, width: w, height: h, stride: w * 4 }).collect();
    g.process(&[Image { data: input, width: w, height: h, stride: w * 4 }], targets, &FrameInfo::new(0.0, 0)).unwrap();
    outs
}

/// Fails unless every channel of `got` is within `tol` of `want`, or with alpha `alpha` when given.
fn assert_near(got: &[u8], want: &[u8], tol: i32, alpha: Option<u8>, what: &str) {
    assert_eq!(got.len(), want.len(), "{what}");
    for (i, (g, w)) in got.iter().zip(want).enumerate() {
        let w = if i % 4 == 3 { alpha.unwrap_or(*w) } else { *w };
        assert!((*g as i32 - w as i32).abs() <= tol, "{what}: byte {i} (pixel {}) is {g}, want {w}", i / 4);
    }
}

#[test]
fn effects_of_the_same_layout_read_each_other_without_a_convert() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (36, 20);
    let src = blocks(w, h);
    let mut g = pkgs.graph(&ctx, "id420.zip|id420.zip|id420.zip").unwrap();
    let out = run(&mut g, &src, w, h);
    // One convert in (rgba to yuv420), one out; none between the effects.
    assert_eq!(g.layout_converts(), 2);
    assert_near(&out[0], &src, 2, Some(255), "chain of yuv420");
}

#[test]
fn a_layout_change_between_effects_inserts_one_convert() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (36, 20);
    let src = blocks(w, h);
    let mut g = pkgs.graph(&ctx, "id420.zip|id444.zip").unwrap();
    let out = run(&mut g, &src, w, h);
    assert_eq!(g.layout_converts(), 3);
    assert_near(&out[0], &src, 2, Some(255), "yuv420 to yuv444");
    let mut g = pkgs.graph(&ctx, "id444.zip|id420.zip|ida420.zip").unwrap();
    let out = run(&mut g, &src, w, h);
    assert_eq!(g.layout_converts(), 4);
    assert_near(&out[0], &src, 2, Some(255), "yuv444 to yuv420 to yuva420");
}

#[test]
fn rgba_through_planes_and_back_keeps_the_pixels_at_odd_sizes() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    for (w, h) in [(5, 3), (1, 1), (17, 9)] {
        // 4:4:4 keeps any colour; alpha is dropped (opaque).
        let src = gradient(w, h);
        let out = run(&mut pkgs.graph(&ctx, "id444.zip").unwrap(), &src, w, h);
        assert_near(&out[0], &src, 2, Some(255), &format!("yuv444 {w}x{h}"));
        // yuva420 keeps the alpha of every pixel.
        let src = blocks(w, h).chunks(4).zip(gradient(w, h).chunks(4)).flat_map(|(c, a)| [c[0], c[1], c[2], a[3]]).collect::<Vec<u8>>();
        let out = run(&mut pkgs.graph(&ctx, "ida420.zip").unwrap(), &src, w, h);
        assert_near(&out[0], &src, 2, None, &format!("yuva420 {w}x{h}"));
    }
}

#[test]
fn a_y_output_is_the_luma() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (7, 5);
    let src: Vec<u8> = (0..w * h).flat_map(|i| [(i * 7) as u8; 3].into_iter().chain([255])).collect();
    let out = run(&mut pkgs.graph(&ctx, "luma.zip").unwrap(), &src, w, h);
    assert_near(&out[0], &src, 2, Some(255), "gray through y");
}

#[test]
fn a_texture_with_planes_between_passes() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (13, 11);
    let src = blocks(w, h);
    let mut g = pkgs.graph(&ctx, "twopass.zip").unwrap();
    let out = run(&mut g, &src, w, h);
    assert_eq!(g.layout_converts(), 2);
    assert_near(&out[0], &src, 2, Some(255), "two passes");
    // One pooled texture per plane; nothing is shared, all are alive at the second pass.
    let (n, _) = g.memory_plan(&[(w, h)], false).unwrap();
    assert_eq!(n, 7, "input convert Y+UV, tmp Y+UV, out Y+UV, output convert RGBA");
}

#[test]
fn an_optional_output_with_planes_switched_off_writes_its_stand_in() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (9, 7);
    let src = blocks(w, h);
    let mut g = pkgs.graph(&ctx, "keyed.zip=matte=off").unwrap();
    assert_eq!(g.output_count(), 1);
    let out = run(&mut g, &src, w, h);
    assert_near(&out[0], &src, 2, Some(255), "color, matte off");
    let mut g = pkgs.graph(&ctx, "keyed.zip").unwrap();
    let out = run(&mut g, &src, w, h);
    assert_near(&out[0], &src, 2, Some(255), "color, matte on");
    assert!(out[1].chunks(4).all(|p| p == [255, 255, 255, 255]), "matte on");
}

#[test]
fn an_effect_with_planes_switched_off_passes_its_input() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (10, 6);
    let src = blocks(w, h);
    let mut g = pkgs.graph(&ctx, "id420.zip|id444.zip").unwrap();
    g.set_node_enabled(1, false).unwrap();
    let out = run(&mut g, &src, w, h);
    assert_near(&out[0], &src, 2, Some(255), "id444 off");
    g.set_node_enabled(1, true).unwrap();
    let out = run(&mut g, &src, w, h);
    assert_near(&out[0], &src, 2, Some(255), "id444 on again");
}

#[test]
fn the_input_convert_of_an_effect_switched_off_does_not_run() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (10, 6);
    let src = blocks(w, h);
    let mut g = pkgs.graph(&ctx, "id420.zip|id444.zip").unwrap();
    run(&mut g, &src, w, h);
    assert_eq!(g.layout_converts(), 3, "in, yuv420 to yuv444, out");
    g.set_node_enabled(1, false).unwrap();
    let out = run(&mut g, &src, w, h);
    // Off, id444 copies yuv420 through its own convert: the one to its input has no reader.
    assert_eq!(g.layout_converts(), 2, "in, out");
    assert_near(&out[0], &src, 2, Some(255), "id444 off");
}

#[test]
fn an_effect_with_planes_switched_off_rejects_an_input_of_another_size() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (10, 6);
    let (a, b) = (blocks(w, h), blocks(4, 2));
    let mut g = pkgs.graph(&ctx, "[0][1]pick420.zip[out]").unwrap();
    g.set_node_enabled(0, false).unwrap();
    g.set_node_bypass(0, 1).unwrap();
    let mut out = vec![0u8; (w * h * 4) as usize];
    let ins = [Image { data: &a, width: w, height: h, stride: w * 4 }, Image { data: &b, width: 4, height: 2, stride: 16 }];
    let targets = vec![ImageMut { data: &mut out, width: w, height: h, stride: w * 4 }];
    let err = g.process(&ins, targets, &FrameInfo::new(0.0, 0)).unwrap_err().to_string();
    assert!(err.contains("passes its input 1") && err.contains("4x2"), "{err}");
}

// Frames loaded and written straight as planes (no RGBA in between) when the format is of
// the layout of the effects reading or writing them.

/// Plane bytes of a `format` frame: any code per sample (10-bit formats: little endian
/// codes below 1024, shifted for P010), different in each plane.
fn codes(format: PixelFormat, w: u32, h: u32, seed: u32) -> Vec<Vec<u8>> {
    let (deep, shift) = match format {
        PixelFormat::P010 => (true, 6),
        PixelFormat::Yuv420p10 | PixelFormat::Yuv422p10 | PixelFormat::Yuv444p10 => (true, 0),
        _ => (false, 0),
    };
    (0..format.plane_count())
        .map(|p| {
            let (row, rows) = format.plane_size(p, w, h);
            let n = if deep { row * rows / 2 } else { row * rows };
            (0..n)
                .flat_map(|i| {
                    let c = (i * 37 + p as u32 * 91 + seed * 13 + 5) % if deep { 1024 } else { 256 };
                    if deep {
                        ((c << shift) as u16).to_le_bytes().to_vec()
                    } else {
                        vec![c as u8]
                    }
                })
                .collect()
        })
        .collect()
}

#[test]
fn a_yuv420_chain_fed_nv12_runs_no_conversion_and_keeps_the_codes() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    for (w, h) in [(37, 21), (1, 1), (6, 4)] {
        let src = codes(PixelFormat::Nv12, w, h, 1);
        let mut g = pkgs.graph(&ctx, "id420.zip|id420.zip|id420.zip").unwrap();
        let out = cpu_run(&mut g, &[(PixelFormat::Nv12, src.clone())], &[PixelFormat::Nv12], w, h, Some(&FrameInfo::new(0.0, 0)));
        assert_eq!(g.layout_converts(), 0, "{w}x{h}");
        assert_eq!(g.rgba_conversions(), 0, "{w}x{h}");
        assert_eq!(out[0], src, "nv12 through yuv420 effects {w}x{h}");
        // The same codes out of a planar format of the layout.
        let out = cpu_run(&mut g, &[(PixelFormat::Nv12, src.clone())], &[PixelFormat::Yuv420p], w, h, Some(&FrameInfo::new(0.0, 0)));
        assert_eq!(out[0][0], src[0], "Y {w}x{h}");
        let (u, v): (Vec<u8>, Vec<u8>) = src[1].chunks(2).map(|c| (c[0], c[1])).unzip();
        assert_eq!((&out[0][1], &out[0][2]), (&u, &v), "U, V {w}x{h}");
    }
}

#[test]
fn a_yuv444p_input_into_a_yuv420_effect_takes_one_plane_convert() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (9, 5);
    let src = codes(PixelFormat::Yuv444p, w, h, 2);
    let mut g = pkgs.graph(&ctx, "id420.zip").unwrap();
    let out = cpu_run(&mut g, &[(PixelFormat::Yuv444p, src.clone())], &[PixelFormat::Nv12], w, h, Some(&FrameInfo::new(0.0, 0)));
    assert_eq!((g.layout_converts(), g.rgba_conversions()), (1, 0));
    assert_eq!(out[0][0], src[0], "Y");
    // UV: the mean of the 2x2 pixels of each texel (those inside the frame).
    let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
    for cy in 0..ch {
        for cx in 0..cw {
            for (c, plane) in [1usize, 2].into_iter().enumerate() {
                let px: Vec<u32> = (0..4)
                    .map(|k| (cx * 2 + k % 2, cy * 2 + k / 2))
                    .filter(|&(x, y)| x < w && y < h)
                    .map(|(x, y)| src[plane][(y * w + x) as usize] as u32)
                    .collect();
                let want = px.iter().sum::<u32>() as f32 / px.len() as f32;
                let got = out[0][1][((cy * cw + cx) * 2) as usize + c] as f32;
                assert!((got - want).abs() <= 1.0, "texel {cx},{cy} channel {c}: {got}, want {want}");
            }
        }
    }
}

#[test]
fn a_y_output_is_written_as_gray() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (7, 5);
    let src = codes(PixelFormat::Nv12, w, h, 3);
    let mut g = pkgs.graph(&ctx, "luma.zip").unwrap();
    assert_eq!(g.output_default_format(0, None, Some("nv12")).unwrap(), PixelFormat::Gray);
    let out = cpu_run(&mut g, &[(PixelFormat::Nv12, src.clone())], &[PixelFormat::Gray], w, h, Some(&FrameInfo::new(0.0, 0)));
    assert_eq!((g.layout_converts(), g.rgba_conversions()), (0, 0));
    assert_eq!(out[0][0], src[0]);
}

#[test]
fn a_yuva420_output_keeps_its_alpha_in_yuva420p() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (11, 7);
    let src = codes(PixelFormat::Yuva420p, w, h, 4);
    let mut g = pkgs.graph(&ctx, "ida420.zip").unwrap();
    assert_eq!(g.output_default_format(0, None, Some("nv12")).unwrap(), PixelFormat::Yuva420p);
    let out = cpu_run(&mut g, &[(PixelFormat::Yuva420p, src.clone())], &[PixelFormat::Yuva420p], w, h, Some(&FrameInfo::new(0.0, 0)));
    assert_eq!((g.layout_converts(), g.rgba_conversions()), (0, 0));
    assert_eq!(out[0], src);
}

#[test]
fn out_format_picks_rgba_over_the_planes() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (8, 6);
    let mut g = pkgs.graph(&ctx, "id420.zip").unwrap();
    // The default: the first input's format when of the output's layout, else the layout's.
    assert_eq!(g.output_default_format(0, Some("rgba"), Some("nv12")).unwrap(), PixelFormat::Rgba);
    assert_eq!(g.output_default_format(0, None, Some("yuv420p")).unwrap(), PixelFormat::Yuv420p);
    assert_eq!(g.output_default_format(0, None, Some("yuv444p")).unwrap(), PixelFormat::Nv12);
    assert!(g.output_default_format(0, Some("gray16le"), None).is_err());
    // Flat chroma: the nearest chroma of the layout convert is the bilinear one of the frame conversion.
    let mut src = codes(PixelFormat::Nv12, w, h, 5);
    src[0].iter_mut().for_each(|y| *y = 16 + *y % 200);
    src[1].chunks_mut(2).for_each(|c| c.copy_from_slice(&[100, 150]));
    let out = cpu_run(&mut g, &[(PixelFormat::Nv12, src.clone())], &[PixelFormat::Rgba], w, h, Some(&FrameInfo::new(0.0, 0)));
    assert_eq!((g.layout_converts(), g.rgba_conversions()), (1, 1));
    let mut plain = pkgs.graph(&ctx, "id420.zip").unwrap();
    let want = cpu_run(&mut plain, &[(PixelFormat::Nv12, src)], &[PixelFormat::Rgba], w, h, None);
    assert_near(&out[0][0], &want[0][0], 2, None, "nv12 to rgba through yuv420");
}

#[test]
fn deep_planes_keep_their_codes() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (13, 7);
    let src = codes(PixelFormat::Yuv420p10, w, h, 6);
    let mut g = pkgs.graph(&ctx, "id420.zip|id420.zip").unwrap();
    let out = cpu_run(&mut g, &[(PixelFormat::Yuv420p10, src.clone())], &[PixelFormat::P010], w, h, Some(&FrameInfo::new(0.0, 0)));
    assert_eq!((g.layout_converts(), g.rgba_conversions()), (0, 0));
    let shifted = |plane: &[u8]| plane.chunks(2).flat_map(|c| (u16::from_le_bytes([c[0], c[1]]) << 6).to_le_bytes()).collect::<Vec<u8>>();
    assert_eq!(out[0][0], shifted(&src[0]), "Y");
    let uv: Vec<u8> = src[1].chunks(2).zip(src[2].chunks(2)).flat_map(|(u, v)| [u, v].concat()).collect();
    assert_eq!(out[0][1], shifted(&uv), "UV");
}

#[test]
fn gray_frames_go_in_and_out_of_rgba_effects() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (w, h) = (5, 3);
    let src = codes(PixelFormat::Gray, w, h, 7);
    let mut g = pkgs.graph(&ctx, "idrgba.zip").unwrap();
    // Through RGBA: limited range gray, neutral chroma, so the codes come back.
    let out = cpu_run(&mut g, &[(PixelFormat::Gray, src.clone())], &[PixelFormat::Gray], w, h, Some(&FrameInfo::new(0.0, 0)));
    assert_eq!(g.rgba_conversions(), 2);
    let clamp = |c: u8| c.clamp(16, 235) as i32;
    for (i, (&got, &want)) in out[0][0].iter().zip(&src[0]).enumerate() {
        assert!((got as i32 - clamp(want)).abs() <= 1, "pixel {i}: {got}, want {}", clamp(want));
    }
}

#[test]
fn gpu_frames_of_the_layout_skip_rgba() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let info = FrameInfo::new(0.0, 0);
    let (w, h) = (37, 21);
    use PixelFormat::*;
    for (fin, fout, text) in [
        (Nv12, Nv12, "id420.zip|id420.zip|id420.zip"),
        (Nv12, Gray, "luma.zip"),
        (Yuva420p, Yuva420p, "ida420.zip"),
        (P010, Yuv420p10, "id420.zip"),
        (Yuv420p10, P010, "id420.zip"),
    ] {
        if !supported(&ctx, fin) || !supported(&ctx, fout) {
            eprintln!("skipping {} -> {}: the adapter lacks the format features", fin.name(), fout.name());
            continue;
        }
        let data = codes(fin, w, h, 8);
        for direct in [false, true] {
            let mut g = pkgs.graph(&ctx, text).unwrap();
            if direct {
                g.allow_direct_gpu();
            }
            let want = cpu_run(&mut g, &[(fin, data.clone())], &[fout], w, h, Some(&info));
            let got = gpu_run(&ctx, &mut g, &[upload(&ctx, fin, &data, w, h)], &[target(&ctx, fout, w, h)], Some(&info));
            assert_eq!(got, want, "{} -> {} direct {direct}", fin.name(), fout.name());
            assert_eq!((g.layout_converts(), g.rgba_conversions()), (0, 0), "{} -> {}", fin.name(), fout.name());
            if direct && matches!(fin, Nv12) {
                assert_eq!(g.memory().input_textures, 0, "8-bit NV12 planes are read in place");
            }
        }
    }
}

#[test]
fn rgba_effects_write_gray_gpu_frames() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let info = FrameInfo::new(0.0, 0);
    let (w, h) = (9, 4);
    for fin in [PixelFormat::Rgba, PixelFormat::Gray] {
        let data = codes(fin, w, h, 9);
        let mut g = pkgs.graph(&ctx, "idrgba.zip").unwrap();
        let want = cpu_run(&mut g, &[(fin, data.clone())], &[PixelFormat::Gray], w, h, Some(&info));
        let got = gpu_run(&ctx, &mut g, &[upload(&ctx, fin, &data, w, h)], &[target(&ctx, PixelFormat::Gray, w, h)], Some(&info));
        assert_eq!(got, want, "{} -> gray", fin.name());
    }
}

// Frame helpers of tests/gpu_frames.rs.

fn is_16(format: wgpu::TextureFormat) -> bool {
    matches!(format, wgpu::TextureFormat::R16Unorm | wgpu::TextureFormat::Rg16Unorm | wgpu::TextureFormat::Rgba16Unorm)
}

fn cpu_run(
    g: &mut EffectGraph,
    inputs: &[(PixelFormat, Vec<Vec<u8>>)],
    outs: &[PixelFormat],
    w: u32,
    h: u32,
    info: Option<&FrameInfo>,
) -> Vec<Vec<Vec<u8>>> {
    let color = ColorInfo { matrix: Matrix::Bt709, range: Range::Limited, ..Default::default() };
    cpu_run_color(g, inputs, outs, w, h, info, color)
}

fn cpu_run_color(
    g: &mut EffectGraph,
    inputs: &[(PixelFormat, Vec<Vec<u8>>)],
    outs: &[PixelFormat],
    w: u32,
    h: u32,
    info: Option<&FrameInfo>,
    color: ColorInfo,
) -> Vec<Vec<Vec<u8>>> {
    let frames: Vec<Frame> = inputs
        .iter()
        .map(|(format, planes)| {
            let mut p: [&[u8]; 4] = [&[]; 4];
            let mut strides = [0; 4];
            for (i, data) in planes.iter().enumerate() {
                p[i] = data;
                strides[i] = format.plane_size(i, w, h).0;
            }
            Frame { format: *format, width: w, height: h, planes: p, strides, color }
        })
        .collect();
    let mut bufs: Vec<Vec<Vec<u8>>> = outs
        .iter()
        .map(|f| {
            (0..f.plane_count())
                .map(|p| {
                    vec![
                        0u8;
                        {
                            let (r, n) = f.plane_size(p, w, h);
                            (r * n) as usize
                        }
                    ]
                })
                .collect()
        })
        .collect();
    {
        let mut targets: Vec<FrameMut> = bufs
            .iter_mut()
            .zip(outs)
            .map(|(planes, &format)| {
                let mut strides = [0; 4];
                let mut it = planes.iter_mut();
                let mut p: [&mut [u8]; 4] = Default::default();
                for (i, slot) in p.iter_mut().enumerate().take(format.plane_count()) {
                    *slot = it.next().unwrap();
                    strides[i] = format.plane_size(i, w, h).0;
                }
                FrameMut { format, width: w, height: h, planes: p, strides, color }
            })
            .collect();
        match info {
            Some(info) => g.process_frames(&frames, &mut targets, info).unwrap(),
            None => g.convert(&frames, &mut targets).unwrap(),
        }
    }
    bufs
}

fn upload(ctx: &GpuContext, format: PixelFormat, planes: &[Vec<u8>], w: u32, h: u32) -> GpuFrame {
    let color = ColorInfo { matrix: Matrix::Bt709, range: Range::Limited, ..Default::default() };
    let textures = planes
        .iter()
        .enumerate()
        .map(|(p, data)| {
            let (pw, ph) = format.plane_texture_size(p, w, h);
            let tex = ctx.device().create_texture(&wgpu::TextureDescriptor {
                label: None,
                size: wgpu::Extent3d { width: pw, height: ph, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: format.plane_texture_format(p),
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            });
            ctx.queue().write_texture(
                tex.as_image_copy(),
                data,
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(format.plane_size(p, w, h).0), rows_per_image: Some(ph) },
                wgpu::Extent3d { width: pw, height: ph, depth_or_array_layers: 1 },
            );
            tex
        })
        .collect();
    GpuFrame { format, width: w, height: h, planes: textures, color }
}

fn target(ctx: &GpuContext, format: PixelFormat, w: u32, h: u32) -> GpuFrame {
    let color = ColorInfo { matrix: Matrix::Bt709, range: Range::Limited, ..Default::default() };
    let textures = (0..format.plane_count())
        .map(|p| {
            let (pw, ph) = format.plane_texture_size(p, w, h);
            ctx.device().create_texture(&wgpu::TextureDescriptor {
                label: None,
                size: wgpu::Extent3d { width: pw, height: ph, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: format.plane_texture_format(p),
                usage: wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC,
                view_formats: &[],
            })
        })
        .collect();
    GpuFrame { format, width: w, height: h, planes: textures, color }
}

/// Tightly packed bytes of every plane texture.
fn download(ctx: &GpuContext, frame: &GpuFrame) -> Vec<Vec<u8>> {
    let device = ctx.device();
    frame
        .planes
        .iter()
        .enumerate()
        .map(|(p, tex)| {
            let row = frame.format.plane_size(p, frame.width, frame.height).0;
            let padded = row.div_ceil(256) * 256;
            let buf = device.create_buffer(&wgpu::BufferDescriptor {
                label: None,
                size: (padded * tex.height()) as u64,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            });
            let mut enc = device.create_command_encoder(&Default::default());
            enc.copy_texture_to_buffer(
                tex.as_image_copy(),
                wgpu::TexelCopyBufferInfo {
                    buffer: &buf,
                    layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(padded), rows_per_image: None },
                },
                tex.size(),
            );
            ctx.queue().submit([enc.finish()]);
            buf.slice(..).map_async(wgpu::MapMode::Read, |r| r.unwrap());
            device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
            let mapped = buf.slice(..).get_mapped_range().unwrap();
            (0..tex.height() as usize).flat_map(|y| mapped[y * padded as usize..][..row as usize].to_vec()).collect()
        })
        .collect()
}

fn gpu_run(ctx: &GpuContext, g: &mut EffectGraph, inputs: &[GpuFrame], outs: &[GpuFrame], info: Option<&FrameInfo>) -> Vec<Vec<Vec<u8>>> {
    let mut enc = ctx.device().create_command_encoder(&Default::default());
    g.encode_gpu(inputs, outs, info, &mut enc).unwrap();
    ctx.queue().submit([enc.finish()]);
    // Other graphs on the device may use the pooled textures from now on.
    g.release_frame();
    outs.iter().map(|o| download(ctx, o)).collect()
}

fn supported(ctx: &GpuContext, format: PixelFormat) -> bool {
    let deep = (0..format.plane_count()).any(|p| is_16(format.plane_texture_format(p)));
    let need = wgpu::Features::TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES
        | if deep { wgpu::Features::TEXTURE_FORMAT_16BIT_NORM } else { wgpu::Features::empty() };
    ctx.device().features().contains(need)
}
