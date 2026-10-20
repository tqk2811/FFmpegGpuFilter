Tiếng Việt: [gpufx_transfer-vi.md](gpufx_transfer-vi.md)

# Filters `gpufx_upload` and `gpufx_download`

Copy frames between system memory and Vulkan frames, like `hwupload` and `hwdownload`, but pipelined: the CPU and
the GPU work at the same time instead of taking turns. Vulkan only (source: `ffmpeg/vf_gpufx_transfer.c`).

- `gpufx_upload`: software frames in, Vulkan frames out. Replaces `hwupload`.
- `gpufx_download`: Vulkan frames in, software frames out. Replaces `hwdownload`.

Why they are faster: on NVIDIA, FFmpeg 9 cannot use host image copy or host memory import, so `hwupload` and
`hwdownload` copy through a staging buffer and the CPU waits for every copy. These filters keep several copies in
flight. The design background (staging ring, synchronization, queues, measurements) is in
[DESIGN.md, Transfer filters](../../DESIGN.md#transfer-filters-gpufx_upload--gpufx_download-vulkan); the numbers are in
[BENCHMARK.md](../../BENCHMARK.md). On Intel under Windows they are also the way to avoid FFmpeg 9's broken host image
copies, see [INTEL_VULKAN.md](../../INTEL_VULKAN.md).

## Syntax

```
gpufx_upload[=depth=3]
gpufx_download[=latency=2]
```

Both need the Vulkan device given to the filter graph: `-init_hw_device vulkan=vk -filter_hw_device vk`. For the
frames to be usable by `gpufx`, `gpufx_ai_framerate` and `gpufx_ai_upscale`, open the device with
`disable_multiplane=1` (`vulkan=vk:0,disable_multiplane=1`), as in the examples.

## Options

| Filter | Option | Type | Default | Range | Meaning |
|--------|--------|------|---------|-------|---------|
| `gpufx_upload` | `depth` | int | `3` | 1..16 | Staging buffers in the ring: copies in flight before the CPU waits. The Vulkan frame pool starts at `depth + 2 + extra_hw_frames` frames (when `extra_hw_frames` is not set to a negative value) |
| `gpufx_download` | `latency` | int | `2` | 0..16 | Frames kept in flight: frame N is sent on after frame N+`latency` was submitted. `0` waits for each frame (no pipelining). Output is delayed by `latency` frames and flushed at the end of the stream |

## Input and output

| Filter | Input | Output |
|--------|-------|--------|
| `gpufx_upload` | Software frames. Formats: the device's software formats (`sw_format`) whose planes map 1:1 to Vulkan planes (for example `nv12`, `yuv420p`, `rgba`, `p010le`). Not accepted: hardware, bitstream, Bayer and palette formats, and packed 4:2:2 (`yuyv422` and similar) | Vulkan frames (`AV_PIX_FMT_VULKAN`) with the input's format as `sw_format`, same size, properties copied |
| `gpufx_download` | Vulkan frames, from any filter or decoder that gives Vulkan frames of a supported format | Software frames of the frames' `sw_format` |

- The frames context of `gpufx_upload` is created on `-filter_hw_device` and drops the host-transfer usage, so
  the frames are safe on the Intel Windows driver.
- `gpufx_download` needs `format=<sw_format>` after it (same rule as `hwdownload`), otherwise it stops with
  an error naming the format to add.
- Multiplane images and one image per plane (`disable_multiplane=1`) both work. They mix with `hwupload`,
  `hwdownload`, `gpufx`, `gpufx_ai_*` and the `*_vulkan` filters.

## Timeline and commands

Neither filter supports the timeline (`enable`) or runtime commands.

## Examples

```sh
# Upload, two effects on the GPU, download
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx=graph=vignette.zip,gpufx=graph=sepia.zip,gpufx_download,format=nv12" out.mp4

# Deeper pipelines for a slow disk or a busy GPU
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx_upload=depth=6,gpufx=graph=sepia.zip,gpufx_download=latency=4,format=nv12" out.mp4

# Mixed with the stock filters
ffmpeg -init_hw_device vulkan=vk -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx_upload,scale_vulkan=1280:720,hwdownload,format=nv12" out.mp4
```

## Limitations

- Vulkan only. D3D12, D3D11 and VideoToolbox use the stock `hwupload` / `hwdownload`.
- A frame size change in the middle of the stream stops the graph with `EINVAL` (`hwupload` / `hwdownload` accept
  it).
- With sparse (live) input each frame comes out `latency` frames later; use `latency=0` to turn the pipelining
  off.
- Hardware, bitstream, Bayer, palette and packed 4:2:2 pixel formats are not supported; the filter logs
  "use hwupload/hwdownload" for them.
- More in [LIMITATIONS.md](../../LIMITATIONS.md#upload--download).

## See also

- [DESIGN.md, Transfer filters](../../DESIGN.md#transfer-filters-gpufx_upload--gpufx_download-vulkan)
- [gpufx_ai_framerate](gpufx_ai_framerate.md), [gpufx_ai_upscale](gpufx_ai_upscale.md)
- [INTEL_VULKAN.md](../../INTEL_VULKAN.md), [BENCHMARK.md](../../BENCHMARK.md)
