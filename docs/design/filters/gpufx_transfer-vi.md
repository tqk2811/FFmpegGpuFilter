English: [gpufx_transfer.md](gpufx_transfer.md)

# Filter `gpufx_upload` và `gpufx_download`

Copy frame giữa RAM và Vulkan frame, giống `hwupload` và `hwdownload`, nhưng chạy pipeline: CPU và GPU làm việc
song song thay vì thay phiên nhau chờ. Chỉ Vulkan (source: `ffmpeg/vf_gpufx_transfer.c`).

- `gpufx_upload`: vào là software frame, ra là Vulkan frame. Thay `hwupload`.
- `gpufx_download`: vào là Vulkan frame, ra là software frame. Thay `hwdownload`.

Vì sao nhanh hơn: trên NVIDIA, FFmpeg 9 không dùng được host image copy và host memory import, nên `hwupload` và
`hwdownload` copy qua staging buffer và CPU chờ từng lần copy. Hai filter này giữ nhiều lần copy chạy cùng lúc.
Nền tảng thiết kế (ring staging, đồng bộ, queue, số đo) nằm ở
[DESIGN-vi.md, Filter truyền frame](../../DESIGN-vi.md#filter-truyền-frame-gpufx_upload--gpufx_download-vulkan); số đo ở
[BENCHMARK-vi.md](../../BENCHMARK-vi.md). Trên Intel dưới Windows, hai filter này cũng là cách tránh host image copy
hỏng của FFmpeg 9, xem [INTEL_VULKAN-vi.md](../../INTEL_VULKAN-vi.md).

## Cú pháp

```
gpufx_upload[=depth=3]
gpufx_download[=latency=2]
```

Cả hai cần Vulkan device đưa vào filter graph: `-init_hw_device vulkan=vk -filter_hw_device vk`. Để frame dùng
được với `gpufx`, `gpufx_ai_framerate` và `gpufx_ai_upscale`, mở device với `disable_multiplane=1`
(`vulkan=vk:0,disable_multiplane=1`), như trong ví dụ.

## Option

| Filter | Option | Kiểu | Mặc định | Khoảng | Ý nghĩa |
|--------|--------|------|----------|--------|---------|
| `gpufx_upload` | `depth` | int | `3` | 1..16 | Số staging buffer trong ring: số lần copy đang chạy trước khi CPU phải chờ. Pool Vulkan frame bắt đầu với `depth + 2 + extra_hw_frames` frame (khi `extra_hw_frames` không đặt âm) |
| `gpufx_download` | `latency` | int | `2` | 0..16 | Số frame giữ đang chạy: frame N được đẩy đi sau khi frame N+`latency` đã submit. `0` chờ từng frame (không pipeline). Output trễ `latency` frame và được xả hết ở cuối stream |

## Input và output

| Filter | Input | Output |
|--------|-------|--------|
| `gpufx_upload` | Software frame. Format: các software format (`sw_format`) của device mà plane ánh xạ 1:1 sang plane Vulkan (ví dụ `nv12`, `yuv420p`, `rgba`, `p010le`). Không nhận: format hardware, bitstream, Bayer, palette, và packed 4:2:2 (`yuyv422`...) | Vulkan frame (`AV_PIX_FMT_VULKAN`) với `sw_format` là format của input, cùng kích thước, copy property |
| `gpufx_download` | Vulkan frame, từ filter hoặc decoder bất kỳ cho Vulkan frame có format được hỗ trợ | Software frame theo `sw_format` của frames context |

- Frames context của `gpufx_upload` được tạo trên `-filter_hw_device` và bỏ cờ usage host-transfer, nên frame an
  toàn trên driver Intel Windows.
- `gpufx_download` cần `format=<sw_format>` đặt sau nó (cùng luật như `hwdownload`), nếu không sẽ dừng với lỗi nói
  rõ format cần thêm.
- Ảnh multiplane và mỗi plane một ảnh (`disable_multiplane=1`) đều chạy được. Dùng chung được với `hwupload`,
  `hwdownload`, `gpufx`, `gpufx_ai_*` và các filter `*_vulkan`.

## Timeline và command

Cả hai filter không hỗ trợ timeline (`enable`) và command lúc chạy.

## Ví dụ

```sh
# Upload, hai hiệu ứng trên GPU, download
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx=graph=vignette.zip,gpufx=graph=sepia.zip,gpufx_download,format=nv12" out.mp4

# Pipeline sâu hơn cho ổ đĩa chậm hoặc GPU bận
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx_upload=depth=6,gpufx=graph=sepia.zip,gpufx_download=latency=4,format=nv12" out.mp4

# Dùng chung với filter có sẵn của FFmpeg
ffmpeg -init_hw_device vulkan=vk -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx_upload,scale_vulkan=1280:720,hwdownload,format=nv12" out.mp4
```

## Giới hạn

- Chỉ Vulkan. D3D12, D3D11 và VideoToolbox dùng `hwupload` / `hwdownload` có sẵn.
- Đổi kích thước frame giữa stream làm graph dừng với `EINVAL` (`hwupload` / `hwdownload` thì chịu được).
- Với input thưa (live), mỗi frame ra trễ `latency` frame; đặt `latency=0` để tắt pipeline.
- Không hỗ trợ pixel format hardware, bitstream, Bayer, palette và packed 4:2:2; filter báo lỗi gợi ý dùng
  `hwupload` / `hwdownload`.
- Xem thêm [LIMITATIONS-vi.md](../../LIMITATIONS-vi.md#upload--download).

## Xem thêm

- [DESIGN-vi.md, Filter truyền frame](../../DESIGN-vi.md#filter-truyền-frame-gpufx_upload--gpufx_download-vulkan)
- [gpufx_ai_framerate](gpufx_ai_framerate-vi.md), [gpufx_ai_upscale](gpufx_ai_upscale-vi.md)
- [INTEL_VULKAN-vi.md](../../INTEL_VULKAN-vi.md), [BENCHMARK-vi.md](../../BENCHMARK-vi.md)
