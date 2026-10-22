//! Effects with several outputs: manifest `output` arrays, labels of graph nodes, outputs
//! dropped, bypass and sizes per output. Tests that need a device are skipped when none
//! can be created.

mod common;

use std::path::{Path, PathBuf};
use std::sync::Arc;

use gpufx_core::{Effect, EffectGraph, Error, FrameInfo, GpuContext, Image, ImageMut, Package, Source};

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

/// The example effect `name` (any group folder).
fn example(name: &str) -> PathBuf {
    fn find(dir: &Path, name: &str) -> Option<PathBuf> {
        for e in std::fs::read_dir(dir).ok()? {
            let p = e.ok()?.path();
            if p.join("manifest.json").exists() {
                if p.file_name().is_some_and(|n| n == name) {
                    return Some(p);
                }
            } else if p.is_dir() {
                if let Some(f) = find(&p, name) {
                    return Some(f);
                }
            }
        }
        None
    }
    find(&PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../packages/gpufx"), name).unwrap_or_else(|| panic!("no example {name}"))
}

/// `color` is the input with red and blue swapped, `matte` its red channel as gray; both
/// copies, so the pixels are exact.
const SWAP: &str = "textureLoad(src, vec2i(id.xy), 0).bgra";
const MATTE: &str = "vec4f(vec3f(textureLoad(src, vec2i(id.xy), 0).r), 1.0)";

fn wgsl(body: &str) -> String {
    format!("@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) {{\n    if (!gpufx_in_bounds(id)) {{ return; }}\n    {body}\n}}\n")
}

/// Test packages written to a temporary directory, removed when dropped.
struct Packages(PathBuf);

impl Packages {
    fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("gpufx-outputs-{}-{n}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        let pkgs = Packages(dir);
        let head = r#""api":1,"used_for":["gpufx"],"output":[{"name":"color","formats":["rgba","nv12"]},{"name":"matte","formats":["gray","rgba"]}]"#;
        // One pass writes both.
        pkgs.add(
            "key",
            &format!(r#"{{"id":"t.key","name":"Key",{head},"groups":[{{"passes":[{{"shader":"k.wgsl","inputs":["src"],"output":["color","matte"]}}]}}]}}"#),
            &[("k.wgsl", wgsl(&format!("gpufx_write(id, {SWAP});\n    gpufx_write1(id, {MATTE});")))],
        );
        // The same in GLSL.
        let glsl = "#version 450\nlayout(local_size_x = 8, local_size_y = 8) in;\nvoid main() {\n    uvec3 id = gl_GlobalInvocationID;\n    if (!gpufx_in_bounds(id)) { return; }\n    vec4 c = texelFetch(sampler2D(src, smp), ivec2(id.xy), 0);\n    gpufx_write(id, c.bgra);\n    gpufx_write1(id, vec4(vec3(c.r), 1.0));\n}\n";
        pkgs.add(
            "keyglsl",
            &format!(r#"{{"id":"t.keyglsl","name":"Key GLSL",{head},"groups":[{{"passes":[{{"shader":"k.glsl","inputs":["src"],"output":["color","matte"]}}]}}]}}"#),
            &[("k.glsl", glsl.to_string())],
        );
        // The matte from the first pass, which also makes a texture for the second.
        pkgs.add(
            "keymid",
            &format!(
                r#"{{"id":"t.keymid","name":"Key mid",{head},"groups":[{{"passes":[{{"shader":"a.wgsl","inputs":["src"],"output":["matte","tmp"]}},{{"shader":"b.wgsl","inputs":["tmp"],"output":["color"]}}]}}]}}"#
            ),
            &[
                ("a.wgsl", wgsl(&format!("gpufx_write(id, {MATTE});\n    gpufx_write1(id, textureLoad(src, vec2i(id.xy), 0));"))),
                ("b.wgsl", wgsl("gpufx_write(id, textureLoad(tmp, vec2i(id.xy), 0).bgra);")),
            ],
        );
        // Each output from a pass of its own, so dropping one skips its pass.
        pkgs.add(
            "keysep",
            &format!(
                r#"{{"id":"t.keysep","name":"Key sep",{head},"groups":[{{"passes":[{{"shader":"c.wgsl","inputs":["src"],"output":["color"]}},{{"shader":"m.wgsl","inputs":["src"],"output":["matte"]}}]}}]}}"#
            ),
            &[("m.wgsl", wgsl(&format!("gpufx_write(id, {MATTE});"))), ("c.wgsl", wgsl(&format!("gpufx_write(id, {SWAP});")))],
        );
        // Two inputs; switched off, the matte passes the second.
        pkgs.add(
            "key2",
            r#"{"id":"t.key2","name":"Key 2","api":1,"used_for":["gpufx"],"inputs":[{"name":"src"},{"name":"bg","same_size":true}],
                "output":[{"name":"color"},{"name":"matte","bypass":"bg"}],
                "groups":[{"passes":[{"shader":"k.wgsl","inputs":["src","bg"],"output":["color","matte"]}]}]}"#,
            &[("k.wgsl", wgsl(&format!("gpufx_write(id, {SWAP});\n    gpufx_write1(id, textureLoad(bg, vec2i(id.xy), 0).bgra);")))],
        );
        // Outputs of different sizes: `color` the first input swapped, `side` both inputs
        // side by side, each pass at the size of its output (`globals.size`).
        pkgs.add(
            "stk",
            r#"{"id":"t.stk","name":"Stack","api":1,"used_for":["gpufx"],"inputs":[{"name":"a"},{"name":"b"}],
                "output":[{"name":"color"},{"name":"side","size":"hstack"}],
                "groups":[{"passes":[{"shader":"c.wgsl","inputs":["a"],"output":["color"]},{"shader":"s.wgsl","inputs":["a","b"],"output":["side"]}]}]}"#,
            &[
                ("c.wgsl", wgsl("gpufx_write(id, textureLoad(a, vec2i(id.xy), 0).bgra);")),
                (
                    "s.wgsl",
                    wgsl("let wa = i32(textureDimensions(a).x);\n    let p = vec2i(id.xy);\n    if (f32(id.x) >= globals.size.x) { return; }\n    if (p.x < wa) { gpufx_write(id, textureLoad(a, p, 0)); } else { gpufx_write(id, textureLoad(b, vec2i(p.x - wa, p.y), 0)); }"),
                ),
            ],
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

    fn open(&self, ctx: &Arc<GpuContext>, name: &str) -> Result<Effect, Error> {
        let dir = self.0.join(name);
        let dir = if dir.exists() { dir } else { example(name) };
        Effect::new(ctx.clone(), Package::open(dir)?)
    }

    fn graph(&self, ctx: &Arc<GpuContext>, text: &str) -> Result<EffectGraph, Error> {
        EffectGraph::parse(text, |path| {
            let name = path.trim_end_matches(".zip");
            Ok((name.to_string(), self.open(ctx, name)?))
        })
    }
}

impl Drop for Packages {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).ok();
    }
}

const W: u32 = 37;
const H: u32 = 21;

fn gradient(seed: u32) -> Vec<u8> {
    (0..W * H).flat_map(|i| [(i % W * 7 + seed) as u8, (i / W * 11) as u8, (seed * 40 + 30) as u8, 200]).collect()
}

fn swapped(src: &[u8]) -> Vec<u8> {
    src.chunks(4).flat_map(|p| [p[2], p[1], p[0], p[3]]).collect()
}

fn matte(src: &[u8]) -> Vec<u8> {
    src.chunks(4).flat_map(|p| [p[0], p[0], p[0], 255]).collect()
}

fn img(d: &[u8]) -> Image<'_> {
    Image { data: d, width: W, height: H, stride: W * 4 }
}

