# gpufx-nn model package

[Tiếng Việt](NN_MODEL_FORMAT-vi.md) · [README](../README.md)

A `gpufx-nn` package is a small inference graph and its weights, run by gpufx's own WGSL compute runtime (no
ncnn, ONNX or other runtime at run time). `gpufx-nnconv` makes it offline from an ncnn model:

```
gpufx-nnconv ncnn --param <model.param> --bin <model.bin> --io <io.json> --used-for <filter>[,<filter>] \
                  [--license <file>] [--readme <file>] [--name <name>] -o <out.zip|out_dir>
```

`-o` ending in `.zip` writes a zip, anything else a directory with the same files. The name defaults to the
output file stem. `--used-for` (required) is written to `used_for` of `model.json`: `gpufx_ai_upscale` for a
`super_resolution` model, `gpufx_ai_framerate` for a `frame_interp` one, `gpufx_ai_matting` for a `matting` one
(checked against the `kind` of `io.json`).
Each `packages/gpufx_ai_*/*/source.json` has its `"used_for"`, which the fetch scripts pass on. Model files are not in git: `scripts/fetch-models.sh` / `scripts/fetch-models.ps1` download the
models listed in `packages/gpufx_ai_*/*/source.json` (pinned URLs, sha256 checked) into `build/packages/<filter>/<name>/` and convert them
to `build/packages/<filter>/<name>.zip`. The matting models have no ncnn release: `scripts/convert-matting-models.py`
downloads their upstream files (pinned in `packages/gpufx_ai_matting/*/source.json`), exports them to ONNX, converts
them with pnnx and then with `gpufx-nnconv` (see "Matting" below); the fetch scripts skip them.

## Package files

| File | Content |
|---|---|
| `model.json` | graph and op parameters (this document), pretty JSON |
| `weights.bin` | all weights, raw (stored, not compressed in the zip) |
| `io.json` | how to feed and read the model (pre/post processing), copied as given, only checked to be JSON |
| `LICENSE` | license of the model, when given |
| `README.md` | description of the model (`--readme <file>`, else a minimal generated one); not read by the runtime |

## weights.bin

Every weight or bias blob is appended as it is in the source (fp16 stays fp16, biases are f32), and starts at a
multiple of 256 bytes (zero padding in between, none after the last). `model.json` points at a blob with
`{"offset": bytes, "count": elements, "dtype": "f16" | "f32"}`; the blob is `count * 2` or `count * 4` bytes,
little endian. The runtime is free to convert fp16 to f32 on upload.

## Tensors

At run time a tensor is `C x H x W`, `f32`, channel planes one after the other (no batch). Tensor names are the
ncnn blob names, unique in the model. `Input` layers become `inputs`; their shapes come from the caller.
`Split` layers are removed: each output of a Split is an alias of its input and every reference is renamed to the
original tensor. `outputs` are the tensors no op reads.

## model.json (version 1)

```json
{ "format": "gpufx-nn", "version": 1, "name": "rife-v4.6", "used_for": ["gpufx_ai_framerate"],
  "source": { "kind": "ncnn" },
  "weights": { "file": "weights.bin" },
  "inputs": [ { "name": "in0" }, { "name": "in1" }, { "name": "in2" } ],
  "outputs": [ "out0" ],
  "ops": [ { "op": "conv2d", "name": "convrelu_0", "inputs": ["18"], "output": "20", "...": "params" } ] }
```

`used_for` (required) lists the FFmpeg filters the model is for: `gpufx_ai_upscale`, `gpufx_ai_framerate`,
`gpufx_ai_matting`. A
missing or empty list, or an unknown name, fails to load. Each filter checks its own name is listed
(`package rife-v4.6 is for gpufx_ai_framerate, not gpufx_ai_upscale`); an effect package given to an AI filter, or
a model given to `gpufx`, fails saying what kind of package it is and which filter takes it. A package converted
before `used_for` existed must be converted again.

Ops are in execution order; every op has `op`, `name` (the ncnn layer name), `inputs`, one `output` and the
parameters of its kind. Unknown ncnn layer types or parameters make the converter fail, never skip.

