# Package model gpufx-nn

[English](NN_MODEL_FORMAT.md) · [README](../README-vi.md)

Package `gpufx-nn` là một graph inference nhỏ kèm weights, chạy bằng runtime compute WGSL của gpufx (lúc chạy
không cần ncnn, ONNX hay runtime nào khác). `gpufx-nnconv` tạo nó offline từ model ncnn:

```
gpufx-nnconv ncnn --param <model.param> --bin <model.bin> --io <io.json> --used-for <filter>[,<filter>] \
                  [--license <file>] [--readme <file>] [--name <name>] -o <out.zip|out_dir>
```

`-o` kết thúc bằng `.zip` thì ghi zip, còn lại ghi thư mục có cùng các file. Mặc định tên model là tên file output
(bỏ đuôi). `--used-for` (bắt buộc) được ghi vào `used_for` của `model.json`: `gpufx_ai_upscale` cho model
`super_resolution`, `gpufx_ai_framerate` cho model `frame_interp` (đối chiếu với `kind` của `io.json`). Mỗi
`packages/gpufx_ai_*/*/source.json` có `"used_for"` riêng, script fetch truyền tiếp cho converter. File model không nằm trong git: `scripts/fetch-models.sh` / `scripts/fetch-models.ps1` tải các model
liệt kê trong `packages/gpufx_ai_*/*/source.json` (URL ghim commit, kiểm sha256) vào `build/packages/<filter>/<name>/` rồi convert thành
`build/packages/<filter>/<name>.zip`.

## File trong package

| File | Nội dung |
|---|---|
| `model.json` | graph và tham số các op (tài liệu này), JSON pretty |
| `weights.bin` | toàn bộ weights, dữ liệu thô (trong zip lưu stored, không nén) |
| `io.json` | cách đưa vào và đọc ra của model (pre/post processing), copy nguyên văn, chỉ kiểm là JSON hợp lệ |
| `LICENSE` | license của model, nếu có |
| `README.md` | mô tả model (`--readme <file>`, nếu không có thì sinh bản tối giản); runtime không đọc |

## weights.bin

Mỗi blob weight hoặc bias được nối vào đúng như nguồn (fp16 giữ fp16, bias là f32) và bắt đầu tại bội số của 256
byte (đệm số 0 ở giữa, không đệm sau blob cuối). `model.json` trỏ tới blob bằng
`{"offset": byte, "count": số phần tử, "dtype": "f16" | "f32"}`; blob dài `count * 2` hoặc `count * 4` byte,
little endian. Runtime tự do đổi fp16 sang f32 lúc upload.

## Tensor

Lúc chạy một tensor là `C x H x W`, `f32`, các plane channel nối tiếp nhau (không có batch). Tên tensor là tên blob
của ncnn, duy nhất trong model. Layer `Input` thành `inputs`; kích thước do caller quyết định. Layer `Split` bị
bỏ: mỗi output của Split là alias của input và mọi tham chiếu được đổi tên về tensor gốc. `outputs` là các tensor
không op nào đọc.

## model.json (version 1)

```json
{ "format": "gpufx-nn", "version": 1, "name": "rife-v4.6", "used_for": ["gpufx_ai_framerate"],
  "source": { "kind": "ncnn" },
  "weights": { "file": "weights.bin" },
  "inputs": [ { "name": "in0" }, { "name": "in1" }, { "name": "in2" } ],
  "outputs": [ "out0" ],
  "ops": [ { "op": "conv2d", "name": "convrelu_0", "inputs": ["18"], "output": "20", "...": "params" } ] }
```

`used_for` (bắt buộc) liệt kê các filter FFmpeg dùng model: `gpufx_ai_upscale`, `gpufx_ai_framerate`. Thiếu, mảng
rỗng hoặc tên lạ thì không load được. Mỗi filter kiểm tên của chính nó có trong danh sách
(`package rife-v4.6 is for gpufx_ai_framerate, not gpufx_ai_upscale`); đưa package effect cho filter AI, hoặc model
cho `gpufx`, thì lỗi nói rõ đó là loại package gì và filter nào dùng được. Package convert từ trước khi có
`used_for` phải convert lại.

Các op theo thứ tự thực thi; mỗi op có `op`, `name` (tên layer ncnn), `inputs`, một `output` và tham số theo loại.
Layer hoặc tham số ncnn lạ thì converter báo lỗi, không bỏ qua.

