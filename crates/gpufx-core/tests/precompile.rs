//! `gpufx pack --precompile`: the D3D12 shaders inside a package give the pixels of the
//! normal path, and are only used with `GPUFX_TRUST_PRECOMPILED=1`. Its own test binary:
//! it sets that variable for the whole process. Skipped without D3D12 or dxcompiler.dll.
#![cfg(windows)]

use std::path::{Path, PathBuf};

use gpufx_core::{Backend, Effect, FrameInfo, GpuContext, Image, ImageMut, Package};

/// Pushes every package directory (one with a `manifest.json`) below `dir`, at any depth.
fn collect_packages(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.join("manifest.json").exists() {
            out.push(p);
        } else if p.is_dir() {
            collect_packages(&p, out);
        }
    }
}

/// Every packed example on a new D3D12 device without cache directory: outputs, shader
/// cache counters and the passes of the groups that ran.
fn run_all(packages: &[Package]) -> (Vec<Vec<u8>>, Option<gpufx_core::ShaderCacheStats>, u64) {
    let ctx = GpuContext::with_shader_cache(Backend::Dx12, None).unwrap();
    let (w, h) = (16, 16);
    let mut passes = 0;
    let src: Vec<u8> = (0..w * h * 4).map(|i| (i * 7) as u8).collect();
    let outputs = packages
        .iter()
        .map(|pkg| {
            let mut fx = Effect::new(ctx.clone(), pkg.clone()).unwrap();
            passes += fx.package().manifest.passes.len() as u64;
            let inputs = vec![Image { data: &src, width: w, height: h, stride: w * 4 }; fx.input_count()];
            let (ow, oh) = fx.output_sizes(&vec![(w, h); fx.input_count()]).unwrap()[0];
            let mut out = vec![0u8; (ow * oh * 4) as usize];
            fx.process(&inputs, ImageMut { data: &mut out, width: ow, height: oh, stride: ow * 4 }, &FrameInfo::new(0.5, 3)).unwrap();
            out
        })
        .collect();
    (outputs, ctx.shader_cache_stats(), passes)
}

#[test]
fn precompiled_shaders_are_used_only_when_trusted() {
    std::env::remove_var("GPUFX_SHADER_CACHE");
    std::env::remove_var("GPUFX_TRUST_PRECOMPILED");
    // A debug build of wgpu compiles the normal path with -Od, the DXIL is optimized:
    // their floats differ by a few steps.
    std::env::set_var("WGPU_DEBUG", "0");
    if let Err(e) = GpuContext::new(Backend::Dx12) {
        eprintln!("skipping: {e}");
        return;
    }
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../packages/gpufx");
    let mut dirs: Vec<PathBuf> = Vec::new();
    collect_packages(&root, &mut dirs);
    dirs.sort();
    let out = std::env::temp_dir().join(format!("gpufx-precompile-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&out);
    std::fs::create_dir_all(&out).unwrap();
    let mut packages = Vec::new();
    for dir in &dirs {
        let zip = out.join(format!("{}.zip", dir.file_name().unwrap().to_string_lossy()));
        match Package::pack(dir, &zip, true) {
            Ok(n) => assert!(n > 0),
            Err(e) => {
                eprintln!("skipping: {e}");
                return;
            }
        }
        let pkg = Package::open(&zip).unwrap();
        // An Effect runs single-output packages only (the others need an EffectGraph).
        if pkg.manifest.outputs.len() != 1 {
            continue;
        }
        packages.push(pkg);
    }

    let (plain, none, _) = run_all(&packages);
    assert!(none.is_none(), "untrusted blobs need no cache: {none:?}");

    std::env::set_var("GPUFX_TRUST_PRECOMPILED", "1");
    let (trusted, stats, passes) = run_all(&packages);
    std::env::remove_var("GPUFX_TRUST_PRECOMPILED");
    let stats = stats.expect("a cache for the packaged DXIL");
    // Every 8-bit pipeline of every package came from its DXIL: at least one per pass
    // (a pass may build more than one pipeline).
    assert!(stats.precompiled >= passes, "{passes} passes, {stats:?}");
    assert_eq!((stats.loaded, stats.written), (0, 0), "{stats:?}");
    // Packages whose pixels differ, with the largest difference of a channel.
    let differ: Vec<String> = packages
        .iter()
        .zip(trusted.iter().zip(&plain))
        .filter(|(_, (t, p))| t != p)
        .map(|(pkg, (t, p))| {
            let max = t.iter().zip(p.iter()).map(|(a, b)| a.abs_diff(*b)).max().unwrap_or(0);
            let n = t.iter().zip(p.iter()).filter(|(a, b)| a != b).count();
            format!("{} (max {max}, {n}/{} bytes)", pkg.manifest.id, t.len())
        })
        .collect();
    assert!(differ.is_empty(), "{} packages differ: {}", differ.len(), differ.join(", "));
    let _ = std::fs::remove_dir_all(&out);
}

/// Pass groups: only those that may run on D3D12 are precompiled; a package without one
/// has nothing to precompile.
#[test]
fn only_d3d12_groups_are_precompiled() {
    if let Err(e) = GpuContext::new(Backend::Dx12) {
        eprintln!("skipping: {e}");
        return;
    }
    let dir = std::env::temp_dir().join(format!("gpufx-precompile-groups-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("ok.wgsl"),
        "@compute @workgroup_size(8, 8)\nfn main(@builtin(global_invocation_id) id: vec3u) {\n    if (!gpufx_in_bounds(id)) { return; }\n    gpufx_write(id, vec4f(1.0));\n}\n",
    )
    .unwrap();
    std::fs::write(dir.join("bad.wgsl"), "@compute @workgroup_size(8,8) fn main() { let x = undefined_thing; }").unwrap();
    let pack = |groups: &str| {
        std::fs::write(dir.join("manifest.json"), format!(r#"{{"id":"t.g","name":"G","used_for":["gpufx"],"groups":[{groups}]}}"#))
            .unwrap();
        Package::pack(&dir, &dir.with_extension("zip"), true)
    };
    // The vendor of a D3D12 group does not matter; the Metal group is not compiled.
    let n = pack(
        r#"{"requires":{"backend":["metal"]},"passes":[{"shader":"bad.wgsl"}]},{"requires":{"os":["windows"],"backend":["d3d12"],"vendor":["nvidia"]},"passes":[{"shader":"ok.wgsl"}]}"#,
    );
    match n {
        Ok(n) => assert!(n > 0),
        Err(e) => eprintln!("skipping: {e}"),
    }
    // A group needing features the precompile device lacks is skipped, not an error.
    let n =
        pack(r#"{"requires":{"features":["cooperative-matrix-f16"]},"passes":[{"shader":"bad.wgsl"}]},{"passes":[{"shader":"ok.wgsl"}]}"#);
    match n {
        Ok(n) => assert!(n > 0),
        Err(e) => eprintln!("skipping: {e}"),
    }
    assert_eq!(pack(r#"{"requires":{"backend":["vulkan","metal"]},"passes":[{"shader":"bad.wgsl"}]}"#).unwrap(), 0);
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_file(dir.with_extension("zip"));
}
