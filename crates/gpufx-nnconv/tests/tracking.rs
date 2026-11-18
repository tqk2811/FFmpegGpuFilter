//! Golden check of the CPU reference executor on the NanoTrack V2 tracker package against onnxruntime.
//!
//! `scripts/convert-tracking-models.py` writes the package (build/packages/gpufx_ai_tracking/nanotrack-v2.zip)
//! and the golden tensors (build/tracking-golden/nanotrack-v2/). Neither is in git: the test skips without them.

use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use gpufx_nnconv::reference::{Reference, Tensor};

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../build")
}

fn read_f32(path: &Path) -> Vec<f32> {
    std::fs::read(path).unwrap().as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect()
}

fn part(zip: &Path, dir: &str) -> Reference {
    let mut archive = zip::ZipArchive::new(std::fs::File::open(zip).unwrap()).unwrap();
    let mut get = |name: &str| {
        let mut bytes = Vec::new();
        archive.by_name(&format!("{dir}/{name}")).unwrap().read_to_end(&mut bytes).unwrap();
        bytes
    };
    let (model, weights, io) = (get("model.json"), get("weights.bin"), get("io.json"));
    Reference::from_parts(&model, &weights, Some(&io)).unwrap()
}

/// The largest difference relative to the largest magnitude of `want`.
fn rel_error(got: &[f32], want: &[f32]) -> f32 {
    assert_eq!(got.len(), want.len());
    let scale = want.iter().fold(0f32, |m, v| m.max(v.abs())).max(1e-6);
    got.iter().zip(want).fold(0f32, |m, (a, b)| m.max((a - b).abs())) / scale
}

#[test]
fn nanotrack_v2_matches_onnxruntime() {
    let zip = root().join("packages/gpufx_ai_tracking/nanotrack-v2.zip");
    let golden = root().join("tracking-golden/nanotrack-v2");
    if !zip.is_file() || !golden.join("shapes.json").is_file() {
        eprintln!("skipping: run scripts/convert-tracking-models.py first");
        return;
    }
    let shapes: HashMap<String, [usize; 3]> = serde_json::from_slice(&std::fs::read(golden.join("shapes.json")).unwrap()).unwrap();
    let tensor = |name: &str| {
        let [c, h, w] = shapes[name];
        Tensor::new(c, h, w, read_f32(&golden.join(format!("{name}.f32"))))
    };
    let backbone = part(&zip, "backbone");
    let head = part(&zip, "head");
    let features = |picture: Tensor| backbone.run(HashMap::from([("in0".to_string(), picture)])).unwrap().remove("out0").unwrap();
    let zf = features(tensor("template"));
    let xf = features(tensor("search"));
    let (want_zf, want_xf) = (tensor("zf"), tensor("xf"));
    assert_eq!((zf.c, zf.h, zf.w), (want_zf.c, want_zf.h, want_zf.w));
    assert!(rel_error(&zf.data, &want_zf.data) < 1e-4, "template features: {}", rel_error(&zf.data, &want_zf.data));
    assert!(rel_error(&xf.data, &want_xf.data) < 1e-4, "search features: {}", rel_error(&xf.data, &want_xf.data));
    let mut out = head.run(HashMap::from([("in0".to_string(), want_zf), ("in1".to_string(), want_xf)])).unwrap();
    let (cls, loc) = (out.remove("out0").unwrap(), out.remove("out1").unwrap());
    assert_eq!((cls.c, loc.c), (2, 4), "out0 is the class scores, out1 the box sides");
    let (want_cls, want_loc) = (tensor("cls"), tensor("loc"));
    assert!(rel_error(&cls.data, &want_cls.data) < 1e-4, "class scores: {}", rel_error(&cls.data, &want_cls.data));
    assert!(rel_error(&loc.data, &want_loc.data) < 1e-4, "box sides: {}", rel_error(&loc.data, &want_loc.data));
}
