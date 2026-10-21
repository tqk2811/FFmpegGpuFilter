//! A multi-variant bundle: several scale variants of one model family in one package, selected at run
//! time by `scale=`. The zip root holds `package.json`
//! (`{"format":"gpufx-nn-bundle","version":1,"kind":...,"variants":[{"scale":N,"dir":"x2"},...]}`), an
//! optional `LICENSE` and `README.md`, and one directory per variant holding a normal v1 package
//! (`model.json`, `weights.bin`, `io.json`). A package without `package.json` is a single-model package.

use std::io::{Read, Write};
use std::path::Path;

use serde_json::Value;

use crate::{fail, Result};

pub const BUNDLE_FORMAT: &str = "gpufx-nn-bundle";

/// The three files of a v1 package, read from a `.zip` or a directory.
pub struct VariantFiles {
    pub model_json: Vec<u8>,
    pub weights: Vec<u8>,
    pub io_json: Vec<u8>,
}

impl VariantFiles {
    /// Reads `model.json`, `weights.bin` and `io.json` of a package at `path` (`.zip` or directory).
    pub fn load(path: &Path) -> Result<Self> {
        let (model_json, weights, io_json) = if path.is_dir() {
            let read = |n: &str| std::fs::read(path.join(n)).map_err(|e| crate::Error(format!("{}: {e}", path.join(n).display())));
            (read("model.json")?, read("weights.bin")?, read("io.json")?)
        } else {
            let mut zip = zip::ZipArchive::new(std::fs::File::open(path)?)?;
            let mut read = |n: &str| -> Result<Vec<u8>> {
                let mut f = zip.by_name(n).map_err(|_| crate::Error(format!("{}: no {n}", path.display())))?;
                let mut v = Vec::new();
                f.read_to_end(&mut v)?;
                Ok(v)
            };
            (read("model.json")?, read("weights.bin")?, read("io.json")?)
        };
        Ok(VariantFiles { model_json, weights, io_json })
    }

    /// Reads the three package files of variant directory `dir` from a bundle at `path` (`.zip` or dir).
    pub fn load_from_bundle(path: &Path, dir: &str) -> Result<Self> {
        if dir.is_empty() || dir.contains('/') || dir.contains('\\') || dir == "." || dir == ".." {
            return fail(format!("variant directory \"{dir}\" must be a simple name"));
        }
        if path.is_dir() {
            return Self::load(&path.join(dir));
        }
        let mut zip = zip::ZipArchive::new(std::fs::File::open(path)?)?;
        let mut read = |n: &str| -> Result<Vec<u8>> {
            let name = format!("{dir}/{n}");
            let mut f = zip.by_name(&name).map_err(|_| crate::Error(format!("{}: no {name}", path.display())))?;
            let mut v = Vec::new();
            f.read_to_end(&mut v)?;
            Ok(v)
        };
        Ok(VariantFiles { model_json: read("model.json")?, weights: read("weights.bin")?, io_json: read("io.json")? })
    }

    /// The `kind` and `scale` of this variant from its io.json.
    fn kind_and_scale(&self) -> Result<(String, u64)> {
        let io: Value = serde_json::from_slice(&self.io_json).map_err(|e| crate::Error(format!("io.json: {e}")))?;
        let kind = io.get("kind").and_then(Value::as_str).ok_or_else(|| crate::Error("io.json has no string \"kind\"".into()))?;
        let scale = io.get("scale").and_then(Value::as_u64).ok_or_else(|| crate::Error("io.json has no integer \"scale\"".into()))?;
        Ok((kind.to_string(), scale))
    }

    /// `used_for` of this variant's model.json, checked against its kind.
    fn used_for(&self, kind: &str) -> Result<Vec<String>> {
        let m: Value = serde_json::from_slice(&self.model_json).map_err(|e| crate::Error(format!("model.json: {e}")))?;
        let list: Vec<String> = match m.get("used_for") {
            Some(v) => serde_json::from_value(v.clone()).map_err(|e| crate::Error(format!("model.json: used_for: {e}")))?,
            None => return fail("model.json has no used_for: convert the model again with --used-for"),
        };
        crate::package::check_used_for(&list, Some(kind)).map_err(|e| crate::Error(format!("model.json: {}", e.0)))?;
        Ok(list)
    }
}

