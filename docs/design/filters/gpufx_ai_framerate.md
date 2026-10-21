Tiếng Việt: [gpufx_ai_framerate-vi.md](gpufx_ai_framerate-vi.md)

# Filter `gpufx_ai_framerate`

Raises the frame rate with a neural frame interpolation model (RIFE v4.6, converted to a gpufx-nn package) run on
the GPU by libgpufx. It works on the same GPU frames and devices as `gpufx` (Vulkan, D3D12, D3D11, VideoToolbox).
Source: `ffmpeg/vf_gpufx_ai_framerate.c`. Design: [DESIGN.md, Frame interpolation](../DESIGN.md#frame-interpolation-gpufx_ai_framerate-rife-gpufx-nn-packages).

The output is a constant frame rate grid (like `framerate` and `minterpolate`). Each grid point between two source
frames is made by the model at the matching time, a grid point on a source frame is that frame itself, and the last
frame lasts until the end of the stream. Any output rate works, not only multiples of the input's.

## Syntax

```
gpufx_ai_framerate=model=<path>[:fps=<rate>][:scene=<0..1>][:max_gap=<n>]
```

## Options

| Option | Type | Default | Range/values | Meaning |
|--------|------|---------|--------------|---------|
| `model` | string | (required) | path | Path of a gpufx-nn package whose `io.json` has kind `frame_interp`, for example `packages/gpufx_ai_framerate/rife-v4.6.zip`. The filter fails to start without it. Format: [NN_MODEL_FORMAT.md](../../NN_MODEL_FORMAT.md) |
| `fps` | rational | twice the input's | 0..INT_MAX | Output frame rate, a number or a fraction (`30`, `24000/1001`); named rates such as `ntsc` are not accepted. `0` (default) means twice the input rate. If the input rate is unknown, `fps` must be set |
| `scene` | double | `0.2` | 0..1 | Scene change threshold: the SSIM of the pair at 32x32, as the official RIFE `inference_video.py` computes it. A pair below it is a cut and is not interpolated (the nearer source frame is repeated). `0` never detects a cut: every pair is interpolated. On anime 0.2 still blends some cuts between shots of similar layout; 0.4 caught 89% of the cuts of three 90 s OP/ED clips, at the cost of repeating a frame on some very fast zooms and flashes |
| `max_gap` | double | `2.0` | 1..100 | A pair of source frames further apart than this many input frame durations (a gap in a VFR stream) is repeated, not interpolated |

Pairs that go back in time, change size or format, or are further apart than `max_gap` are also repeated, with a
warning. A jump of more than 10000 output frames (a timestamp jump, or the stream ending long after the last frame)
is skipped.

## Input and output

- Input: GPU frames only, from `gpufx_upload` / `hwupload` or a hardware decoder: Vulkan, D3D12, D3D11 or
  VideoToolbox, with `sw_format` `nv12`, `p010le`, `rgba` or `rgba64le` (VideoToolbox: `nv12`, `p010le`). The
  GPU converts these using BT.601, BT.709 or BT.2020 matrices; other color spaces stop with an error asking for a
  supported matrix before uploading.
- Output: GPU frames of the same format and size, at the new frame rate. When the GPU can write the input frames
  (Vulkan storage images, D3D12, shared D3D11 textures) the output uses the input frames context and the source
  frames pass through as they are. Otherwise (for example D3D11 `hwupload`) the output has its own frames
  context and the source frames are copied into it on the GPU through 8-bit RGBA, which is slightly lossy.
- With an input frames pool of fixed size the filter warns that more frames may be needed; raise
  `extra_hw_frames` when uploading, or the stream may stall.
- Vulkan: use a device opened with `disable_multiplane=1`, and `gpufx_upload` rather than `hwupload` (host image
  copies are refused on Intel Windows, see [INTEL_VULKAN.md](../../INTEL_VULKAN.md)). The Vulkan device needs a
  graphics queue.
- D3D12: the model shaders need DXC (`dxcompiler.dll`, shipped in `bin/`); the first run compiles them, set
  `GPUFX_SHADER_CACHE` to keep them.

## Timeline and commands

No timeline support and no runtime commands.

## Examples

```sh
# 12 fps -> 24 fps on Vulkan
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_framerate=model=packages/gpufx_ai_framerate/rife-v4.6.zip,gpufx_download,format=nv12" out.mp4

# Any target rate, D3D12 (Windows)
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,hwupload,gpufx_ai_framerate=model=packages/gpufx_ai_framerate/rife-v4.6.zip:fps=60000/1001,hwdownload,format=nv12" out.mp4

# No cut detection, interpolate across gaps up to 4 frame durations
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_framerate=model=packages/gpufx_ai_framerate/rife-v4.6.zip:scene=0:max_gap=4,gpufx_download,format=nv12" out.mp4
```

The model is not in git: the release asset `gpufx-packages.zip` ships it in `gpufx_ai_framerate/` (not the ffmpeg bundles), or fetch and convert it with
`scripts/fetch-models.sh` / `scripts/fetch-models.ps1` (written to `build/packages/<filter>/`).

## Limitations

- Untested: the VideoToolbox (macOS) path has never run on a Mac, and the linux64 bundle's filter and
  `packages/gpufx_ai_framerate/rife-v4.6.zip` have not been run (only Windows has).
- Speed (RTX 4060 Laptop): Vulkan about 45 ms per 1080p frame (4K about 174 ms); D3D12 and D3D11 are about
  1.7x slower. Prefer Vulkan.
- Output frame rate is constant: variable frame rate input is resampled to the grid.
- Full list: [LIMITATIONS.md](../../LIMITATIONS.md#frame-interpolation-gpufx_ai_framerate).

## See also

- [README: Frame interpolation](../../../README.md#frame-interpolation-gpufx_ai_framerate)
- [NN_MODEL_FORMAT.md](../../NN_MODEL_FORMAT.md), [DESIGN.md, Frame interpolation](../DESIGN.md#frame-interpolation-gpufx_ai_framerate-rife-gpufx-nn-packages)
- [gpufx_transfer](gpufx_transfer.md), [gpufx_ai_upscale](gpufx_ai_upscale.md)
