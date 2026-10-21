//! Manifest pass groups: the group matching the device is the one that runs.
//! Tests that need a device are skipped when none can be created.

mod common;

use std::path::PathBuf;

use gpufx_core::{Effect, FrameInfo, GpuContext, Image, ImageMut, Package};

/// Writes one solid color.
fn solid(r: f32, g: f32, b: f32) -> String {
    format!(
        "@compute @workgroup_size(8, 8)\nfn main(@builtin(global_invocation_id) id: vec3u) {{\n    if (!gpufx_in_bounds(id)) {{ return; }}\n    gpufx_write(id, vec4f({r:?}, {g:?}, {b:?}, 1.0));\n}}\n"
    )
}

/// A package in a temporary directory with the shaders `red.wgsl`, `green.wgsl`,
/// `blue.wgsl` and `bad.wgsl` (which does not compile); removed on drop.
struct TempPackage(PathBuf);

impl TempPackage {
    fn new(tag: &str, manifest: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("gpufx-groups-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("manifest.json"), manifest).unwrap();
        std::fs::write(dir.join("red.wgsl"), solid(1.0, 0.0, 0.0)).unwrap();
        std::fs::write(dir.join("green.wgsl"), solid(0.0, 1.0, 0.0)).unwrap();
        std::fs::write(dir.join("blue.wgsl"), solid(0.0, 0.0, 1.0)).unwrap();
        std::fs::write(dir.join("bad.wgsl"), "@compute @workgroup_size(8,8) fn main() { let x = undefined_thing; }").unwrap();
        TempPackage(dir)
    }

    fn open(&self) -> Package {
        Package::open(&self.0).unwrap()
    }
}

impl Drop for TempPackage {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).ok();
    }
}

fn manifest(groups: &str) -> String {
    format!(r#"{{"id":"t.groups","name":"Groups","groups":[{groups}]}}"#)
}

fn gpu() -> Option<std::sync::Arc<GpuContext>> {
    static CTX: std::sync::OnceLock<Option<std::sync::Arc<GpuContext>>> = std::sync::OnceLock::new();
    CTX.get_or_init(|| match GpuContext::new(common::backend()) {
        Ok(ctx) => Some(ctx),
        Err(e) => {
            eprintln!("skipping: {e}");
            None
        }
    })
    .clone()
}

/// The first pixel `pkg` writes on `ctx`.
fn first_pixel(ctx: &std::sync::Arc<GpuContext>, pkg: Package) -> [u8; 4] {
    let mut fx = Effect::new(ctx.clone(), pkg).unwrap();
    let (w, h) = (8, 8);
    let src = vec![0u8; (w * h * 4) as usize];
    let mut out = vec![0u8; (w * h * 4) as usize];
    let image = [Image { data: &src, width: w, height: h, stride: w * 4 }];
    fx.process(&image, ImageMut { data: &mut out, width: w, height: h, stride: w * 4 }, &FrameInfo::new(0.0, 0)).unwrap();
    out[..4].try_into().unwrap()
}

/// A backend other than the device's, for groups that must not match.
fn other_backend(this: &str) -> &'static str {
    if this == "metal" {
        "vulkan"
    } else {
        "metal"
    }
}

#[test]
fn the_group_of_this_backend_runs() {
    let Some(ctx) = gpu() else { return };
    let this = ctx.target().backend_name().expect("a real backend");
    let other = other_backend(this);
    let pkg = TempPackage::new(
        "match",
        &manifest(&format!(
            r#"{{"name":"other","requires":{{"backend":["{other}"]}},"passes":[{{"shader":"bad.wgsl"}}]}},
               {{"name":"this","requires":{{"backend":["{this}"]}},"passes":[{{"shader":"red.wgsl","output":"x"}},{{"shader":"green.wgsl","inputs":["x"]}}]}},
               {{"passes":[{{"shader":"blue.wgsl"}}]}}"#
        )),
    );
    assert_eq!(first_pixel(&ctx, pkg.open()), [0, 255, 0, 255]);
    // The program keeps the chosen group as its passes.
    let fx = Effect::new(ctx.clone(), pkg.open()).unwrap();
    let m = &fx.package().manifest;
    assert!(m.groups.is_empty());
    assert_eq!(m.passes.len(), 2);
}

#[test]
fn the_fallback_group_runs_when_the_others_do_not_match() {
    let Some(ctx) = gpu() else { return };
    let other = other_backend(ctx.target().backend_name().expect("a real backend"));
    let pkg = TempPackage::new(
        "fallback",
        &manifest(&format!(
            r#"{{"requires":{{"backend":["{other}"]}},"passes":[{{"shader":"red.wgsl"}}]}},{{"name":"generic","requires":{{"backend":"*"}},"passes":[{{"shader":"blue.wgsl"}}]}}"#
        )),
    );
    assert_eq!(first_pixel(&ctx, pkg.open()), [0, 0, 255, 255]);
}