struct Variant {
    dir: String,
    scale: u64,
    files: VariantFiles,
}

/// A bundle ready to write.
pub struct Bundle {
    kind: String,
    name: String,
    variants: Vec<Variant>,
    license: Option<Vec<u8>>,
    readme: Vec<u8>,
}

impl Bundle {
    /// `inputs` is `(dir, package files)` per variant. All variants must share one kind and have distinct
    /// scales. Without `readme` a minimal one is generated.
    pub fn new(name: &str, inputs: Vec<(String, VariantFiles)>, license: Option<Vec<u8>>, readme: Option<Vec<u8>>) -> Result<Self> {
        if inputs.is_empty() {
            return fail("a bundle needs at least one variant");
        }
        let mut variants = Vec::new();
        let mut kind: Option<String> = None;
        let mut used_for: Option<Vec<String>> = None;
        for (dir, files) in inputs {
            if dir.is_empty() || dir.contains('/') || dir.contains('\\') {
                return fail(format!("variant directory \"{dir}\" must be a simple name"));
            }
            let (k, scale) = files.kind_and_scale()?;
            match &kind {
                Some(existing) if *existing != k => {
                    return fail(format!("variant \"{dir}\" has kind \"{k}\", expected \"{existing}\""));
                }
                None => kind = Some(k.clone()),
                _ => {}
            }
            let u = files.used_for(&k).map_err(|e| crate::Error(format!("variant \"{dir}\": {}", e.0)))?;
            match &used_for {
                Some(existing) if *existing != u => {
                    return fail(format!("variant \"{dir}\" is for {}, expected {}", u.join(", "), existing.join(", ")));
                }
                None => used_for = Some(u),
                _ => {}
            }
            if variants.iter().any(|v: &Variant| v.dir == dir) {
                return fail(format!("duplicate variant directory \"{dir}\""));
            }
            if variants.iter().any(|v: &Variant| v.scale == scale) {
                return fail(format!("duplicate scale {scale}"));
            }
            variants.push(Variant { dir, scale, files });
        }
        variants.sort_by_key(|v| v.scale);
        let kind = kind.expect("at least one variant");
        let readme = readme.unwrap_or_else(|| default_readme(name, &kind, &variants, license.is_some()).into_bytes());
        Ok(Bundle { kind, name: name.to_string(), variants, license, readme })
    }

    fn package_json(&self) -> Vec<u8> {
        let variants: Vec<Value> = self.variants.iter().map(|v| serde_json::json!({ "scale": v.scale, "dir": v.dir })).collect();
        let v = serde_json::json!({
            "format": BUNDLE_FORMAT,
            "version": 1,
            "name": self.name,
            "kind": self.kind,
            "variants": variants,
        });
        let mut s = serde_json::to_vec_pretty(&v).expect("serialize package.json");
        s.push(b'\n');
        s
    }

    /// Writes a zip when `out` ends with `.zip`, a directory otherwise.
    pub fn write(&self, out: &Path) -> Result<()> {
        if out.extension().is_some_and(|e| e.eq_ignore_ascii_case("zip")) {
            self.write_zip(out)
        } else {
            self.write_dir(out)
        }
    }