| op | Tham số | Ý nghĩa |
|---|---|---|
| `conv2d` | `in_channels`, `out_channels`, `kernel` [h,w], `stride` [h,w], `dilation` [h,w], `pad` [top,left,bottom,right], `activation`, `weight`, `bias` | cross-correlation, pad bằng 0, không group; layout weight `[out][in][kh][kw]` (ncnn native) |
| `deconv2d` | như trên, thêm `output_pad` [h,w] | transposed convolution; layout weight `[out][in][kh][kw]` (ncnn native; `ConvTranspose2d` của PyTorch là `[in][out]`), kernel không lật |
| `activation` | `type` | từ layer ReLU (slope 0 là `relu`, khác 0 là `leaky_relu`) và Sigmoid |
| `binary` | `kind`, `scalar` | `add sub mul div max min pow rsub rdiv`; có `scalar` thì 1 input, không thì 2 input có từng chiều bằng nhau hoặc bằng 1 (chiều kích thước 1 được lặp lại, vd mask `1 x H x W` nhân ảnh `3 x H x W`). `rsub` là `b - a`, `rdiv` là `b / a` (`b` là scalar hoặc input thứ hai) |
| `eltwise` | `kind` (`prod sum max`), `coeffs` | n input; `sum` có `coeffs` là `sum(c_i * x_i)` |
| `concat` | `axis` | theo channel (chỉ `0`) |
| `slice` | `axis`, `start`, `end` | channel `[start, end)` (chỉ axis `0`); `end` là `null` nghĩa là tới cuối |
| `resize` | `mode` (`nearest bilinear bicubic`), `scale` [h,w] hoặc `size` [h,w], `align_corners` | kích thước ra là `floor(in * scale)` hoặc `size` |
| `pixel_shuffle` | `factor` | `out[c][y*r+i][x*r+j] = in[c*r*r + i*r + j][y][x]` (thứ tự PyTorch) |
| `warp` | `variant` (`rife`) | input `[image, flow]`, flow có 2 channel |
| `prelu` | `slope` (blob f32) | `x >= 0 ? x : slope[c] * x`; `slope.count` là số channel, hoặc 1 khi mọi channel dùng chung một slope |
| `clip` | `min`, `max` | `clamp(x, min, max)` (Clip của ncnn; thiếu cận nào thì lấy giới hạn của f32) |

`activation` của conv là `null`, `{"type":"relu"}`, `{"type":"leaky_relu","slope":s}` hoặc `{"type":"sigmoid"}`,
áp sau khi cộng bias. `leaky_relu(x) = x >= 0 ? x : s * x`.

Ngữ nghĩa các op:

- **conv2d / deconv2d:** `in_channels = weight.count / (out_channels * kh * kw)`. Kích thước ra của deconv theo
  mỗi trục là `(in - 1) * stride - pad_a - pad_b + dilation * (k - 1) + output_pad + 1`. Deconv là phép scatter
  `out[o][i*stride + ky*dilation - pad_top][j*stride + kx*dilation - pad_left] += in[q][i][j] * w[o][q][ky][kx]`
  (theo `Deconvolution::forward` của ncnn), cộng bias.
- **resize, `align_corners` false:** tâm pixel half-pixel, `src = (dst + 0.5) * in / out - 0.5` với kích thước
  thật (có `scale` thì tính kích thước ra trước; tỉ lệ không phải `1 / scale`). Bilinear kẹp source vào `[0, in - 1]` (source âm đọc pixel 0, source từ pixel
  cuối trở đi đọc pixel cuối). `nearest` lấy `floor(dst / scale)`, có kẹp. `align_corners` true thì
  `src = dst * (in - 1) / (out - 1)`. `bicubic` theo ncnn (A = -0.75), RIFE không dùng.
- **warp `rife`:** channel 0 của `flow` là `fx`, channel 1 là `fy`, đơn vị pixel. Mỗi pixel ra `(x, y)` của từng
  channel ảnh lấy mẫu `image` tại `(x + fx, y + fy)` kiểu bilinear: `x0 = clamp(floor(sx), 0, w-1)`,
  `x1 = clamp(floor(sx) + 1, 0, w-1)`, `alpha = sx - x0` (tính sau khi kẹp, đúng như shader của ncnn), `y` làm
  tương tự; clamp-to-edge. Ảnh và flow cùng `H x W`.

`io.json` dành cho caller, không thuộc graph. Bản của RIFE:

```json
{ "kind": "frame_interp", "family": "rife-v4",
  "inputs": { "frame0": "in0", "frame1": "in1", "timestep": "in2" }, "output": "out0",
  "color": "rgb", "range": [0, 1], "pad_multiple": 32, "pad_mode": "zero", "output_clamp": [0, 1] }
```

`timestep` là plane một channel điền giá trị thời gian trong (0, 1); frame được pad lên bội số của
`pad_multiple`, chạy, rồi output được crop và clamp.

Bản của Real-ESRGAN (`packages/gpufx_ai_upscale/realesr-*/io-x<N>.json`):