| op | Parameters | Meaning |
|---|---|---|
| `conv2d` | `in_channels`, `out_channels`, `kernel` [h,w], `stride` [h,w], `dilation` [h,w], `pad` [top,left,bottom,right], `groups` (optional, 1), `activation`, `weight`, `bias` | cross-correlation with zero padding; weight layout `[out][in / groups][kh][kw]` (ncnn native). Output channel `o` reads input channels `[g * in / groups, (g + 1) * in / groups)`, `g = o / (out / groups)`; `groups == in == out` is depthwise. The GPU runs groups 1 and depthwise only (another count fails to load) |
| `deconv2d` | same, plus `output_pad` [h,w] | transposed convolution; weight layout `[out][in][kh][kw]` (ncnn native; PyTorch `ConvTranspose2d` is `[in][out]`), kernel not flipped |
| `activation` | `type` | from ReLU (slope 0 is `relu`, else `leaky_relu`), Sigmoid, HardSigmoid and HardSwish layers |
| `binary` | `kind`, `scalar` | `add sub mul div max min pow rsub rdiv`; one input when `scalar` is set, else two inputs whose dimensions are equal or 1 (a size 1 dimension is repeated, e.g. a `1 x H x W` mask times a `3 x H x W` image). `rsub` is `b - a`, `rdiv` is `b / a` (`b` the scalar or the second input) |
| `eltwise` | `kind` (`prod sum max`), `coeffs` | n inputs; `sum` with `coeffs` is `sum(c_i * x_i)` |
| `concat` | `axis` | along channels (only `0`) |
| `slice` | `axis`, `start`, `end` | channels `[start, end)` (only axis `0`); `end` `null` is to the end |
| `resize` | `mode` (`nearest bilinear bicubic`), `scale` [h,w] or `size` [h,w], `align_corners` | output size is `floor(in * scale)` or `size` |
| `pixel_shuffle` | `factor` | `out[c][y*r+i][x*r+j] = in[c*r*r + i*r + j][y][x]` (PyTorch order) |
| `warp` | `variant` (`rife`) | inputs `[image, flow]`, flow has 2 channels |
| `prelu` | `slope` (f32 blob) | `x >= 0 ? x : slope[c] * x`; `slope.count` is the channel count, or 1 for one shared slope |
| `clip` | `min`, `max` | `clamp(x, min, max)` (ncnn Clip; a missing bound is the f32 limit) |
| `pool` | `kind` (`max avg`), `global`, `kernel` [h,w], `stride` [h,w], `pad` [top,left,bottom,right], `count_include_pad` | `global`: the max or mean of each channel plane, output `C x 1 x 1` (kernel, stride and pad unused). Else a window: output size as a convolution of dilation 1, a window counts only the pixels inside the input (max ignores the padding; average divides by that count, or by `kh * kw` with `count_include_pad`); the padding is smaller than the kernel |
| `instance_norm` | `channels`, `eps`, `gamma`, `beta` | per channel `(x - mean) / sqrt(var + eps)` over its plane (biased variance around the mean), then `* gamma[c] + beta[c]` when both f32 blobs are given (both or neither) |

`activation` of a conv is `null`, `{"type":"relu"}`, `{"type":"leaky_relu","slope":s}`, `{"type":"sigmoid"}`,
`{"type":"clip","min":a,"max":b}`, `{"type":"hard_sigmoid","alpha":a,"beta":b}` or
`{"type":"hard_swish","alpha":a,"beta":b}`, applied after the bias; an `activation` op takes the same types.
`leaky_relu(x) = x >= 0 ? x : s * x`, `hard_sigmoid(x) = clamp(a * x + b, 0, 1)`,
`hard_swish(x) = x * hard_sigmoid(x)` (ncnn HardSigmoid / HardSwish, whose defaults are `a = 0.2`, `b = 0.5`).