fn run_graph(g: &mut EffectGraph, inputs: &[&[u8]]) -> Vec<Vec<u8>> {
    let mut outs = vec![vec![0u8; (W * H * 4) as usize]; g.output_count()];
    let imgs: Vec<Image> = inputs.iter().map(|d| img(d)).collect();
    let targets = outs.iter_mut().map(|o| ImageMut { data: o, width: W, height: H, stride: W * 4 }).collect();
    g.process(&imgs, targets, &FrameInfo::new(0.0, 0)).unwrap();
    outs
}

/// One example effect run alone.
fn run(pkgs: &Packages, ctx: &Arc<GpuContext>, name: &str, input: &[u8]) -> Vec<u8> {
    let mut out = vec![0u8; input.len()];
    pkgs.open(ctx, name)
        .unwrap()
        .process(&[img(input)], ImageMut { data: &mut out, width: W, height: H, stride: W * 4 }, &FrameInfo::new(0.0, 0))
        .unwrap();
    out
}

#[test]
fn an_effect_writes_two_outputs_in_wgsl_and_glsl_from_any_pass() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let src = gradient(1);
    for name in ["key", "keyglsl", "keymid", "keysep"] {
        // A chain of one effect: one pad per output, named as in the manifest.
        let mut g = pkgs.graph(&ctx, &format!("{name}.zip")).unwrap();
        assert_eq!(g.output_names(), ["color", "matte"], "{name}");
        assert_eq!(g.output_source(1), Source::Node(0, 1));
        assert_eq!(g.output_formats(1), ["gray", "rgba"]);
        let outs = run_graph(&mut g, &[&src]);
        assert!(outs[0] == swapped(&src), "{name}: color");
        assert!(outs[1] == matte(&src), "{name}: matte");
        // Labelled, by position.
        let mut g = pkgs.graph(&ctx, &format!("[0]{name}.zip[c][m]")).unwrap();
        assert_eq!(g.output_names(), ["c", "m"]);
        assert!(run_graph(&mut g, &[&src]) == [swapped(&src), matte(&src)], "{name}: labelled");
    }
    // Run alone, an effect of two outputs has nowhere to put the second.
    let mut fx = pkgs.open(&ctx, "key").unwrap();
    let mut out = vec![0u8; src.len()];
    let e = fx.process(&[img(&src)], ImageMut { data: &mut out, width: W, height: H, stride: W * 4 }, &FrameInfo::new(0.0, 0));
    assert!(e.unwrap_err().to_string().contains("has 2 outputs"));
}

