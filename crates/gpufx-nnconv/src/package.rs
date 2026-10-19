//! The `gpufx-nn` package: model.json, weights.bin, io.json, README.md and an optional LICENSE.

use std::io::Write;
use std::path::Path;

use crate::convert::Converted;
use crate::{fail, Result};

pub struct Package {
    pub model_json: Vec<u8>,
    pub weights: Vec<u8>,
    pub io_json: Vec<u8>,
    pub license: Option<Vec<u8>>,
    pub readme: Vec<u8>,
}

impl Package {
    /// `io_json` is stored as given after checking that it is JSON. `readme` is stored as given; without it
    /// a minimal README.md is generated from the model name, source and license.
    pub fn new(converted: &Converted, io_json: Vec<u8>, license: Option<Vec<u8>>, readme: Option<Vec<u8>>) -> Result<Self> {
        if let Err(e) = serde_json::from_slice::<serde_json::Value>(&io_json) {
            return fail(format!("io.json is not valid JSON: {e}"));
        }
        let mut model_json = serde_json::to_vec_pretty(&converted.model)?;
        model_json.push(b'\n');
        let readme = readme.unwrap_or_else(|| default_readme(converted, license.is_some()).into_bytes());
        Ok(Package { model_json, weights: converted.weights.clone(), io_json, license, readme })
    }

    fn files(&self) -> Vec<(&'static str, &[u8], bool)> {
        let mut files = vec![("model.json", &self.model_json[..], true), ("io.json", &self.io_json[..], true)];
        if let Some(l) = &self.license {
            files.push(("LICENSE", &l[..], true));
        }
        files.push(("README.md", &self.readme[..], true));
        files.push(("weights.bin", &self.weights[..], false));
        files
    }

    /// Writes a zip when `out` ends with `.zip`, a directory otherwise.
    pub fn write(&self, out: &Path) -> Result<()> {
        if out.extension().is_some_and(|e| e.eq_ignore_ascii_case("zip")) {
            self.write_zip(out)
        } else {
            self.write_dir(out)
        }
    }

    pub fn write_zip(&self, out: &Path) -> Result<()> {
        if let Some(parent) = out.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)?;
        }
        let mut zip = zip::ZipWriter::new(std::fs::File::create(out)?);
        let opts = zip::write::SimpleFileOptions::default();
        for (name, data, compress) in self.files() {
            // weights.bin is mostly fp16 and read at offsets: not worth compressing.
            let method = if compress { zip::CompressionMethod::Deflated } else { zip::CompressionMethod::Stored };
            zip.start_file(name, opts.compression_method(method))?;
            zip.write_all(data)?;
        }
        zip.finish()?;
        Ok(())
    }

    pub fn write_dir(&self, out: &Path) -> Result<()> {
        std::fs::create_dir_all(out)?;
        for (name, data, _) in self.files() {
            std::fs::write(out.join(name), data)?;
        }
        Ok(())
    }
}

/// Minimal README.md for a package converted without `--readme`.
fn default_readme(converted: &Converted, has_license: bool) -> String {
    let model = &converted.model;
    let mut s = format!(
        "# {name}

A gpufx-nn package (format version {version}), converted from {source} by gpufx-nnconv.

\n         ## Files

\n         - `model.json`: graph and op parameters
\n         - `weights.bin`: weights
\n         - `io.json`: how the model is fed and read
",
        name = model.name,
        version = model.version,
        source = model.source.kind,
    );
    if has_license {
        s.push_str(
            "- `LICENSE`: license of the model; read it before redistributing the package
",
        );
    }
    s.push_str(
        "
See docs/NN_MODEL_FORMAT.md of the gpufx repository for the format.
",
    );
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::convert_ncnn;
    use std::io::Read;

    fn converted() -> Converted {
        let param = "7767517\n2 2\nInput in0 0 1 in0\nConvolution c 1 1 in0 out0 0=1 1=1 6=2\n";
        let mut bin = vec![0u8; 4];
        bin.extend(1.0f32.to_le_bytes());
        bin.extend(2.0f32.to_le_bytes());
        convert_ncnn(param, &bin, "t").unwrap()
    }

    fn package() -> Package {
        Package::new(
            &converted(),
            br#"{"kind":"x"}"#.to_vec(),
            Some(b"MIT".to_vec()),
            Some(
                b"# custom
"
                .to_vec(),
            ),
        )
        .unwrap()
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("gpufx-nnconv-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn zip_layout() {
        let dir = scratch("zip");
        let out = dir.join("m.zip");
        package().write(&out).unwrap();
        let mut zip = zip::ZipArchive::new(std::fs::File::open(&out).unwrap()).unwrap();
        let names: Vec<String> = (0..zip.len()).map(|i| zip.by_index(i).unwrap().name().unwrap().to_string()).collect();
        assert_eq!(names, ["model.json", "io.json", "LICENSE", "README.md", "weights.bin"]);
        assert_eq!(zip.by_name("weights.bin").unwrap().compression(), zip::CompressionMethod::Stored);
        assert_eq!(zip.by_name("model.json").unwrap().compression(), zip::CompressionMethod::Deflated);
        let mut readme = String::new();
        zip.by_name("README.md").unwrap().read_to_string(&mut readme).unwrap();
        assert_eq!(
            readme,
            "# custom
"
        );
        let mut io = String::new();
        zip.by_name("io.json").unwrap().read_to_string(&mut io).unwrap();
        assert_eq!(io, r#"{"kind":"x"}"#);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generated_readme_without_option() {
        let dir = scratch("readme");
        let pkg = Package::new(&converted(), b"{}".to_vec(), Some(b"MIT".to_vec()), None).unwrap();
        pkg.write(&dir.join("pkg")).unwrap();
        let readme = std::fs::read_to_string(dir.join("pkg/README.md")).unwrap();
        assert!(
            readme.starts_with(
                "# t
"
            ),
            "{readme}"
        );
        assert!(readme.contains("ncnn") && readme.contains("LICENSE"), "{readme}");
        let no_license = Package::new(&converted(), b"{}".to_vec(), None, None).unwrap();
        assert!(!String::from_utf8(no_license.readme).unwrap().contains("LICENSE"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn directory_layout_and_bad_io() {
        let dir = scratch("dir");
        package().write(&dir.join("pkg")).unwrap();
        assert_eq!(std::fs::read(dir.join("pkg/weights.bin")).unwrap().len(), 8);
        assert!(dir.join("pkg/model.json").exists());
        let converted = converted();
        assert!(Package::new(&converted, b"{".to_vec(), None, None).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
