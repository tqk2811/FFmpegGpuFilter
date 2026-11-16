#!/usr/bin/env python3
"""Builds the gpufx-nn packages of packages/gpufx_ai_matting/<name>/source.json from their upstream releases.

The matting models are not published as ncnn files: MODNet is a PyTorch checkpoint and PP-HumanSeg a Paddle
inference model. This script downloads the files source.json pins (sha256 checked), exports each to ONNX,
converts the ONNX to ncnn with pnnx (f32 weights: `fp16=0`, so the package matches the upstream model to float
noise), drops PP-HumanSeg's final Softmax (the runtime takes the softmax when it reads the matte, see
io.json `matte`), and runs gpufx-nnconv into build/packages/gpufx_ai_matting/<name>.zip. It also writes
build/matting-test.png, the portrait the GPU tests compare against the CPU reference.

    py scripts/convert-matting-models.py                         all models
    py scripts/convert-matting-models.py modnet-webcam           chosen models
    py scripts/convert-matting-models.py --paddle-python <exe>   run the Paddle steps with another Python
    py scripts/convert-matting-models.py --bin <gpufx-nnconv>    use a built converter instead of `cargo run`
    py scripts/convert-matting-models.py --strict                fail when the ncnn files differ from source.json

Needs Python 3.10 to 3.12 with: torch (CPU is enough), onnx, pnnx, pillow (MODNet, the test image), and
paddlepaddle 3.1 and paddle2onnx 2.1 (PP-HumanSeg). paddle2onnx can fail to load next to torch or
onnxruntime in one environment ("DLL load failed"); give the Paddle steps their own environment with
--paddle-python. Tested with torch 2.x, pnnx 20261020, paddlepaddle 3.1.1, paddle2onnx 2.1.0.

source.json of a matting model:
  "used_for", "license_url", "sha256_license"   as the other models
  "convert"      "modnet" or "paddleseg"
  "upstream"     [{"file", "url", "sha256"}]: the files to download (for MODNet the checkpoint and the four
                 pinned source files of its ONNX export; for PP-HumanSeg the inference model zip)
  "export"       {"height", "width"}: the input size of the export (MODNet's graph runs at any multiple of 32
                 after it; PP-HumanSeg's is fixed)
  "sha256_param", "sha256_bin"   the ncnn files this script made with the tool versions above; another
                 version may write other bytes (a warning, an error with --strict)
  "sha256_zip"   the package zip of the published release (models-matting-v1); the editor checks
                 downloads against it. Update it with the release when the zip is rebuilt
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
FILTER = "gpufx_ai_matting"
# A public domain portrait (NASA, Wikimedia Commons "File:Yvonne_Cagle.jpg") for the GPU tests.
TEST_IMAGE_URL = "https://upload.wikimedia.org/wikipedia/commons/a/a0/Yvonne_Cagle.jpg"
TEST_IMAGE_SHA256 = "a34fa7dd444a4d14b70a37eb11928c310e9a3b7c87f285a99b4644fef2773a99"
USER_AGENT = "gpufx-convert-matting/1.0"


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


def pnnx(onnx_path, shape, work):
    """ONNX -> ncnn .param/.bin with pnnx, f32 weights. Returns the two paths."""
    exe = shutil.which("pnnx") or str(Path(sys.executable).parent / ("pnnx.exe" if os.name == "nt" else "pnnx"))
    stem = Path(onnx_path).stem
    run([exe, Path(onnx_path).name, f"inputshape=[1,3,{shape[0]},{shape[1]}]", "fp16=0"], cwd=work, stdout=subprocess.DEVNULL)
    return Path(work) / f"{stem}.ncnn.param", Path(work) / f"{stem}.ncnn.bin"


def strip_softmax(src, dst):
    """Drops the one Softmax layer of an ncnn .param; the layer feeding it then writes the Softmax's output."""
    lines = Path(src).read_text(encoding="utf-8").splitlines()
    head, counts, layers = lines[0], lines[1].split(), lines[2:]
    soft = [i for i, l in enumerate(layers) if l.split()[0] == "Softmax"]
    if len(soft) != 1:
        raise SystemExit(f"{src}: expected one Softmax layer, found {len(soft)}")
    f = layers[soft[0]].split()
    inp, out = f[4], f[5]
    del layers[soft[0]]
    fixed = []
    for l in layers:
        t = l.split()
        n_in, n_out = int(t[2]), int(t[3])
        if inp in t[4:4 + n_in]:
            raise SystemExit(f"{src}: the Softmax input is read by another layer")
        outs = t[4 + n_in:4 + n_in + n_out]
        if inp in outs:
            t[4 + n_in + outs.index(inp)] = out
            l = " ".join(t)
        fixed.append(l)
    counts[0] = str(int(counts[0]) - 1)
    counts[1] = str(int(counts[1]) - 1)
    Path(dst).write_text("\n".join([head, " ".join(counts)] + fixed) + "\n", encoding="utf-8", newline="\n")


# ---- stages run in a subprocess (their own interpreter and imports) ----

def stage_modnet_onnx(src_dir, ckpt, out, h, w):
    sys.path.insert(0, src_dir)
    import torch
    import modnet_onnx  # the pinned upstream onnx/modnet_onnx.py

    m = modnet_onnx.MODNet(backbone_pretrained=False)
    sd = torch.load(ckpt, map_location="cpu", weights_only=True)
    m.load_state_dict({k[7:] if k.startswith("module.") else k: v for k, v in sd.items()})
    m.eval()
    x = torch.zeros(1, 3, int(h), int(w))
    torch.onnx.export(m, x, out, input_names=["input"], output_names=["output"], opset_version=11, dynamo=False)


