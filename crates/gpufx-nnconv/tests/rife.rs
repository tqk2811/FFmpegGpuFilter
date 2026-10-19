//! Converts the real RIFE model when GPUFX_RIFE_NCNN_DIR points at a directory with flownet.param and flownet.bin.

use gpufx_nnconv::convert_ncnn;

#[test]
#[ignore = "needs GPUFX_RIFE_NCNN_DIR with flownet.param and flownet.bin"]
fn converts_rife_v46() {
    let dir = std::env::var("GPUFX_RIFE_NCNN_DIR").expect("GPUFX_RIFE_NCNN_DIR");
    let param = std::fs::read_to_string(format!("{dir}/flownet.param")).unwrap();
    let bin = std::fs::read(format!("{dir}/flownet.bin")).unwrap();
    let c = convert_ncnn(&param, &bin, "rife-v4.6").unwrap();
    let v = serde_json::to_value(&c.model).unwrap();

    let count = |kind: &str| v["ops"].as_array().unwrap().iter().filter(|o| o["op"] == kind).count();
    assert_eq!(count("conv2d"), 40);
    assert_eq!(count("deconv2d"), 4);
    assert_eq!(count("warp"), 8);
    assert_eq!(count("resize"), 8);
    assert_eq!(count("binary"), 43);
    assert_eq!(count("concat"), 7);
    assert_eq!(count("slice"), 16);
    assert_eq!(count("pixel_shuffle"), 4);
    assert_eq!(count("eltwise"), 2);
    assert_eq!(count("activation"), 33);
    assert_eq!(v["ops"].as_array().unwrap().len(), 165);
    assert!(!param.contains("Split") || v["ops"].as_array().unwrap().iter().all(|o| o["op"] != "split"));
    assert_eq!(v["inputs"].as_array().unwrap().len(), 3);
    assert_eq!(v["outputs"], serde_json::json!(["out0"]));

    // Blobs are fp16 weights plus f32 biases: a little under the source size, with 256 byte alignment.
    assert!(c.weights.len() > 10_000_000 && c.weights.len() < bin.len() + 165 * 256);
    for o in v["ops"].as_array().unwrap() {
        for key in ["weight", "bias"] {
            if let Some(offset) = o[key]["offset"].as_u64() {
                assert_eq!(offset % 256, 0);
            }
        }
    }
}