#[test]
fn labels_go_to_outputs_by_position_or_by_name() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let src = gradient(2);
    let inv = run(&pkgs, &ctx, "invert", &swapped(&src));
    let gray = run(&pkgs, &ctx, "grayscale", &matte(&src));
    for text in [
        // The first output without a label goes on along the chain.
        "[0]key.zip[matte=m]|invert.zip[out]; [m]grayscale.zip[out2]",
        "[0]key.zip[matte=m][color=c]; [c]invert.zip[out]; [m]grayscale.zip[out2]",
        "[0]key.zip[c][m]; [c]invert.zip[out]; [m]grayscale.zip[out2]",
    ] {
        let mut g = pkgs.graph(&ctx, text).unwrap();
        assert_eq!(g.output_names(), ["out", "out2"], "{text}");
        let outs = run_graph(&mut g, &[&src]);
        assert!(outs[0] == inv && outs[1] == gray, "{text}");
    }
    // A label written by a node names its effects, whatever output it is.
    let g = pkgs.graph(&ctx, "[0]key.zip[c][m]; [c]invert.zip[out]").unwrap();
    assert_eq!(g.find_node("m").unwrap(), [0]);
    assert_eq!(g.output_names(), ["m", "out"]);

    // In a chain, the second output of a middle effect is dropped.
    let mut g = pkgs.graph(&ctx, "key.zip|invert.zip").unwrap();
    assert_eq!(g.output_names(), ["default"]);
    assert_eq!(g.effect_inputs(1), [Source::Node(0, 0)]);
    assert!(run_graph(&mut g, &[&src])[0] == inv);
    // A last effect without labels writes every output to the graph.
    let g = pkgs.graph(&ctx, "[0]invert.zip[a]; [a]key.zip").unwrap();
    assert_eq!(g.output_names(), ["out0", "out1"]);
}

