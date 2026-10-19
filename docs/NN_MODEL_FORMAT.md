# gpufx-nn model package

[Tiếng Việt](NN_MODEL_FORMAT-vi.md) · [README](../README.md)

A `gpufx-nn` package is a small inference graph and its weights, run by gpufx's own WGSL compute runtime (no
ncnn, ONNX or other runtime at run time). `gpufx-nnconv` makes it offline from an ncnn model:

```
gpufx-nnconv ncnn --param <model.param> --bin <model.bin> --io <io.json> \
                  [--license <file>] [--readme <file>] [--name <name>] -o <out.zip|out_dir>
```

`-o` ending in `.zip` writes a zip, anything else a directory with the same files. The name defaults to the
output file stem. Model files are not in git: `scripts/fetch-models.sh` / `scripts/fetch-models.ps1` download the
models listed in `models/*/source.json` (pinned URLs, sha256 checked) into `build/models/<name>/` and convert them
to `build/models/<name>.zip`.

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
{ "format": "gpufx-nn", "version": 1, "name": "rife-v4.6",
  "source": { "kind": "ncnn" },
  "weights": { "file": "weights.bin" },
  "inputs": [ { "name": "in0" }, { "name": "in1" }, { "name": "in2" } ],
  "outputs": [ "out0" ],
  "ops": [ { "op": "conv2d", "name": "convrelu_0", "inputs": ["18"], "output": "20", "...": "params" } ] }
```

Ops are in execution order; every op has `op`, `name` (the ncnn layer name), `inputs`, one `output` and the
parameters of its kind. Unknown ncnn layer types or parameters make the converter fail, never skip.

| op | Parameters | Meaning |
|---|---|---|
| `conv2d` | `in_channels`, `out_channels`, `kernel` [h,w], `stride` [h,w], `dilation` [h,w], `pad` [top,left,bottom,right], `activation`, `weight`, `bias` | cross-correlation with zero padding, no groups; weight layout `[out][in][kh][kw]` (ncnn native) |
| `deconv2d` | same, plus `output_pad` [h,w] | transposed convolution; weight layout `[out][in][kh][kw]` (ncnn native; PyTorch `ConvTranspose2d` is `[in][out]`), kernel not flipped |
| `activation` | `type` | from ReLU (slope 0 is `relu`, else `leaky_relu`) and Sigmoid layers |
| `binary` | `kind`, `scalar` | `add sub mul div max min pow rsub rdiv`; one input when `scalar` is set, else two inputs whose dimensions are equal or 1 (a size 1 dimension is repeated, e.g. a `1 x H x W` mask times a `3 x H x W` image). `rsub` is `b - a`, `rdiv` is `b / a` (`b` the scalar or the second input) |
| `eltwise` | `kind` (`prod sum max`), `coeffs` | n inputs; `sum` with `coeffs` is `sum(c_i * x_i)` |
| `concat` | `axis` | along channels (only `0`) |
| `slice` | `axis`, `start`, `end` | channels `[start, end)` (only axis `0`); `end` `null` is to the end |
| `resize` | `mode` (`nearest bilinear bicubic`), `scale` [h,w] or `size` [h,w], `align_corners` | output size is `floor(in * scale)` or `size` |
| `pixel_shuffle` | `factor` | `out[c][y*r+i][x*r+j] = in[c*r*r + i*r + j][y][x]` (PyTorch order) |
| `warp` | `variant` (`rife`) | inputs `[image, flow]`, flow has 2 channels |

`activation` of a conv is `null`, `{"type":"relu"}`, `{"type":"leaky_relu","slope":s}` or `{"type":"sigmoid"}`,
applied after the bias. `leaky_relu(x) = x >= 0 ? x : s * x`.

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
  "color": "rgb", "range": [0, 1], "pad_multiple": 32, "pad_mode": "zero", "output_clamp": [0, 1] }
```

`timestep` is a one-channel plane filled with the time in (0, 1); the frames are padded to a multiple of
`pad_multiple`, run, and the output is cropped and clamped.

## Not supported (converter fails)

Quantized weights (tags other than fp16 and f32), grouped convolution, `Crop` other than one channel range,
`Concat` and `Crop` on axes other than channels, `PixelShuffle` mode other than 0, fixed deconvolution output
size, SAME padding, activation types other than none, relu, leaky relu and sigmoid inside a convolution, any
layer type not in the table.

## Verification

`gpufx-nnconv run-ref` runs a package with the CPU reference executor (`src/reference.rs`, f32). On RIFE v4.6 with
real frames it matches rife-ncnn-vulkan 20221029 (fp16 storage on the GPU) at 60 to 66 dB PSNR, which confirms the
deconvolution layout, the resize rule, `warp` and the op order.
