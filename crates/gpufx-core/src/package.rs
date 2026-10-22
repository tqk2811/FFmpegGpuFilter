//! Effect packages: a zip (or, for development, a directory) holding `manifest.json`,
//! WGSL shaders and optional PNG textures.

use std::collections::HashMap;
use std::io::Read;
use std::path::Path;

use crate::manifest::Manifest;
use crate::used_for;
use crate::Error;

/// Hard limits so a hostile package cannot exhaust memory.
const MAX_FILES: usize = 1024;
const MAX_TOTAL_BYTES: u64 = 256 << 20;

#[derive(Debug, Clone)]
pub struct Package {
    /// The manifest, with a repeated input expanded to its default count.
    pub manifest: Manifest,
    /// The manifest as written, when it has a repeated input (see [`Package::with_input_count`]).
    template: Option<Box<Manifest>>,
    files: HashMap<String, Vec<u8>>,
}

impl Package {
    /// Opens a `.zip` package or an unpacked package directory.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, Error> {
        let path = path.as_ref();
        let files = if path.is_dir() { read_dir(path)? } else { read_zip(&std::fs::read(path)?)? };
        Self::from_files(files)
    }

    /// Loads a package from zip bytes held in memory.
    pub fn from_zip_bytes(bytes: &[u8]) -> Result<Self, Error> {
        Self::from_files(read_zip(bytes)?)
    }

    fn from_files(files: HashMap<String, Vec<u8>>) -> Result<Self, Error> {
        let Some(manifest_bytes) = files.get("manifest.json") else {
            return Err(used_for::wrong_kind(&files, "manifest.json"));
        };
        let parsed = Manifest::parse(manifest_bytes)?;
        used_for::check(&parsed.id, &parsed.used_for, used_for::GPUFX)?;
        let manifest = parsed.with_input_count(None)?;
        let template = parsed.repeat().is_some().then(|| Box::new(parsed));
        let pkg = Package { manifest, template, files };
        for pass in pkg.manifest.groups.iter().flat_map(|g| &g.passes) {
            pkg.file(&pass.shader)?;
        }
        for tex in &pkg.manifest.textures {
            for f in tex.files() {
                pkg.file(f)?;
            }
        }
        // Image sizes come from the headers: nothing is decoded until a device loads it.
        crate::texture::check_package(&pkg)?;
        Ok(pkg)
    }

    /// The package with its repeated input expanded to `count` inputs (the number of labels a
    /// graph node reads). Fails for a package without one or a count outside its range.
    pub fn with_input_count(&self, count: u32) -> Result<Self, Error> {
        let manifest = match &self.template {
            Some(t) => t.with_input_count(Some(count))?,
            None => self.manifest.with_input_count(Some(count))?,
        };
        Ok(Package { manifest, template: self.template.clone(), files: self.files.clone() })
    }

    /// The package with the passes of manifest group `g` as its passes and no groups
    /// (see [`Manifest::with_group`]).
    pub fn with_group(&self, g: usize) -> Self {
        Package {
            manifest: self.manifest.with_group(g),
            template: self.template.as_ref().map(|t| Box::new(t.with_group(g))),
            files: self.files.clone(),
        }
    }

    /// The name of the repeated input as written (`src` for pads `src0`, `src1`...), if any.
    pub fn repeated_input(&self) -> Option<&str> {
        self.template.as_ref().and_then(|t| t.inputs.last()).map(|i| i.name.as_str())
    }

    /// Number of inputs of the manifest as written, a repeated one counting once.
    pub fn template_inputs(&self) -> usize {
        self.template.as_ref().map_or(self.manifest.inputs.len(), |t| t.inputs.len())
    }

    /// The manifest has a repeated input (see [`Package::with_input_count`]).
    pub fn has_repeated_input(&self) -> bool {
        self.template.is_some()
    }

    pub fn file(&self, path: &str) -> Result<&[u8], Error> {
        self.files
            .get(normalize(path).as_str())
            .map(Vec::as_slice)
            .ok_or_else(|| Error::Package(format!("missing file `{path}` in package")))
    }

    pub fn text(&self, path: &str) -> Result<&str, Error> {
        std::str::from_utf8(self.file(path)?).map_err(|_| Error::Package(format!("`{path}` is not UTF-8")))
    }
}

/// Every file of a `.zip` or a directory, by normalised path, within the package limits; for
/// other kinds of packages (`crate::nn`) that share the zip/directory handling.
pub(crate) fn read_files(path: &Path) -> Result<HashMap<String, Vec<u8>>, Error> {
    if path.is_dir() {
        read_dir(path)
    } else {
        read_zip(&std::fs::read(path)?)
    }
}

fn normalize(path: &str) -> String {
    path.replace('\\', "/").trim_start_matches("./").to_string()
}

