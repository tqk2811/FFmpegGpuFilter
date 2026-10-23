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
| `model` | string | (required) | path | Path of a gpufx-nn package or bundle with `io.json` kind `super_resolution`: `packages/gpufx_ai_upscale/realesr-animevideov3.zip` (anime, scales 2, 3, 4) or `packages/gpufx_ai_upscale/realesr-general-x4v3.zip` (general content, scale 4). The filter fails to start without it. Format: [NN_MODEL_FORMAT.md](../../NN_MODEL_FORMAT.md) |
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

## Use cases & examples

**Model (`model`).** Pick by content: `realesr-animevideov3.zip` for anime and cartoons (scales 2, 3, 4),
`realesr-general-x4v3.zip` for live action and other general content (scale 4 only). Other `super_resolution`
gpufx-nn packages work too; the filter does not start without `model`.

```sh
# Anime 1080p -> 4K on Vulkan
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_upscale=model=packages/gpufx_ai_upscale/realesr-animevideov3.zip:scale=2,gpufx_download,format=nv12" out.mp4

# Live action x4 on D3D12 (Windows); the general model only has scale 4
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,hwupload,gpufx_ai_upscale=model=packages/gpufx_ai_upscale/realesr-general-x4v3.zip:scale=4,hwdownload,format=nv12" out.mp4
```

**`scale`.** Use it for the output size: 2 for 1080p to 4K, 4 for small sources. Ask for a scale the package does not
have and the filter stops with an error listing the scales it has. A size change mid-stream needs
`-reinit_filter 0` and the output frames follow the new size.

**`tile` and `precision`.** Use `tile` on a GPU with little memory (or to bound memory use on 4K input): smaller tiles
use less memory, the result does not depend on the tiling. Leave `0` otherwise. Use `precision=f32` to check
the f16 output of `auto` or when f16 shows artefacts; it is slower.

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_upscale=model=packages/gpufx_ai_upscale/realesr-animevideov3.zip:scale=2:tile=256:precision=f32,gpufx_download,format=nv12" out.mp4
```

**Vulkan, D3D12, D3D11.** The filter takes the GPU frames of the device it runs on. Vulkan was the fastest in the
measurements (see Limitations); it needs `disable_multiplane=1`, and `gpufx_upload` on Intel Windows. D3D12 and D3D11
use `hwupload` / `hwdownload`, and D3D12 needs DXC for the shaders. The D3D11 form of the D3D12 command above is the
same with a `d3d11va` device (`-init_hw_device d3d11va=dx -filter_hw_device dx`); the test bundle exercises the
filter on D3D11, and this exact command line is not in it, but it ran on an RTX 4060 Laptop.

**Chain with `gpufx` (stay on the GPU).** Upscale first, then effects at the new size, with one upload and one
download for the whole chain:

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_upscale=model=packages/gpufx_ai_upscale/realesr-animevideov3.zip:scale=2,gpufx=graph=sepia.zip,gpufx_download,format=nv12" out.mp4
```

**Encode on the GPU without a download.** The output is GPU frames, so a GPU encoder that accepts that frame type
could take them directly (no `gpufx_download` / `hwdownload`). The test bundle does not cover this for this filter,
so check the Vulkan case on your setup: the Vulkan output is storage images with multiplane disabled, and whether a given Vulkan
encoder takes them is unverified. With a D3D12 device and a D3D12 encoder the form is below (run on an RTX 4060 Laptop; `-bf 0` because NVIDIA's D3D12 encoder fails on B-frames):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,hwupload,gpufx_ai_upscale=model=packages/gpufx_ai_upscale/realesr-animevideov3.zip:scale=2" -c:v h264_d3d12va -bf 0 out.mp4
```

The models are not in git: the release asset `gpufx-packages.zip` ships them in `gpufx_ai_upscale/` (with their licenses; the ffmpeg bundles do not), or fetch and
convert them with `scripts/fetch-models.sh` / `scripts/fetch-models.ps1` (written to `build/packages/<filter>/`).

## Limitations

- Not real time: on an RTX 4060 Laptop a 1080p frame at x2 (realesr-animevideov3) takes about 480-510 ms on
  D3D11/D3D12 (f16) and about 280 ms on Vulkan (f16 on tensor cores, also on the device FFmpeg creates). For
  offline encodes.
- Frames go through 8-bit RGBA: 10-bit input loses its extra bits and alpha is not kept.
- Untested: the VideoToolbox path has never run. Vulkan, D3D12 and D3D11 match the CPU reference in the win64
  bundle (97.5 dB f32, 57.9 dB f16); linux64 was tested on lavapipe only.
- Full list: [LIMITATIONS.md](../../LIMITATIONS.md#super-resolution-gpufx_ai_upscale).

## See also

- [README: Super resolution](../../../README.md#super-resolution-gpufx_ai_upscale)
- [NN_MODEL_FORMAT.md](../../NN_MODEL_FORMAT.md)
- [gpufx_transfer](gpufx_transfer.md), [gpufx_ai_framerate](gpufx_ai_framerate.md)
