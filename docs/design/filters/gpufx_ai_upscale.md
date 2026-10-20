Tiếng Việt: [gpufx_ai_upscale-vi.md](gpufx_ai_upscale-vi.md)

# Filter `gpufx_ai_upscale`

Upscales each frame with a neural super resolution model (Real-ESRGAN, converted to a gpufx-nn package) run on the
GPU by libgpufx, on the same GPU frames and devices as `gpufx` (Vulkan, D3D12, D3D11, VideoToolbox). The output is
`scale` times the input on each axis, in the input's pixel format. Source: `ffmpeg/vf_gpufx_ai_upscale.c`.

Each frame is converted to RGBA, upscaled by the model in overlapping tiles (so 1080p and 4K frames fit the GPU's
buffer limits) and converted back. The input frames are only read.

## Syntax

```
gpufx_ai_upscale=model=<path>[:scale=<n>][:tile=<px>][:precision=auto|f32]
```

## Options

| Option | Type | Default | Range/values | Meaning |
|--------|------|---------|--------------|---------|
| `model` | string | (required) | path | Path of a gpufx-nn package or bundle with `io.json` kind `super_resolution`: `models/realesr-animevideov3.zip` (anime, scales 2, 3, 4) or `models/realesr-general-x4v3.zip` (general content, scale 4). The filter fails to start without it. Format: [NN_MODEL_FORMAT.md](../../NN_MODEL_FORMAT.md) |
| `scale` | int | `2` | 1..16 | Output size / input size on each axis. The package must have it; the error lists the scales it has. A frame whose upscaled size is too large is rejected |
| `tile` | int | `0` | 0..16384 | Largest tile side in input pixels. `0` picks the fewest tiles that fit the GPU's buffer limits. Tiles overlap by the model's context, so the result does not depend on the tiling (no seams) |
| `precision` | int (constants) | `auto` | `auto`, `f32` | Arithmetic of the convolutions. `auto`: f16 where the GPU has it (about 57 dB against the f32 reference), else f32. `f32`: f32 everywhere (slower) |

## Input and output

- Input: GPU frames only, from `gpufx_upload` / `hwupload` or a hardware decoder: Vulkan, D3D12, D3D11 or
  VideoToolbox, `sw_format` `nv12`, `p010le`, `rgba` or `rgba64le` (VideoToolbox: `nv12`, `p010le`). Other color
  spaces than BT.601, BT.709 and BT.2020 stop with an error.
- Output: GPU frames of the same format, `scale` times larger, with a frames context of its own (Vulkan: storage
  images, multiplane disabled). Frames pass through 8-bit RGBA (the model's input and output), so 10-bit input
  loses its extra bits and alpha is not kept.
- A size change in the middle of a stream (`-reinit_filter 0`) gives output frames of the new size, with a warning.
- Vulkan: use a device opened with `disable_multiplane=1`, and `gpufx_upload` rather than `hwupload` on Intel
  Windows ([INTEL_VULKAN.md](../../INTEL_VULKAN.md)). The device needs a graphics queue and the input frames must be
  samplable.
- D3D12: the shaders need DXC (`dxcompiler.dll`, shipped in `bin/`), as for `gpufx_ai_framerate`; set
  `GPUFX_SHADER_CACHE` to keep the compiled shaders.

## Timeline and commands

No timeline support and no runtime commands.

## Examples

```sh
# Anime 1080p -> 4K on Vulkan
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_upscale=model=models/realesr-animevideov3.zip:scale=2,gpufx_download,format=nv12" out.mp4

# Live action x4 on D3D12 (Windows)
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,hwupload,gpufx_ai_upscale=model=models/realesr-general-x4v3.zip:scale=4,hwdownload,format=nv12" out.mp4

# Smaller tiles and f32, for a GPU with little memory or to check f16 output
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_upscale=model=models/realesr-animevideov3.zip:scale=2:tile=256:precision=f32,gpufx_download,format=nv12" out.mp4
```

The models are not in git: the win64/linux64 bundles ship them in `models/` (with their licenses), or fetch and
convert them with `scripts/fetch-models.sh` / `scripts/fetch-models.ps1` (written to `build/models/`).

## Limitations

- Not real time: on an RTX 4060 Laptop a 1080p frame at x2 (realesr-animevideov3) takes about 480-510 ms on
  D3D11/D3D12 (f16) and about 690 ms on Vulkan. For offline encodes.
- On the Vulkan device FFmpeg creates, `precision=auto` runs f32: that device does not enable the 16-bit features
  wgpu needs for f16.
- Frames go through 8-bit RGBA: 10-bit input loses its extra bits and alpha is not kept.
- Untested: the VideoToolbox path has never run. Vulkan, D3D12 and D3D11 match the CPU reference in the win64
  bundle (97.5 dB f32, 57.9 dB f16); linux64 was tested on lavapipe only.
- Full list: [LIMITATIONS.md](../../LIMITATIONS.md#super-resolution-gpufx_ai_upscale).

## See also

- [README: Super resolution](../../../README.md#super-resolution-gpufx_ai_upscale)
- [NN_MODEL_FORMAT.md](../../NN_MODEL_FORMAT.md)
- [gpufx_transfer](gpufx_transfer.md), [gpufx_ai_framerate](gpufx_ai_framerate.md)
