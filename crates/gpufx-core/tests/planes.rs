//! Effects with a `pixel_layout` other than `rgba` in graphs: the layout converts the core
//! inserts between sources and effect inputs of other layouts (none between effects of
//! the same layout), pooled plane textures, odd sizes, outputs switched off and textures
//! between passes. Frames still come and go as RGBA. Tests that need a device are skipped
//! when none can be created.

mod common;

use std::path::PathBuf;
use std::sync::Arc;

use gpufx_core::{Effect, EffectGraph, Error, FrameInfo, GpuContext, Image, ImageMut, Package};

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