#[test]
fn no_matching_group_is_an_error_naming_each_group() {
    let Some(ctx) = gpu() else { return };
    let other = other_backend(ctx.target().backend_name().expect("a real backend"));
    let pkg = TempPackage::new(
        "nomatch",
        &manifest(&format!(r#"{{"name":"only","requires":{{"backend":["{other}"]}},"passes":[{{"shader":"red.wgsl"}}]}}"#)),
    );
    let err = Effect::new(ctx.clone(), pkg.open()).err().expect("must fail").to_string();
    assert!(err.contains("effect `Groups`: no group matches this device"), "{err}");
    assert!(err.contains(&format!("only: needs backend {other}")), "{err}");
}

#[test]
fn plain_passes_still_run() {
    let Some(ctx) = gpu() else { return };
    let pkg = TempPackage::new("plain", r#"{"id":"t.plain","name":"Plain","passes":[{"shader":"red.wgsl"}]}"#);
    assert_eq!(first_pixel(&ctx, pkg.open()), [255, 0, 0, 255]);
}

#[test]
fn the_noop_device_checks_every_group_of_this_os() {
    let ctx = match GpuContext::noop() {
        Ok(ctx) => ctx,
        Err(e) => return eprintln!("skipping: {e}"),
    };
    let os = gpufx_core::requires::Target::current_os();
    let other_os = if os == "linux" { "windows" } else { "linux" };
    // Backends are not known yet: both groups of this OS are compiled, the first kept.
    let ok = TempPackage::new(
        "noop-ok",
        &manifest(&format!(
            r#"{{"requires":{{"backend":["metal"]}},"passes":[{{"shader":"red.wgsl"}}]}},{{"requires":{{"os":["{other_os}"]}},"passes":[{{"shader":"bad.wgsl"}}]}},{{"requires":{{"backend":["vulkan"]}},"passes":[{{"shader":"green.wgsl"}}]}}"#
        )),
    );
    let fx = Effect::new(ctx.clone(), ok.open()).unwrap();
    assert_eq!(fx.package().manifest.passes[0].shader, "red.wgsl");
    // A broken shader in any group of this OS fails.
    let bad = TempPackage::new(
        "noop-bad",
        &manifest(
            r#"{"requires":{"backend":["metal"]},"passes":[{"shader":"red.wgsl"}]},{"requires":{"backend":["vulkan"]},"passes":[{"shader":"bad.wgsl"}]}"#,
        ),
    );
    assert!(Effect::new(ctx.clone(), bad.open()).is_err());
    // No group for this OS.
    let none =
        TempPackage::new("noop-none", &manifest(&format!(r#"{{"requires":{{"os":["{other_os}"]}},"passes":[{{"shader":"red.wgsl"}}]}}"#)));
    let err = Effect::new(ctx, none.open()).err().expect("must fail").to_string();
    assert!(err.contains(&format!("no group matches this OS ({os})")), "{err}");
}

#[test]
fn the_noop_device_skips_groups_needing_features_it_lacks() {
    let ctx = match GpuContext::noop() {
        Ok(ctx) => ctx,
        Err(e) => return eprintln!("skipping: {e}"),
    };
    // The cooperative matrix group comes first but cannot be checked on the noop device.
    let pkg = TempPackage::new(
        "noop-coop",
        &manifest(
            r#"{"requires":{"features":["cooperative-matrix","cooperative-matrix-f16"]},"passes":[{"shader":"bad.wgsl"}]},{"passes":[{"shader":"green.wgsl"}]}"#,
        ),
    );
    let fx = Effect::new(ctx.clone(), pkg.open()).unwrap();
    assert_eq!(fx.package().manifest.passes[0].shader, "green.wgsl");
    // Only such groups: nothing can be checked.
    let only = TempPackage::new(
        "noop-only-coop",
        &manifest(r#"{"requires":{"features":["cooperative-matrix-f16"]},"passes":[{"shader":"red.wgsl"}]}"#),
    );
    let err = Effect::new(ctx, only.open()).err().expect("must fail").to_string();
    assert!(err.contains("every group needs features the device is not known to have yet (cooperative-matrix-f16)"), "{err}");
}

#[test]
fn shader_files_of_every_group_must_exist() {
    let dir = TempPackage::new("missing", &manifest(r#"{"passes":[{"shader":"red.wgsl"}]},{"passes":[{"shader":"nope.wgsl"}]}"#));
    let err = Package::open(&dir.0).unwrap_err().to_string();
    assert!(err.contains("missing file `nope.wgsl`"), "{err}");
}