The converter also maps ncnn layers that have no op of their own: `ConvolutionDepthWise` and a grouped
`Convolution` are `conv2d` with `groups`; `BatchNorm` is a depthwise 1x1 `conv2d` (weight
`slope / sqrt(var + eps)`, bias `bias - mean * weight`, computed in f64); `InnerProduct` of a `C x 1 x 1` vector
(the output of a global `Pooling` or of another InnerProduct) is a 1x1 `conv2d` (weights `[out][in]`), and a
`Reshape` of such a vector to `w = 1, h = 1` is an alias like `Split`; a `Slice` along the channels with several
outputs becomes one `slice` op per output (`<layer>_<k>`); activation type 3 (clip) and 6 (hard swish) of a
convolution or InnerProduct map to the types above; `4=-233` (SAME padding, as pnnx writes ONNX `auto_pad`) is
taken for stride 1 and an odd kernel span only, where it is the symmetric `(span - 1) / 2`. `Pooling` needs
`pad_mode` 1 (valid, explicit pads) or `global`, and is not adaptive.

### Parameters

A model may declare named run-time parameters, top level, optional:
`"params": { "scale": { "default": 1.0, "min": 0.125, "max": 1.0 } }` (`min` and `max` are optional; so is `values`, the list of the only values allowed, e.g. `"values": [0.25, 0.5, 1.0]`
for a model that is right at those scales only; it must be non-empty, inside `[min, max]` and hold the default). An f32
constant of an op may then be a number or a reference `{"param": "scale", "mul": k, "pow": p}`, whose value is
`k * scale ^ p` (`mul` and `pow` default to 1). References are allowed in `scale` of `resize`, `scalar` of
`binary` and each value of `coeffs` of `eltwise`. A reference to a parameter that is not declared, an unknown key
in it, or a value that is not finite at the default fails to load. The caller gives values by name when it lays
the model out (`NnModel::plan_with`, `FrameInterp::set_params`; `Reference::run_with` in gpufx-nnconv); a
parameter not given takes its default, a name the model does not declare or a value outside `[min, max]` or not in `values` is an
error. A model without `params` runs as before.

For `frame_interp` models the parameter named `scale` has a fixed meaning: the scale the model estimates motion
at (1 full size, 0.5 half). `InterpFrames::set_scale` / `gpufx_ai_interp_set_scale` (the filter option `scale`)
set it, and their auto value (0) picks 0.5 for frames above 1920x1088 pixels in area and 1 otherwise when the
model declares `scale`. `gpufx-nnconv ncnn --rewrite rife-v4-scale` (or `"rewrite": "rife-v4-scale"` in
`source.json`) adds it to the RIFE v4.6 IFNet: every constant that depends on RIFE's `scale` becomes a reference
(`scale_list = [8, 4, 2, 1] / scale`: block `k` resizes its input by `scale / k` = `{"mul": 1/k, "pow": 1}`, its
flow by the same and divides it by `k / scale` = `{"mul": k, "pow": -1}`, then resizes its output and multiplies
the flow by `k / scale`), and the four resize/multiply steps the export leaves out for the last block (`k = 1`)
are inserted as ops that are identities at `scale = 1`. The ops are checked by name, kind and value; another
graph fails to convert. At `scale = 1` the plan is the one of the package converted without the rewrite.

The runtime drops an op that returns its input at the values given: `resize` by `scale` [1, 1] (not by `size`),
`binary` `mul`/`div` by a scalar 1 or `add`/`sub` of a scalar 0, `eltwise` of one input (`sum` with no
coefficient other than 1). Its readers read the input, so a parameter at a neutral value costs no memory and no
dispatch. An op whose output is a model output is kept.

Op semantics:

- **conv2d / deconv2d:** `in_channels = weight.count / (out_channels * kh * kw)`. Deconv output size is
  `(in - 1) * stride - pad_a - pad_b + dilation * (k - 1) + output_pad + 1` per axis. Deconv is the scatter
  `out[o][i*stride + ky*dilation - pad_top][j*stride + kx*dilation - pad_left] += in[q][i][j] * w[o][q][ky][kx]`
  (ncnn `Deconvolution::forward`), plus bias.
- **resize, `align_corners` false:** half-pixel centres, `src = (dst + 0.5) * in / out - 0.5` with the real
  sizes (with `scale` the output size is computed first; the ratio is not `1 / scale`). Bilinear clamps the source to `[0, in - 1]` (a negative source reads pixel 0, a
  source at or past the last pixel reads the last one). `nearest` takes `floor(dst / scale)`, clamped. With
  `align_corners` true, `src = dst * (in - 1) / (out - 1)`. `bicubic` is ncnn's (A = -0.75), unused by RIFE.