    fn write_zip(&self, out: &Path) -> Result<()> {
        if let Some(parent) = out.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)?;
        }
        let mut zip = zip::ZipWriter::new(std::fs::File::create(out)?);
        let opts = zip::write::SimpleFileOptions::default();
        let deflate = opts.compression_method(zip::CompressionMethod::Deflated);
        let store = opts.compression_method(zip::CompressionMethod::Stored);
        let pkg = self.package_json();
        zip.start_file("package.json", deflate)?;
        zip.write_all(&pkg)?;
        if let Some(l) = &self.license {
            zip.start_file("LICENSE", deflate)?;
            zip.write_all(l)?;
        }
        zip.start_file("README.md", deflate)?;
        zip.write_all(&self.readme)?;
        for v in &self.variants {
            zip.start_file(format!("{}/model.json", v.dir), deflate)?;
            zip.write_all(&v.files.model_json)?;
            zip.start_file(format!("{}/io.json", v.dir), deflate)?;
            zip.write_all(&v.files.io_json)?;
            // weights.bin is mostly fp16 and read at offsets: not worth compressing.
            zip.start_file(format!("{}/weights.bin", v.dir), store)?;
            zip.write_all(&v.files.weights)?;
        }
        zip.finish()?;
        Ok(())
    }

    fn write_dir(&self, out: &Path) -> Result<()> {
        std::fs::create_dir_all(out)?;
        std::fs::write(out.join("package.json"), self.package_json())?;
        if let Some(l) = &self.license {
            std::fs::write(out.join("LICENSE"), l)?;
        }
        std::fs::write(out.join("README.md"), &self.readme)?;
        for v in &self.variants {
            let dir = out.join(&v.dir);
            std::fs::create_dir_all(&dir)?;
            std::fs::write(dir.join("model.json"), &v.files.model_json)?;
            std::fs::write(dir.join("io.json"), &v.files.io_json)?;
            std::fs::write(dir.join("weights.bin"), &v.files.weights)?;
        }
        Ok(())
    }
}

fn default_readme(name: &str, kind: &str, variants: &[Variant], has_license: bool) -> String {
    let scales: Vec<String> = variants.iter().map(|v| format!("x{}", v.scale)).collect();
    let mut s = format!(
        "# {name}\n\nA gpufx-nn bundle (format {BUNDLE_FORMAT} version 1), kind `{kind}`, with the scale variants \
{scales}. Select one at run time with `scale=`.\n\n## Files\n\n- `package.json`: the bundle manifest\n\
- `<dir>/`: a gpufx-nn package per variant (model.json, weights.bin, io.json)\n",
        scales = scales.join(", "),
    );
    if has_license {
        s.push_str("- `LICENSE`: license of the models; read it before redistributing the package\n");
    }
    s.push_str("\nSee docs/NN_MODEL_FORMAT.md of the gpufx repository for the format.\n");
    s
}