```json
{ "kind": "super_resolution", "family": "realesr", "inputs": { "image": "data" }, "output": "output",
  "scale": 2, "color": "rgb", "range": [0, 1], "pad_multiple": 1, "pad_mode": "reflect",
  "output_clamp": [0, 1], "tile_pad": 10 }
```

Output lớn gấp `scale` lần input theo mỗi trục. `pad_mode` `reflect` lấy đối xứng không lặp pixel viền
(reflect-101, giống cách ncnn và realesrgan-ncnn-vulkan pad); không có `pad_mode` thì lặp pixel viền. `tile_pad` là
phần lề (tính theo pixel input) thêm quanh mỗi tile: trong frame thì chồng lên tile bên cạnh, ở viền frame thì pad
theo `pad_mode`; `scale * tile_pad` pixel output tương ứng bị cắt bỏ.

Runtime gpufx (`FrameUpscale`) chạy frame theo tile, kích thước tile chọn theo giới hạn storage buffer của thiết bị.
Phần overlap là số lớn hơn giữa `tile_pad` và receptive field của graph (tính từ các op: 19 đến 21 pixel với
realesr-animevideov3, 35 với realesr-general-x4v3), nên frame chạy theo tile bằng frame chạy nguyên khối pad
`tile_pad` (bản tham chiếu ở trên) tới mức nhiễu float; ở viền frame tile kết thúc đúng chỗ frame đã pad kết thúc.
Runtime cần `pad_multiple` 1 và mọi resize trong graph có `scale`, không phải `size`. Convolution chạy f16 khi
thiết bị có `SHADER_F16` (khoảng 55 dB so với tham chiếu f32 trên Real-ESRGAN; f32 khớp từ 90 dB trở lên). Đường
f16 cộng dồn tổng convolution bằng f16 (cộng dồn f32 chậm hơn khoảng 55% để được thêm ~10 dB), nên giả định
activation luôn nhỏ hơn nhiều so với 65504, giá trị lớn nhất của f16 (input vượt ngưỡng bị clamp): ổn với model
chạy trên ảnh [0, 1] như Real-ESRGAN; model có activation lớn thì ép `Precision::F32`.

## Bundle (nhiều scale trong một package)

```
gpufx-nnconv bundle --variant <dir>=<pkg.zip|dir> [--variant ...] \n                    [--license <file>] [--readme <file>] [--name <name>] -o <out.zip|out_dir>
```

Bundle chứa nhiều biến thể của cùng một họ model, lúc chạy chọn theo scale. Thư mục gốc có `package.json`,
`LICENSE` và `README.md` (nếu có) và mỗi biến thể một thư mục chứa package thường (`model.json`, `weights.bin`,
`io.json`):

```json
{ "format": "gpufx-nn-bundle", "version": 1, "name": "realesr-animevideov3", "kind": "super_resolution",
  "variants": [ { "scale": 2, "dir": "x2" }, { "scale": 3, "dir": "x3" }, { "scale": 4, "dir": "x4" } ] }
```

`kind` và `scale` của từng biến thể đọc từ `io.json` của nó; mọi biến thể phải cùng kind, cùng `used_for` trong
`model.json`, khác scale và tên thư mục là tên đơn. Package không có `package.json` là package một model (RIFE).
`source.json` của model có thể liệt kê nhiều biến thể; script fetch convert từng cái rồi gộp thành bundle.

## Chưa hỗ trợ (converter báo lỗi)

Weights quantized (tag khác fp16 và f32), grouped convolution, `Crop` khác một khoảng channel, `Concat` và `Crop`
theo trục khác channel, `PixelShuffle` mode khác 0, output size cố định của deconvolution, padding SAME, activation
trong convolution ngoài none/relu/leaky relu/sigmoid, tham số `PReLU` ngoài `num_slope`, mọi loại layer không có
trong bảng.

## Đối chiếu

`gpufx-nnconv run-ref` chạy package bằng bộ thực thi tham chiếu CPU (`src/reference.rs`, f32). Với RIFE v4.6 trên
khung hình thật, kết quả khớp rife-ncnn-vulkan 20221029 (GPU lưu fp16) ở 60 đến 66 dB PSNR, xác nhận layout
deconvolution, quy tắc resize, `warp` và thứ tự op.

`gpufx-nnconv run-ref --model <pkg> --input <in.png> [--scale N] -o <out.png>` upscale một ảnh bằng package
`super_resolution` (`--scale` chọn biến thể của bundle). So với realesrgan-ncnn-vulkan 20220424, các biến thể x2,
x3, x4 của realesr-animevideov3 khớp ở 58.0, 57.9 và 58.4 dB, realesr-general-x4v3 ở 56.2 dB (model này không có
trong bản release ncnn; so với cùng weights chạy bằng ncnn), xác nhận `prelu`, `clip`, `resize` bicubic và cách pad
reflect.