def stage_paddle_onnx(model_dir, out, h, w):
    """Fixes the input shape of a Paddle inference model (paddle2onnx needs it for adaptive pooling), then
    exports ONNX."""
    os.environ["FLAGS_enable_pir_api"] = "0"
    import paddle

    paddle.enable_static()
    exe = paddle.static.Executor(paddle.CPUPlace())
    prog, feeds, fetches = paddle.static.load_inference_model(os.path.join(model_dir, "model"), exe)
    blk = prog.global_block()
    for n in feeds:
        blk.var(n).desc.set_shape([1, 3, int(h), int(w)])
    for op in blk.ops:
        if op.type not in ("feed", "fetch"):
            op.desc.infer_shape(blk.desc)
    fixed = os.path.join(os.path.dirname(out), "static")
    paddle.static.save_inference_model(os.path.join(fixed, "model"), [blk.var(n) for n in feeds], fetches, exe, program=prog)
    import paddle2onnx

    paddle2onnx.export(os.path.join(fixed, "model.pdmodel"), os.path.join(fixed, "model.pdiparams"), out, opset_version=11)


# ---- per model ----

def build(name, mdir, args):
    src = json.loads((mdir / "source.json").read_text(encoding="utf-8"))
    out_root = ROOT / "build" / "packages" / FILTER
    work = out_root / name
    if work.exists():
        shutil.rmtree(work / "convert", ignore_errors=True)
    up = work / "upstream"
    for f in src["upstream"]:
        fetch(f["url"], f["sha256"], up / f["file"])
    conv = work / "convert"
    conv.mkdir(parents=True, exist_ok=True)
    h, w = src["export"]["height"], src["export"]["width"]
    me = Path(__file__).resolve()
    if src["convert"] == "modnet":
        # the upstream export code expects src/models/backbones next to it
        code = conv / "code"
        for f in src["upstream"]:
            if f["file"].endswith(".py"):
                (code / f["file"]).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(up / f["file"], code / f["file"])
        ckpt = next(up / f["file"] for f in src["upstream"] if f["file"].endswith(".ckpt"))
        onnx = conv / "model.onnx"
        run([args.python, "-I", me, "--stage", "modnet-onnx", code, ckpt, onnx, h, w])
        param, binf = pnnx(onnx, (h, w), conv)
    elif src["convert"] == "paddleseg":
        z = next(up / f["file"] for f in src["upstream"] if f["file"].endswith(".zip"))
        with zipfile.ZipFile(z) as zf:
            members = [m for m in zf.namelist() if not m.startswith("__MACOSX") and m.endswith(("model.pdmodel", "model.pdiparams"))]
            if len(members) != 2:
                raise SystemExit(f"{z}: no model.pdmodel / model.pdiparams")
            pd = conv / "paddle"
            pd.mkdir(exist_ok=True)
            for m in members:
                (pd / Path(m).name).write_bytes(zf.read(m))
        onnx = conv / "model.onnx"
        run([args.paddle_python, "-I", me, "--stage", "paddle-onnx", pd, onnx, h, w])
        param, binf = pnnx(onnx, (h, w), conv)
        stripped = conv / "model.nosoftmax.param"
        strip_softmax(param, stripped)
        param = stripped
    else:
        raise SystemExit(f"{name}: unknown convert \"{src['convert']}\"")
    for key, f in (("sha256_param", param), ("sha256_bin", binf)):
        want, got = src.get(key), sha256(f)
        if want and want != got:
            msg = f"{name}: {f.name} has sha256 {got}, source.json {key} is {want} (another pnnx or exporter version?)"
            if args.strict:
                raise SystemExit(msg)
            print(f"warning: {msg}")
    lic = None
    if src.get("license_url"):
        lic = fetch(src["license_url"], src["sha256_license"], work / "LICENSE")
    conv_args = ["ncnn", "--param", param, "--bin", binf, "--io", mdir / "io.json", "--used-for", ",".join(src["used_for"]),
                 "--name", name, "--readme", mdir / "README.md", "-o", out_root / f"{name}.zip"]
    if lic:
        conv_args += ["--license", lic]
    if args.bin:
        run([args.bin] + conv_args)
    else:
        run(["cargo", "run", "--release", "--quiet", "--manifest-path", ROOT / "Cargo.toml", "-p", "gpufx-nnconv", "--"] + conv_args)


def test_image():
    from PIL import Image

    jpg = fetch(TEST_IMAGE_URL, TEST_IMAGE_SHA256, ROOT / "build" / "matting-test.jpg")
    Image.open(jpg).convert("RGB").save(ROOT / "build" / "matting-test.png")
    print(f"wrote {ROOT / 'build' / 'matting-test.png'}")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--stage":
        stage, rest = sys.argv[2], sys.argv[3:]
        {"modnet-onnx": stage_modnet_onnx, "paddle-onnx": stage_paddle_onnx}[stage](*rest)
        return
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("names", nargs="*")
    ap.add_argument("--python", default=sys.executable, help="Python with torch (MODNet export)")
    ap.add_argument("--paddle-python", default=sys.executable, help="Python with paddlepaddle and paddle2onnx")
    ap.add_argument("--bin", default="", help="a built gpufx-nnconv")
    ap.add_argument("--strict", action="store_true", help="fail when the ncnn files differ from sha256_param / sha256_bin")
    args = ap.parse_args()
    base = ROOT / "packages" / FILTER
    dirs = {d.name: d for d in sorted(base.iterdir()) if (d / "source.json").exists()}
    for n in args.names or list(dirs):
        if n not in dirs:
            raise SystemExit(f"{n}: no packages/{FILTER}/{n}/source.json")
        build(n, dirs[n], args)
    test_image()


if __name__ == "__main__":
    main()
