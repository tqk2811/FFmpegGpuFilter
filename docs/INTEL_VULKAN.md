# Intel Vulkan on Windows: host image copy (FFmpeg 9.0)

[Tiếng Việt](INTEL_VULKAN-vi.md) · [README](../README.md)

Short version: with the FFmpeg master gpufx builds on, `hwupload` / `hwdownload` work on an Intel GPU under Windows and gpufx needs no special handling. Nothing below applies unless you build FFmpeg 9.0 yourself.

## What happened

FFmpeg 9.0 enables `VK_EXT_host_image_copy` on devices with a resizable BAR and gives every Vulkan frames context `VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT`. The Intel Windows driver (tested: UHD Graphics RaptorLake-S, 32.0.101.7082) gets it wrong: optimal-tiling single-plane images fail `vkAllocateMemory` with `VK_ERROR_OUT_OF_HOST_MEMORY`, and host copies of multi-planar images put chroma into plane 0 with no error.

FFmpeg master checks each frames context first (`vulkan_host_transfer_usable` in `libavutil/hwcontext_vulkan.c`). That driver reports no optimal device access, so FFmpeg drops the usage and copies through a staging buffer. The driver itself is unchanged: `-v verbose` prints `Disabling host image transfers: format ... has no optimal device access`.

`gpufx_upload` / `gpufx_download` remain useful on every GPU because they pipeline the copies (see [BENCHMARK.md](BENCHMARK.md)).

## Status upstream

Reported as [FFmpeg issue #25063](https://code.ffmpeg.org/FFmpeg/FFmpeg/issues/25063) and [IGCIT issue #1587](https://github.com/IGCIT/Intel-GPU-Community-Issue-Tracker-IGCIT/issues/1587).

## How to re-check

```sh
ffmpeg -v error -f lavfi -i testsrc2=s=320x180 -frames:v 1 -pix_fmt nv12 -f rawvideo in.yuv
ffmpeg -v verbose -init_hw_device vulkan=vk:1 -filter_hw_device vk -f rawvideo -pix_fmt nv12 -s 320x180 -i in.yuv   -vf "hwupload,hwdownload,format=nv12" -f rawvideo out.yuv 2>&1 | grep "host image transfers"
md5sum in.yuv out.yuv  # must match
VK_ADAPTER=1 DX_ADAPTER=1 REQUIRE_D3D=1 sh scripts/test-bundle.sh dist/win64
```