fn read_zip(bytes: &[u8]) -> Result<HashMap<String, Vec<u8>>, Error> {
    let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes)).map_err(|e| Error::Package(e.to_string()))?;
    if zip.len() > MAX_FILES {
        return Err(Error::Package("too many files in package".into()));
    }
    let mut files = HashMap::new();
    let mut total = 0u64;
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| Error::Package(e.to_string()))?;
        if entry.is_dir() {
            continue;
        }
        // `enclosed_name` rejects absolute paths and `..` components.
        let name =
            entry.enclosed_name().ok_or_else(|| Error::Package(format!("unsafe path `{}`", String::from_utf8_lossy(entry.name_raw()))))?;
        let name = normalize(&name.to_string_lossy());
        let mut data = Vec::new();
        let budget = MAX_TOTAL_BYTES - total;
        (&mut entry).take(budget + 1).read_to_end(&mut data)?;
        total += data.len() as u64;
        if total > MAX_TOTAL_BYTES {
            return Err(Error::Package("package is too large".into()));
        }
        files.insert(name, data);
    }
    Ok(files)
}

fn read_dir(root: &Path) -> Result<HashMap<String, Vec<u8>>, Error> {
    let mut files = HashMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir)? {
            let path = entry?.path();
            if path.is_dir() {
                stack.push(path);
            } else {
                let rel = path.strip_prefix(root).expect("walked from root");
                files.insert(normalize(&rel.to_string_lossy()), std::fs::read(&path)?);
                if files.len() > MAX_FILES {
                    return Err(Error::Package("too many files in package".into()));
                }
            }
        }
    }
    Ok(files)
}

impl Package {
    /// Zips the package directory `dir` into `out`, after checking it opens. With
    /// `precompile`, the D3D12 shaders of its passes are added under `compiled/dx12/` (see
    /// [`crate::precompile`]); a `compiled/` folder already in `dir` is never copied.
    /// Returns the number of shaders added.
    pub fn pack(dir: &Path, out: &Path, precompile: bool) -> Result<usize, Error> {
        let pkg = Package::open(dir)?;
        let compiled = if precompile { crate::precompile(&pkg)? } else { Vec::new() };
        // The zip being written must not end up inside itself.
        let out_abs = std::path::absolute(out).ok();
        let mut files = Vec::new();
        let mut stack = vec![dir.to_path_buf()];
        while let Some(d) = stack.pop() {
            for entry in std::fs::read_dir(&d)? {
                let entry = entry?;
                let path = entry.path();
                // Symlinks and junctions are not followed: they could pull in files from
                // outside the package, or loop.
                let kind = std::fs::symlink_metadata(&path)?.file_type();
                if kind.is_symlink() {
                    continue;
                }
                if kind.is_dir() {
                    // Stale blobs of another version must not ship.
                    let top_compiled = d == dir && entry.file_name().to_string_lossy().eq_ignore_ascii_case("compiled");
                    if !top_compiled {
                        stack.push(path);
                    }
                } else if kind.is_file() && (out_abs.is_none() || std::path::absolute(&path).ok() != out_abs) {
                    files.push(path);
                }
            }
        }
        files.sort();
        let zip_err = |e: zip::result::ZipError| Error::Package(e.to_string());
        let mut zip = zip::ZipWriter::new(std::fs::File::create(out)?);
        let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        for path in files {
            let rel = normalize(&path.strip_prefix(dir).expect("walked from dir").to_string_lossy());
            zip.start_file(rel, opts).map_err(zip_err)?;
            std::io::Write::write_all(&mut zip, &std::fs::read(&path)?)?;
        }
        for (name, data) in &compiled {
            // DXIL is already compressed.
            zip.start_file(name.as_str(), opts.compression_method(zip::CompressionMethod::Stored)).map_err(zip_err)?;
            std::io::Write::write_all(&mut zip, data)?;
        }
        zip.finish().map_err(zip_err)?;
        Ok(compiled.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str, files: &[(&str, &str)]) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("gpufx-package-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        for (f, text) in files {
            let p = d.join(f);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, text).unwrap();
        }
        d
    }

    const SHADER: (&str, &str) = ("a.wgsl", "fn main() {}");

    #[test]
    fn opens_only_packages_for_gpufx() {
        let m =
            |used_for: &str| format!(r#"{{"id":"t.x","name":"X","used_for":{used_for},"groups":[{{"passes":[{{"shader":"a.wgsl"}}]}}]}}"#);
        let ok = dir("ok", &[("manifest.json", &m(r#"["gpufx"]"#)), SHADER]);
        Package::open(&ok).unwrap();
        let ai = dir("ai", &[("manifest.json", &m(r#"["gpufx_ai_upscale"]"#)), SHADER]);
        let e = Package::open(&ai).unwrap_err().to_string();
        assert_eq!(e, "package: package `t.x` is for gpufx_ai_upscale, not gpufx");
        for d in [ok, ai] {
            let _ = std::fs::remove_dir_all(d);
        }
    }

    /// A model package given to gpufx says what it is and which filter takes it.
    #[test]
    fn a_model_package_names_its_filter() {
        let model = dir("model", &[("model.json", r#"{"format":"gpufx-nn","used_for":["gpufx_ai_framerate"]}"#)]);
        let e = Package::open(&model).unwrap_err().to_string();
        assert!(e.contains("missing manifest.json: it is a gpufx-nn model package, use it with the gpufx_ai_framerate filter"), "{e}");
        let _ = std::fs::remove_dir_all(model);
    }
}