/// `Some(root)` for a bundle zip/dir (reads `package.json`), `None` for a single-model package.
pub fn read_manifest(path: &Path) -> Result<Option<Value>> {
    let bytes = if path.is_dir() {
        match std::fs::read(path.join("package.json")) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        }
    } else {
        let mut zip = zip::ZipArchive::new(std::fs::File::open(path)?)?;
        let mut v = Vec::new();
        match zip.by_name("package.json") {
            Ok(mut f) => {
                f.read_to_end(&mut v)?;
            }
            Err(zip::result::ZipError::FileNotFound) => return Ok(None),
            Err(e) => return Err(e.into()),
        }
        v
    };
    let manifest: Value = serde_json::from_slice(&bytes).map_err(|e| crate::Error(format!("package.json: {e}")))?;
    if manifest.get("format").and_then(Value::as_str) != Some(BUNDLE_FORMAT) {
        return fail("package.json is not a gpufx-nn-bundle manifest");
    }
    Ok(Some(manifest))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::convert_ncnn;
    use crate::package::Package;

    #[test]
    fn rejects_variant_dir_outside_bundle() {
        let root = std::env::temp_dir();
        for dir in ["../x", "..", ".", "", "a/b", "a\\b"] {
            let err = VariantFiles::load_from_bundle(&root, dir).err().expect(dir);
            assert!(err.0.contains("simple name"), "{dir}: {}", err.0);
        }
    }

    fn pkg_dir(dir: &Path, name: &str, scale: u64) {
        let param = "7767517\n2 2\nInput in0 0 1 in0\nConvolution c 1 1 in0 out0 0=1 1=1 6=2\n";
        let mut bin = vec![0u8; 4];
        bin.extend(1.0f32.to_le_bytes());
        bin.extend(2.0f32.to_le_bytes());
        let mut converted = convert_ncnn(param, &bin, name).unwrap();
        converted.model.used_for = vec!["gpufx_ai_upscale".into()];

        let io = format!(r#"{{"kind":"super_resolution","scale":{scale}}}"#);
        Package::new(&converted, io.into_bytes(), None, None).unwrap().write(dir).unwrap();
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("gpufx-nnconv-bundle-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn bundle_round_trip() {
        let root = scratch("roundtrip");
        pkg_dir(&root.join("p2"), "m", 2);
        pkg_dir(&root.join("p4"), "m", 4);
        let inputs = vec![
            ("x4".to_string(), VariantFiles::load(&root.join("p4")).unwrap()),
            ("x2".to_string(), VariantFiles::load(&root.join("p2")).unwrap()),
        ];
        let bundle = Bundle::new("fam", inputs, Some(b"MIT".to_vec()), None).unwrap();
        let out = root.join("b.zip");
        bundle.write(&out).unwrap();

        let manifest = read_manifest(&out).unwrap().unwrap();
        assert_eq!(manifest["format"], BUNDLE_FORMAT);
        assert_eq!(manifest["kind"], "super_resolution");
        let vs = manifest["variants"].as_array().unwrap();
        // sorted by scale
        assert_eq!(vs[0]["scale"], 2);
        assert_eq!(vs[0]["dir"], "x2");
        assert_eq!(vs[1]["scale"], 4);
        assert!(read_manifest(&root.join("p2")).unwrap().is_none());

        let mut zip = zip::ZipArchive::new(std::fs::File::open(&out).unwrap()).unwrap();
        assert!(zip.by_name("x2/model.json").is_ok());
        assert_eq!(zip.by_name("x4/weights.bin").unwrap().compression(), zip::CompressionMethod::Stored);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn rejects_mixed_kind_and_duplicate_scale() {
        let root = scratch("reject");
        pkg_dir(&root.join("p2"), "m", 2);
        pkg_dir(&root.join("p2b"), "m", 2);
        let dup = vec![
            ("x2".to_string(), VariantFiles::load(&root.join("p2")).unwrap()),
            ("x2b".to_string(), VariantFiles::load(&root.join("p2b")).unwrap()),
        ];
        match Bundle::new("f", dup, None, None) {
            Err(e) => assert!(e.0.contains("scale"), "{}", e.0),
            Ok(_) => panic!("duplicate scale should fail"),
        }
        assert!(Bundle::new("f", vec![], None, None).is_err());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn variants_need_one_used_for() {
        let root = scratch("used-for");
        pkg_dir(&root.join("p2"), "m", 2);
        pkg_dir(&root.join("p4"), "m", 4);
        let model = root.join("p4/model.json");
        let mut json: Value = serde_json::from_slice(&std::fs::read(&model).unwrap()).unwrap();
        json["used_for"] = serde_json::json!(["gpufx_ai_upscale", "gpufx_ai_framerate"]);
        std::fs::write(&model, serde_json::to_vec(&json).unwrap()).unwrap();
        let inputs = |root: &Path| {
            vec![
                ("x2".to_string(), VariantFiles::load(&root.join("p2")).unwrap()),
                ("x4".to_string(), VariantFiles::load(&root.join("p4")).unwrap()),
            ]
        };
        let e = Bundle::new("f", inputs(&root), None, None).err().unwrap().0;
        assert!(e.contains("runs frame_interp models"), "{e}");
        json.as_object_mut().unwrap().remove("used_for");
        std::fs::write(&model, serde_json::to_vec(&json).unwrap()).unwrap();
        let e = Bundle::new("f", inputs(&root), None, None).err().unwrap().0;
        assert!(e.contains("variant \"x4\": model.json has no used_for"), "{e}");
        let _ = std::fs::remove_dir_all(&root);
    }
}
