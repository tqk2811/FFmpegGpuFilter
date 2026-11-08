# Vulkan Intel trên Windows: host image copy (FFmpeg 9.0)

[English](INTEL_VULKAN.md) · [README](../README-vi.md)

Tóm tắt: với FFmpeg master mà gpufx đang build, `hwupload` / `hwdownload` chạy đúng trên GPU Intel dưới Windows và gpufx không cần xử lý riêng. Phần dưới chỉ liên quan nếu bạn tự build FFmpeg 9.0.

## Chuyện gì đã xảy ra

FFmpeg 9.0 bật `VK_EXT_host_image_copy` trên device có resizable BAR và thêm `VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT` vào mọi frames context Vulkan. Driver Intel Windows (đã test: UHD Graphics RaptorLake-S, 32.0.101.7082) xử lý sai: image optimal một plane lỗi `vkAllocateMemory` với `VK_ERROR_OUT_OF_HOST_MEMORY`, còn host copy của image multi-planar ghi chroma vào plane 0 mà không báo lỗi.

FFmpeg master kiểm từng frames context trước (`vulkan_host_transfer_usable` trong `libavutil/hwcontext_vulkan.c`). Driver đó báo không có optimal device access nên FFmpeg bỏ cờ usage và copy qua staging buffer. Bản thân driver không đổi: `-v verbose` in `Disabling host image transfers: format ... has no optimal device access`.

`gpufx_upload` / `gpufx_download` vẫn có ích trên mọi GPU vì chạy nhiều lần copy cùng lúc (xem [BENCHMARK-vi.md](BENCHMARK-vi.md)).

## Trạng thái upstream

Đã báo: [FFmpeg issue #25063](https://code.ffmpeg.org/FFmpeg/FFmpeg/issues/25063) và [IGCIT issue #1587](https://github.com/IGCIT/Intel-GPU-Community-Issue-Tracker-IGCIT/issues/1587).

## Cách kiểm lại

```sh
ffmpeg -v error -f lavfi -i testsrc2=s=320x180 -frames:v 1 -pix_fmt nv12 -f rawvideo in.yuv
ffmpeg -v verbose -init_hw_device vulkan=vk:1 -filter_hw_device vk -f rawvideo -pix_fmt nv12 -s 320x180 -i in.yuv   -vf "hwupload,hwdownload,format=nv12" -f rawvideo out.yuv 2>&1 | grep "host image transfers"
md5sum in.yuv out.yuv  # phải trùng
VK_ADAPTER=1 DX_ADAPTER=1 REQUIRE_D3D=1 sh scripts/test-bundle.sh dist/win64
```