#[test]
fn input_labels_by_name_take_the_manifest_order() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (a, b) = (gradient(3), gradient(4));
    let want = run_graph(&mut pkgs.graph(&ctx, "[0][1]key2.zip[c][m]").unwrap(), &[&a, &b]);
    let mut g = pkgs.graph(&ctx, "[bg=1][src=0]key2.zip[matte=m][color=c]").unwrap();
    assert_eq!(g.effect_inputs(0), [Source::Input(0), Source::Input(1)]);
    assert_eq!(g.output_names(), ["m", "c"]);
    let outs = run_graph(&mut g, &[&a, &b]);
    assert!(outs[0] == want[1] && outs[1] == want[0]);
    // A repeated input counts the pads it is given by name.
    let g = pkgs.graph(&ctx, "[src0=0][src1=1][src2=2]hstack.zip[o]").unwrap();
    assert_eq!(g.input_count(), 3);
    assert_eq!(g.effects()[0].input_count(), 3);
}

#[test]
fn label_mistakes_are_explained() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let cases = [
        ("[0]key.zip[matte=m][color=c]|invert.zip[out]", "every output has a label, so none goes on to `invert`"),
        ("[0]key.zip[c]|[c]invert.zip[o]", "input labels go at the start of a statement"),
        ("[0][bg=1]key2.zip[c]", "use either positional labels or `[name=label]` for its inputs"),
        ("[src=0][bg=1]key2.zip[matte=m][x]", "use either positional labels or `[name=label]`, not both"),
        ("[0]key.zip[nope=x]", "`key` has no output `nope` (outputs: color, matte)"),
        ("[0]key.zip[matte=x][matte=y]", "output `matte` of `key` is given two labels"),
        ("[0]key.zip[a][b][c]", "`key` writes 2 outputs (color, matte), got 3 labels"),
        ("[src=0]key2.zip[c]", "input `bg` of `key2` has no label"),
        ("[src=0][src=1]key2.zip[c]", "input `src` of `key2` is given two labels"),
        ("[nope=0]invert.zip[c]", "`invert` has no input `nope`"),
        ("[0]split[a=b][c]", "takes plain labels"),
        ("[0]key.zip[=x]", "bad label"),
        ("[src0=0][src2=1]hstack.zip[o]", "they go from `src0` to `src1`"),
    ];
    for (text, want) in cases {
        let got = match pkgs.graph(&ctx, text) {
            Ok(_) => panic!("`{text}` was accepted"),
            Err(e) => e.to_string(),
        };
        assert!(got.contains(want), "`{text}`: {got}");
    }
}

#[test]
fn outputs_nobody_reads_are_dropped_with_their_passes() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let src = gradient(5);
    let both = pkgs.graph(&ctx, "keysep.zip").unwrap();
    assert_eq!(both.memory_plan(&[(W, H)], false).unwrap().0, 2);
    // The matte has no label: its pass does not run and gets no texture (the color is
    // kept for the readback, so a matte texture would be a second one).
    let mut g = pkgs.graph(&ctx, "[0]keysep.zip[color=c]").unwrap();
    assert_eq!(g.output_names(), ["c"]);
    assert_eq!(g.memory_plan(&[(W, H)], false).unwrap().0, 1);
    assert!(run_graph(&mut g, &[&src])[0] == swapped(&src));
    let mut g = pkgs.graph(&ctx, "[0]keysep.zip[matte=m]").unwrap();
    assert!(run_graph(&mut g, &[&src])[0] == matte(&src));
}