- **warp `rife`:** `flow` channel 0 is `fx`, channel 1 is `fy`, in pixels. Each output pixel `(x, y)` of each image
  channel samples `image` at `(x + fx, y + fy)` bilinearly: `x0 = clamp(floor(sx), 0, w-1)`,
  `x1 = clamp(floor(sx) + 1, 0, w-1)`, `alpha = sx - x0` (after clamping, as the ncnn shader does), the same for
  `y`; clamp to edge. Image and flow have the same `H x W`.

`io.json` is for the caller, not the graph. The RIFE one is:

```json
{ "kind": "frame_interp", "family": "rife-v4",
  "inputs": { "frame0": "in0", "frame1": "in1", "timestep": "in2" }, "output": "out0",
  "color": "rgb", "range": [0, 1], "pad_multiple": { "param": "scale", "mul": 32, "pow": -1 },
  "pad_mode": "zero", "output_clamp": [0, 1] }
```

`timestep` is a one-channel plane filled with the time in (0, 1); the frames are padded to a multiple of
`pad_multiple`, run, and the output is cropped and clamped. `pad_multiple` is a number, or (`frame_interp` only)
a reference to a parameter as in the ops, rounded up: a graph that shrinks by `scale / 32` needs sizes that are
multiples of `32 / scale` (32 at scale 1, 64 at 0.5, 128 at 0.25), so the padding grows only when the scale drops.

The Real-ESRGAN ones (`packages/gpufx_ai_upscale/realesr-*/io-x<N>.json`) are:

```json
{ "kind": "super_resolution", "family": "realesr", "inputs": { "image": "data" }, "output": "output",
  "scale": 2, "color": "rgb", "range": [0, 1], "pad_multiple": 1, "pad_mode": "reflect",
  "output_clamp": [0, 1], "tile_pad": 10 }
```

The output is `scale` times the input on each axis. `pad_mode` `reflect` mirrors without repeating the edge pixel
(reflect-101, as ncnn and realesrgan-ncnn-vulkan pad); without `pad_mode` the edge pixel is repeated. `tile_pad` is
the margin in input pixels added around each tile: inside the frame it overlaps the next tile, at the frame border it
is padded with `pad_mode`; its `scale * tile_pad` output pixels are cut.

The gpufx runtime (`FrameUpscale`) runs a frame in tiles sized from the device's storage buffer limits. Its overlap is
the larger of `tile_pad` and the receptive field of the graph (computed from the ops: 19 to 21 pixels for
realesr-animevideov3, 35 for realesr-general-x4v3), so a tiled frame equals the whole frame padded by `tile_pad` (the
reference above) up to float noise; at the frame border a tile ends with that padded frame. It needs `pad_multiple`
1 and a graph whose resizes have a scale, not a size. Convolutions run in f16 where the device has `SHADER_F16`
(about 55 dB against the f32 reference on Real-ESRGAN; f32 matches at 90 dB and more). The f16 path keeps the
convolution sums in f16 (f32 sums cost about 55% more time for ~10 dB), so it assumes activations stay well below
65504, the f16 maximum (inputs above it are clamped): fine for models on [0, 1] images such as Real-ESRGAN; force
`Precision::F32` for a model with large activations.

### Matting

The `matting` models (`packages/gpufx_ai_matting/*/io.json`, run by `FrameMatte`, filter name `gpufx_ai_matting`):

```json
{ "kind": "matting", "family": "modnet", "inputs": { "image": "in0" }, "output": "out0", "color": "rgb",
  "mean": [0.5, 0.5, 0.5], "std": [0.5, 0.5, 0.5],
  "size": { "mode": "short_side", "short_side": 512, "multiple": 32 },
  "matte": { "type": "alpha", "channel": 0 } }
```

- `size` is the model input size for a `w x h` frame. `short_side`: the frame scaled so its short side is
  `short_side`, each side then rounded to the nearest multiple of `multiple` (at least one; default 1), so the
  aspect ratio holds up to that rounding (MODNet: 1920x1080 runs at 896x512). `fixed` with `height` and `width`:
  always that size, the frame stretched (PP-HumanSeg: 256x144).
