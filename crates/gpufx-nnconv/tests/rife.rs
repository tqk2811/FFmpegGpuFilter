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

#[test]
#[ignore = "needs GPUFX_RIFE_NCNN_DIR with flownet.param and flownet.bin"]
fn rife_v4_scale_rewrite_binds_every_scale_constant() {
    let dir = std::env::var("GPUFX_RIFE_NCNN_DIR").expect("GPUFX_RIFE_NCNN_DIR");
    let param = std::fs::read_to_string(format!("{dir}/flownet.param")).unwrap();
    let bin = std::fs::read(format!("{dir}/flownet.bin")).unwrap();
    let mut c = convert_ncnn(&param, &bin, "rife-v4.6").unwrap();
    gpufx_nnconv::rife::apply(&mut c.model, "rife-v4-scale").unwrap();
    let v = serde_json::to_value(&c.model).unwrap();
    assert_eq!(v["params"], serde_json::json!({"scale": {"default": 1.0, "min": 0.25, "max": 1.0, "values": [0.25, 0.5, 1.0]}}));

    let ops = v["ops"].as_array().unwrap();
    assert_eq!(ops.len(), 170, "5 ops inserted for block 3");
    let p = |mul: f32, pow: f32| serde_json::json!({"param": "scale", "mul": mul, "pow": pow});
    let op = |name: &str| ops.iter().find(|o| o["name"] == name).unwrap_or_else(|| panic!("{name}"));
    let pos = |name: &str| ops.iter().position(|o| o["name"] == name).unwrap();
    // (op, field, expected): block i shrinks by s/k, enlarges by k/s, scales flow by k/s
    for (name, k, pow) in [
        ("upsample_9", 0.125, 1.0),
        ("upsample_10", 8.0, -1.0),
        ("upsample_11", 0.25, 1.0),
        ("upsample_12", 0.25, 1.0),
        ("upsample_13", 4.0, -1.0),
        ("upsample_14", 0.5, 1.0),
        ("upsample_15", 0.5, 1.0),
        ("upsample_16", 2.0, -1.0),
        ("scale3_x_resize", 1.0, 1.0),
        ("scale3_flow_resize", 1.0, 1.0),
        ("scale3_tmp_resize", 1.0, -1.0),
    ] {
        assert_eq!(op(name)["scale"], serde_json::json!([p(k, pow), p(k, pow)]), "{name}");
    }
    for (name, kind, k, pow) in [
        ("mul_16", "mul", 8.0, -1.0),
        ("div_17", "div", 4.0, -1.0),
        ("div_37", "div", 2.0, -1.0),
        ("scale3_flow_mul", "mul", 1.0, 1.0),
        ("scale3_flow_out_mul", "mul", 1.0, -1.0),
    ] {
        assert_eq!((op(name)["kind"].as_str().unwrap(), &op(name)["scalar"]), (kind, &p(k, pow)), "{name}");
    }
    assert_eq!(op("weighted_sum_0")["coeffs"], serde_json::json!([1.0, p(4.0, -1.0)]));
    assert_eq!(op("weighted_sum_1")["coeffs"], serde_json::json!([1.0, p(2.0, -1.0)]));
    let binds = ops.iter().filter(|o| o.to_string().contains("\"param\":\"scale\"")).count();
    assert_eq!(binds, 18);

    // block 3 wiring: x and flow shrink before cat_12; the block output grows before its two slices, and only
    // the flow slice is scaled (the mask slice is not)
    assert_eq!(op("cat_12")["inputs"], serde_json::json!(["scale3_x", "scale3_flow"]));
    assert_eq!(op("scale3_flow_mul")["inputs"], serde_json::json!(["scale3_flow_rs"]));
    assert_eq!(op("scale3_x_resize")["inputs"], serde_json::json!([op("cat_11")["output"]]));
    assert_eq!(op("scale3_flow_resize")["inputs"], serde_json::json!([op("weighted_sum_1")["output"]]));
    assert_eq!(op("scale3_tmp_resize")["inputs"], serde_json::json!(["flow3"]));
    assert_eq!(op("slice_120")["inputs"], serde_json::json!(["scale3_tmp"]));
    assert_eq!(op("slice_121")["inputs"], serde_json::json!(["scale3_tmp"]));
    assert_eq!(op("scale3_flow_out_mul")["inputs"], serde_json::json!([op("slice_120")["output"]]));
    assert!(op("add_73")["inputs"].as_array().unwrap().contains(&serde_json::json!("scale3_flow_out")));
    assert!(pos("scale3_flow_mul") < pos("cat_12") && pos("pixelshuffle_107") < pos("scale3_tmp_resize"));
    assert!(pos("scale3_tmp_resize") < pos("slice_120") && pos("scale3_flow_out_mul") < pos("add_73"));
}

#[test]
fn rife_v4_scale_rewrite_rejects_another_graph() {
    let param = "7767517\n2 2\nInput in0 0 1 in0\nInterp upsample_9 1 1 in0 out0 0=1 1=2.0 2=2.0\n";
    let mut c = convert_ncnn(param, &[], "x").unwrap();
    let e = gpufx_nnconv::rife::apply(&mut c.model, "rife-v4-scale").unwrap_err().0;
    assert!(e.contains("upsample_9") && e.contains("not a RIFE v4.6 IFNet"), "{e}");
    assert!(gpufx_nnconv::rife::apply(&mut c.model, "nope").unwrap_err().0.contains("unknown rewrite"));
}