#[test]
fn an_output_kept_for_the_graph_does_not_share_a_texture_with_later_passes() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let src = gradient(6);
    let blurred = run(&pkgs, &ctx, "gaussian-blur", &swapped(&src));
    // The matte is written first and read back last: the blur's two passes run in between.
    let mut g = pkgs.graph(&ctx, "[0]keymid.zip[c][m]; [c]gaussian-blur.zip[o]").unwrap();
    assert_eq!(g.output_names(), ["m", "o"]);
    for _ in 0..2 {
        let outs = run_graph(&mut g, &[&src]);
        assert!(outs[0] == matte(&src), "the matte was overwritten");
        assert!(outs[1] == blurred);
    }
}

#[test]
fn an_effect_switched_off_passes_the_input_of_each_output() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (a, b) = (gradient(7), gradient(8));
    let mut g = pkgs.graph(&ctx, "[0][1]key2.zip[c][m]").unwrap();
    g.set_node_enabled(0, false).unwrap();
    // `matte` names `bg` as its bypass.
    assert_eq!((g.node_bypass(0, 0), g.node_bypass(0, 1)), (0, 1));
    assert!(run_graph(&mut g, &[&a, &b]) == [a.clone(), b.clone()]);
    // `<effect>.bypass` picks one input for every output.
    g.set_node_bypass(0, 0).unwrap();
    assert!(run_graph(&mut g, &[&a, &b]) == [a.clone(), a.clone()]);
    g.set_node_enabled(0, true).unwrap();
    assert!(run_graph(&mut g, &[&a, &b]) == [swapped(&a), swapped(&b)]);
    // Bypassing the whole graph through the effects follows each output.
    g.set_bypass_pad(gpufx_core::BypassPad::Nodes).unwrap();
    let mut g = pkgs.graph(&ctx, "[0][1]key2.zip[c][m]").unwrap();
    g.set_bypass_pad(gpufx_core::BypassPad::Nodes).unwrap();
    assert_eq!((g.bypass_pad(0), g.bypass_pad(1)), (0, 1));
}

#[test]
fn outputs_have_their_own_sizes_and_passes_run_at_them() {
    let Some(ctx) = gpu() else { return };
    let pkgs = Packages::new();
    let (wa, wb, h) = (5u32, 3u32, 4u32);
    let a: Vec<u8> = (0..wa * h).flat_map(|i| [i as u8, 10, 20, 255]).collect();
    let b: Vec<u8> = (0..wb * h).flat_map(|i| [100 + i as u8, 30, 40, 255]).collect();
    let mut g = pkgs.graph(&ctx, "stk.zip").unwrap();
    assert_eq!(g.output_size(0, &[(wa, h), (wb, h)]).unwrap(), (wa, h));
    assert_eq!(g.output_size(1, &[(wa, h), (wb, h)]).unwrap(), (wa + wb, h));
    let mut color = vec![0u8; (wa * h * 4) as usize];
    let mut side = vec![0u8; ((wa + wb) * h * 4) as usize];
    let outs = vec![
        ImageMut { data: &mut color, width: wa, height: h, stride: wa * 4 },
        ImageMut { data: &mut side, width: wa + wb, height: h, stride: (wa + wb) * 4 },
    ];
    let ins = [Image { data: &a, width: wa, height: h, stride: wa * 4 }, Image { data: &b, width: wb, height: h, stride: wb * 4 }];
    g.process(&ins, outs, &FrameInfo::new(0.0, 0)).unwrap();
    assert_eq!(color, swapped(&a));
    let want: Vec<u8> = (0..h as usize)
        .flat_map(|y| [&a[y * wa as usize * 4..(y + 1) * wa as usize * 4], &b[y * wb as usize * 4..(y + 1) * wb as usize * 4]].concat())
        .collect();
    assert_eq!(side, want, "the second pass ran at the stacked size");
}
