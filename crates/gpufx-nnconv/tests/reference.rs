//! Golden check of the CPU reference executor on the real RIFE v4.6 package.
//!
//! GPUFX_RIFE_PKG is the package (zip or directory). GPUFX_RIFE_TESTDIR holds, per case `X`, the frames
//! `X_0.png` and `X_2.png`, the true middle frame `X_1.png` and the output of rife-ncnn-vulkan `X_ncnn.png`
//! (`-m rife-v4.6 -s 0.5` on the same two frames). The frames are not in git.

use std::path::{Path, PathBuf};

use gpufx_nnconv::frames::{interpolate, load_png, psnr};
use gpufx_nnconv::reference::Reference;

#[test]
#[ignore = "needs GPUFX_RIFE_PKG and GPUFX_RIFE_TESTDIR"]
fn rife_v46_matches_ncnn() {
    let pkg = std::env::var("GPUFX_RIFE_PKG").expect("GPUFX_RIFE_PKG");
    let dir = PathBuf::from(std::env::var("GPUFX_RIFE_TESTDIR").expect("GPUFX_RIFE_TESTDIR"));
    let model = Reference::load(Path::new(&pkg)).unwrap();
    let mut cases = 0;
    for case in ["A", "B"] {
        let f0 = dir.join(format!("{case}_0.png"));
        if !f0.exists() {
            continue;
        }
        let load = |n: &str| load_png(&dir.join(format!("{case}_{n}.png"))).unwrap();
        let ours = interpolate(&model, &load("0"), &load("2"), 0.5).unwrap();
        let vs_ncnn = psnr(&ours, &load("ncnn")).unwrap();
        let vs_truth = psnr(&ours, &load("1")).unwrap();
        println!("{case}: ours vs ncnn {vs_ncnn:.2} dB, ours vs truth {vs_truth:.2} dB");
        assert!(vs_ncnn > 45.0, "{case}: {vs_ncnn} dB against ncnn");
        assert!(vs_truth > 25.0, "{case}: {vs_truth} dB against the real middle frame");
        cases += 1;
    }
    assert!(cases > 0, "no test case found in {}", dir.display());
}
