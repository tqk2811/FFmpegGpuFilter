#!/usr/bin/env python3
"""Builds the tracker packages of packages/gpufx_ai_tracking/<name>/source.json from their upstream files.

YuNet (`"convert": "yunet"`, the face detector of the automatic face censor) is one model: see build_yunet.
It also needs pillow, and writes build/tracking-golden/<name>/ with a frame of a test picture, its raw outputs
from onnxruntime and the decoded boxes (boxes.json).

NanoTrack is published as two ONNX files (backbone and head). This script downloads the files source.json pins
(sha256 checked), converts each ONNX to ncnn with pnnx (f32 weights), runs gpufx-nnconv on each into a gpufx-nn
model, and zips both with tracker.json, README.md and the upstream LICENSE into
build/packages/gpufx_ai_tracking/<name>.zip:

    tracker.json            crop sizes and box decoding settings (copied from the package folder)
    backbone/model.json     backbone/weights.bin  backbone/io.json
    head/model.json         head/weights.bin      head/io.json
    LICENSE  README.md

It also writes build/tracking-golden/<name>/: a template and a search crop (deterministic test pictures) and
the outputs onnxruntime gives for them with the upstream ONNX files, as raw little-endian f32 (`*.f32`) with
their shapes in shapes.json. The tests of gpufx-nnconv (CPU reference) and gpufx-core (GPU) compare against them.

    py scripts/convert-tracking-models.py                 all models
    py scripts/convert-tracking-models.py nanotrack-v2    chosen models
    py scripts/convert-tracking-models.py --bin <gpufx-nnconv>
    py scripts/convert-tracking-models.py --strict        fail when the ncnn files differ from source.json

Needs Python 3.10 to 3.12 with: onnx, onnxruntime, numpy, pnnx. Tested with pnnx 20261020, onnxruntime 1.23.

source.json of a tracker:
  "used_for", "license_url", "sha256_license"   as the other models
  "convert"      "nanotrack"
  "upstream"     [{"file", "url", "sha256"}]: the ONNX files
  "parts"        {"backbone": {"onnx", "inputshape"}, "head": {...}}: the pnnx input shapes of each part
  "sha256_param", "sha256_bin"   per part, the ncnn files this script made with the tool versions above
  "sha256_zip"   the package zip of the published release (models-tracking-v1); the editor checks downloads
                 against it. Empty until the release exists

source.json of a face detector (convert "yunet"): "upstream" (one ONNX), "cut" {"outputs"} (the ONNX tensors kept as
the model outputs, out0.. in that order), "inputshape" and "inputshape2" (pnnx, two sizes so the resizes take a
scale), "test_picture" {"file", "url", "sha256"} (the picture of the golden), "sha256_param", "sha256_bin" (one
each) and "sha256_zip".
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILTER = "gpufx_ai_tracking"
USER_AGENT = "gpufx-convert-tracking/1.0"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def fetch(url, digest, dest):
    dest = Path(dest)
    if dest.exists() and sha256(dest) == digest:
        print(f"cached: {dest}")
        return dest
    print(f"download: {url}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req) as r, open(part, "wb") as f:
        shutil.copyfileobj(r, f)
    got = sha256(part)
    if got != digest:
        part.unlink()
        raise SystemExit(f"sha256 mismatch for {url}: expected {digest}, got {got}")
    part.replace(dest)
    return dest


def run(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd))
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def pnnx(onnx_path, inputshape, work):
    """ONNX -> ncnn .param/.bin with pnnx, f32 weights. Returns the two paths."""
    exe = shutil.which("pnnx") or str(Path(sys.executable).parent / ("pnnx.exe" if os.name == "nt" else "pnnx"))
    stem = Path(onnx_path).stem
    run([exe, Path(onnx_path).name, f"inputshape={inputshape}", "fp16=0"], cwd=work, stdout=subprocess.DEVNULL)
    return Path(work) / f"{stem}.ncnn.param", Path(work) / f"{stem}.ncnn.bin"


def test_picture(size, phase):
    """A deterministic BGR picture in [0, 255], 3 x size x size: smooth shapes and some texture."""
    import numpy as np

    y, x = np.mgrid[0:size, 0:size].astype(np.float32) / size
    blob = np.exp(-((x - 0.5 - phase) ** 2 + (y - 0.45) ** 2) / 0.02)
    b = 128 + 100 * np.sin(9 * x + 3 * phase) * np.cos(7 * y)
    g = 90 + 150 * blob
    r = 60 + 60 * np.sin(23 * x * y + phase) + 80 * blob
    return np.clip(np.stack([b, g, r]), 0, 255).astype(np.float32)


def golden(up, out):
    import numpy as np
    import onnxruntime as ort

    out.mkdir(parents=True, exist_ok=True)
    opts = ort.SessionOptions()
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    import onnx
    import onnx.utils

    # the published backbone states a 255 x 255 input; the template goes through it at 127 x 127 (as OpenCV runs
    # it), so the spatial sizes are made free
    m = onnx.load(str(up / "nanotrack_backbone_sim.onnx"))
    for d, n in zip(m.graph.input[0].type.tensor_type.shape.dim[2:], ("h", "w")):
        d.dim_param = n
    del m.graph.value_info[:]
    for o in m.graph.output:
        for d in o.type.tensor_type.shape.dim[2:]:
            d.dim_param = "o"
    bb = ort.InferenceSession(m.SerializeToString(), opts, providers=["CPUExecutionProvider"])
    hd = ort.InferenceSession(str(up / "nanotrack_head_sim.onnx"), opts, providers=["CPUExecutionProvider"])
    template = test_picture(127, 0.0)
    search = test_picture(255, 0.08)
    zf = bb.run(None, {"input": template[None]})[0][0]
    xf = bb.run(None, {"input": search[None]})[0][0]
    cls, loc = hd.run(None, {"input1": zf[None], "input2": xf[None]})
    tensors = {"template": template, "search": search, "zf": zf, "xf": xf, "cls": cls[0], "loc": loc[0]}
    for k, v in tensors.items():
        np.ascontiguousarray(v, dtype="<f4").tofile(out / f"{k}.f32")
    shapes = {k: list(v.shape) for k, v in tensors.items()}
    (out / "shapes.json").write_text(json.dumps(shapes, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {out}")


def yunet_decode(maps, io):
    """Face boxes (x, y, w, h, score) in input pixels from the raw output maps, after NMS: the reference of
    `FaceDetector` (gpufx-core) and `decode` there."""
    import numpy as np

    boxes = []
    for head in io["heads"]:
        s = head["stride"]
        cls, obj, bb = maps[head["cls"]][0], maps[head["obj"]][0], maps[head["bbox"]]
        score = np.sqrt(np.clip(1 / (1 + np.exp(-cls)) * (1 / (1 + np.exp(-obj))), 0, 1))
        for r, c in zip(*np.nonzero(score >= io["score_threshold"])):
            cx, cy = (c + bb[0, r, c]) * s, (r + bb[1, r, c]) * s
            w, h = np.exp(bb[2, r, c]) * s, np.exp(bb[3, r, c]) * s
            boxes.append([float(cx - w / 2), float(cy - h / 2), float(w), float(h), float(score[r, c])])
    boxes.sort(key=lambda b: -b[4])

    def iou(a, b):
        ix = max(0.0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
        iy = max(0.0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
        inter = ix * iy
        union = a[2] * a[3] + b[2] * b[3] - inter
        return inter / union if union > 0 else 0.0

    kept = []
    for b in boxes:
        if all(iou(b, k) <= io["nms_threshold"] for k in kept):
            kept.append(b)
    return kept


def build_yunet(name, mdir, src, args):
    """YuNet: one model. The graph is cut before the reshapes of its outputs (the raw maps are decoded by the
    runtime), converted, and zipped with io.json, README.md and LICENSE. The golden is a frame of the test
    picture, its raw maps from onnxruntime and the boxes `yunet_decode` finds in them."""
    import numpy as np
    import onnx
    import onnxruntime as ort
    from PIL import Image

    out_root = ROOT / "build" / "packages" / FILTER
    work = out_root / name
    shutil.rmtree(work / "convert", ignore_errors=True)
    up = work / "upstream"
    for f in src["upstream"]:
        fetch(f["url"], f["sha256"], up / f["file"])
    lic = fetch(src["license_url"], src["sha256_license"], work / "LICENSE")
    pic = src["test_picture"]
    picture = fetch(pic["url"], pic["sha256"], up / pic["file"])
    conv = work / "convert"
    conv.mkdir(parents=True, exist_ok=True)
    m = onnx.load(str(up / src["upstream"][0]["file"]))
    cut = onnx.utils.Extractor(m).extract_model([m.graph.input[0].name], src["cut"]["outputs"])
    # free spatial sizes: pnnx then writes resizes by scale, which run at any frame size
    for d, n in zip(cut.graph.input[0].type.tensor_type.shape.dim[2:], ("h", "w")):
        d.dim_param = n
    del cut.graph.value_info[:]
    for o in cut.graph.output:
        for d in o.type.tensor_type.shape.dim[2:]:
            d.dim_param = "o"
    onnx.save(cut, str(conv / "yunet.onnx"))
    exe = shutil.which("pnnx") or str(Path(sys.executable).parent / ("pnnx.exe" if os.name == "nt" else "pnnx"))
    run([exe, "yunet.onnx", f"inputshape={src['inputshape']}", f"inputshape2={src['inputshape2']}", "fp16=0"],
        cwd=conv, stdout=subprocess.DEVNULL)
    param, binf = conv / "yunet.ncnn.param", conv / "yunet.ncnn.bin"
    for key, f in (("sha256_param", param), ("sha256_bin", binf)):
        want, got = src.get(key), sha256(f)
        if want and want != got:
            msg = f"{name}: {f.name} has sha256 {got}, source.json {key} is {want} (another pnnx version?)"
            if args.strict:
                raise SystemExit(msg)
            print(f"warning: {msg}")
    model = conv / "model"
    conv_args = ["ncnn", "--param", param, "--bin", binf, "--io", mdir / "io.json", "--used-for", ",".join(src["used_for"]),
                 "--name", name, "--license", lic, "--readme", mdir / "README.md", "-o", model]
    if args.bin:
        run([args.bin] + conv_args)
    else:
        run(["cargo", "run", "--release", "--quiet", "--manifest-path", ROOT / "Cargo.toml", "-p", "gpufx-nnconv", "--"] + conv_args)
    zpath = out_root / f"{name}.zip"
    with zipfile.ZipFile(zpath, "w") as z:
        def add(arc, data, compress=True):
            info = zipfile.ZipInfo(arc, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED if compress else zipfile.ZIP_STORED
            z.writestr(info, data)

        for f in ("model.json", "io.json"):
            add(f, (model / f).read_bytes())
        add("weights.bin", (model / "weights.bin").read_bytes(), compress=False)
        add("LICENSE", lic.read_bytes())
        add("README.md", (mdir / "README.md").read_bytes())
    print(f"wrote {zpath} (sha256 {sha256(zpath)})")
    want = src.get("sha256_zip")
    if want and want != sha256(zpath):
        print(f"warning: {zpath.name} differs from sha256_zip of source.json (update it with the release)")

    # golden: the lower right of the test picture (the larger faces) at 640 x 352, a multiple of 32 whose long
    # side is input_size, so the frame is the model input as it is
    io = json.loads((mdir / "io.json").read_text(encoding="utf-8"))
    out = ROOT / "build" / "tracking-golden" / name
    out.mkdir(parents=True, exist_ok=True)
    img = Image.open(picture).convert("RGB")
    w, h = img.size
    box = (w - 998, h - 549, w, h)
    frame = img.crop(box).resize((640, 352), Image.Resampling.BILINEAR)
    rgb = np.asarray(frame, dtype=np.uint8)
    rgba = np.concatenate([rgb, np.full(rgb.shape[:2] + (1,), 255, np.uint8)], axis=2)
    (out / "frame.rgba").write_bytes(rgba.tobytes())
    bgr = rgb[:, :, ::-1].transpose(2, 0, 1).astype(np.float32)
    opts = ort.SessionOptions()
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    sess = ort.InferenceSession(cut.SerializeToString(), opts, providers=["CPUExecutionProvider"])
    names = [o.name for o in sess.get_outputs()]
    res = sess.run(None, {sess.get_inputs()[0].name: bgr[None]})
    # the converted model names its outputs out0..out8 in the order of the cut
    maps = {f"out{i}": res[names.index(o)][0] for i, o in enumerate(src["cut"]["outputs"])}
    tensors = {"input": bgr, **maps}
    for k, v in tensors.items():
        np.ascontiguousarray(v, dtype="<f4").tofile(out / f"{k}.f32")
    shapes = {k: list(v.shape) for k, v in tensors.items()}
    (out / "shapes.json").write_text(json.dumps(shapes, indent=2) + "\n", encoding="utf-8", newline="\n")
    boxes = yunet_decode(maps, io)
    (out / "boxes.json").write_text(json.dumps(boxes, indent=1) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {out} ({len(boxes)} faces)")


def build(name, mdir, args):
    src = json.loads((mdir / "source.json").read_text(encoding="utf-8"))
    if src["convert"] == "yunet":
        return build_yunet(name, mdir, src, args)
    if src["convert"] != "nanotrack":
        raise SystemExit(f"{name}: unknown convert \"{src['convert']}\"")
    out_root = ROOT / "build" / "packages" / FILTER
    work = out_root / name
    shutil.rmtree(work / "convert", ignore_errors=True)
    up = work / "upstream"
    for f in src["upstream"]:
        fetch(f["url"], f["sha256"], up / f["file"])
    lic = fetch(src["license_url"], src["sha256_license"], work / "LICENSE")
    conv = work / "convert"
    conv.mkdir(parents=True, exist_ok=True)
    parts = {}
    for part, spec in src["parts"].items():
        pdir = conv / part
        pdir.mkdir()
        shutil.copy(up / spec["onnx"], pdir / spec["onnx"])
        param, binf = pnnx(pdir / spec["onnx"], spec["inputshape"], pdir)
        for key, f in (("sha256_param", param), ("sha256_bin", binf)):
            want, got = src.get(key, {}).get(part), sha256(f)
            if want and want != got:
                msg = f"{name}/{part}: {f.name} has sha256 {got}, source.json {key} is {want} (another pnnx version?)"
                if args.strict:
                    raise SystemExit(msg)
                print(f"warning: {msg}")
        io = pdir / "io.json"
        io.write_text(json.dumps({"kind": "tracking", "role": part}) + "\n", encoding="utf-8", newline="\n")
        model = pdir / "model"
        conv_args = ["ncnn", "--param", param, "--bin", binf, "--io", io, "--used-for", ",".join(src["used_for"]),
                     "--name", f"{name}-{part}", "--license", lic, "-o", model]
        if args.bin:
            run([args.bin] + conv_args)
        else:
            run(["cargo", "run", "--release", "--quiet", "--manifest-path", ROOT / "Cargo.toml", "-p", "gpufx-nnconv", "--"] + conv_args)
        parts[part] = model
    zpath = out_root / f"{name}.zip"
    # fixed timestamps and order so the same inputs give the same zip
    with zipfile.ZipFile(zpath, "w") as z:
        def add(arc, data, compress=True):
            info = zipfile.ZipInfo(arc, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED if compress else zipfile.ZIP_STORED
            z.writestr(info, data)

        add("tracker.json", (mdir / "tracker.json").read_bytes())
        for part in sorted(parts):
            for f in ("model.json", "io.json"):
                add(f"{part}/{f}", (parts[part] / f).read_bytes())
            add(f"{part}/weights.bin", (parts[part] / "weights.bin").read_bytes(), compress=False)
        add("LICENSE", lic.read_bytes())
        add("README.md", (mdir / "README.md").read_bytes())
    print(f"wrote {zpath} (sha256 {sha256(zpath)})")
    want = src.get("sha256_zip")
    if want and want != sha256(zpath):
        print(f"warning: {zpath.name} differs from sha256_zip of source.json (update it with the release)")
    golden(up, ROOT / "build" / "tracking-golden" / name)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("names", nargs="*")
    ap.add_argument("--bin", default="", help="a built gpufx-nnconv")
    ap.add_argument("--strict", action="store_true", help="fail when the ncnn files differ from sha256_param / sha256_bin")
    args = ap.parse_args()
    base = ROOT / "packages" / FILTER
    dirs = {d.name: d for d in sorted(base.iterdir()) if (d / "source.json").exists()}
    for n in args.names or list(dirs):
        if n not in dirs:
            raise SystemExit(f"{n}: no packages/{FILTER}/{n}/source.json")
        build(n, dirs[n], args)


if __name__ == "__main__":
    main()