- The frame is resized to it bilinearly with half-pixel centres, the source clamped to the frame, no antialias
  (the `resize` rule above), as RGB in [0, 1], then `(v - mean) / std` per channel (defaults 0 and 1).
- `matte` turns the output (the model size, any channel count) into one alpha per pixel: `alpha` takes channel
  `channel` as it is, `sigmoid` its sigmoid, `softmax` the softmax over the channels at `channel` (the foreground
  class; PP-HumanSeg's export ends in a Softmax the conversion removes, so the runtime takes it). The result is
  clamped to [0, 1].
- `FrameMatte::draw` resizes the matte bilinearly (half-pixel centres, clamped) into a one-channel texture of any
  size (r8unorm, r16float or r32float): the model size for the raw matte, the frame size to cut the frame out.

The CPU reference of these steps is `gpufx-nnconv frames::matte` (and `frames::resize_matte`).

## Bundles (several scales in one package)

```
gpufx-nnconv bundle --variant <dir>=<pkg.zip|dir> [--variant ...] \n                    [--license <file>] [--readme <file>] [--name <name>] -o <out.zip|out_dir>
```

A bundle holds several variants of one model family, picked at run time by scale. Its root has `package.json`,
`LICENSE` and `README.md` (when given) and one directory per variant holding a normal package (`model.json`,
`weights.bin`, `io.json`):

```json
{ "format": "gpufx-nn-bundle", "version": 1, "name": "realesr-animevideov3", "kind": "super_resolution",
  "variants": [ { "scale": 2, "dir": "x2" }, { "scale": 3, "dir": "x3" }, { "scale": 4, "dir": "x4" } ] }
```

Each variant's `kind` and `scale` are read from its `io.json`; all variants must share the kind and have distinct
scales and simple directory names, and the same `used_for` in their `model.json`.
A package without `package.json` is a single model package (RIFE).
`source.json` of a model may list several variants; the fetch scripts convert each and bundle them.

## Not supported (converter fails)

Quantized weights (tags other than fp16 and f32), grouped deconvolution, `Crop` other than one channel range,
`Concat`, `Crop` and `Slice` on axes other than channels, `PixelShuffle` mode other than 0, fixed deconvolution
output size, SAME padding other than stride 1 with an odd kernel, activation types other than none, relu, leaky
relu, clip, sigmoid and hard swish inside a convolution, `PReLU` parameters other than `num_slope`, `InnerProduct`
or `Reshape` of anything but a `C x 1 x 1` vector, adaptive `Pooling` or a `pad_mode` other than valid,
`Softmax` (`scripts/convert-matting-models.py` removes PP-HumanSeg's), any layer type not in the table.

## Verification

`gpufx-nnconv run-ref` runs a package with the CPU reference executor (`src/reference.rs`, f32). On RIFE v4.6 with
real frames it matches rife-ncnn-vulkan 20221029 (fp16 storage on the GPU) at 60 to 66 dB PSNR, which confirms the
deconvolution layout, the resize rule, `warp` and the op order.

`gpufx-nnconv run-ref --model <pkg> --input <in.png> [--scale N] -o <out.png>` upscales an image with a
`super_resolution` package (`--scale` picks a bundle variant). Against realesrgan-ncnn-vulkan 20220424 the
realesr-animevideov3 x2, x3 and x4 variants match at 58.0, 57.9 and 58.4 dB, realesr-general-x4v3 at 56.2 dB
(that model is not in the ncnn release; compared with the same weights run by ncnn), which confirms `prelu`,
`clip`, bicubic `resize` and the reflect padding.

The matting packages match onnxruntime on their upstream ONNX export within 8e-6 (MODNet at 512x512) and 3e-6
(PP-HumanSeg, after the softmax) on a real portrait, which confirms the depthwise and grouped convolution,
`BatchNorm`, `InstanceNorm`, pooling, `InnerProduct`, hard activations and the downscaling `resize`. On the GPU
(`matting_packages_match_the_cpu_reference` in `crates/gpufx-core/tests/nn.rs`) the f32 alpha is within 1e-5 of
the CPU reference; with f16 convolutions the IoU of the mattes at 0.5 stays above 0.9998.
