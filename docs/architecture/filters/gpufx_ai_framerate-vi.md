English: [gpufx_ai_framerate.md](gpufx_ai_framerate.md)

# Filter `gpufx_ai_framerate`

Tăng frame rate bằng model nội suy khung hình neural (RIFE v4.6, đã convert sang gói gpufx-nn) chạy trên GPU qua
libgpufx. Làm việc trên cùng GPU frame và device với `gpufx` (Vulkan, D3D12, D3D11, VideoToolbox).
Source: `ffmpeg/vf_gpufx_ai_framerate.c`. Thiết kế: [Kiến trúc, Nội suy khung hình](../README-vi.md#nội-suy-khung-hình-gpufx_ai_framerate-rife-gói-gpufx-nn).

Output có frame rate cố định (như `framerate` và `minterpolate`). Mỗi điểm lưới nằm giữa hai source frame được model
tạo ra tại thời điểm tương ứng, điểm lưới trùng source frame thì chính là frame đó, và frame cuối kéo dài đến hết
stream. Rate output tuỳ ý, không cần là bội của rate input.

## Cú pháp

```
gpufx_ai_framerate=model=<path>[:fps=<rate>][:scene=<0..1>][:max_gap=<n>]
```

## Option

| Option | Kiểu | Mặc định | Khoảng/giá trị | Ý nghĩa |
|--------|------|----------|----------------|---------|
| `model` | string | (bắt buộc) | path | Đường dẫn gói gpufx-nn có `io.json` kind `frame_interp`, ví dụ `packages/gpufx_ai_framerate/rife-v4.6.zip`. Thiếu thì filter không khởi động được. Định dạng: [NN_MODEL_FORMAT-vi.md](../../NN_MODEL_FORMAT-vi.md) |
| `fps` | rational | gấp đôi rate input | 0..INT_MAX | Frame rate output, số hoặc phân số (`30`, `24000/1001`); không nhận tên rate như `ntsc`. `0` (mặc định) nghĩa là gấp đôi rate input. Nếu không biết rate input thì phải đặt `fps` |
| `scene` | double | `0.2` | 0..1 | Ngưỡng đổi cảnh: SSIM của cặp frame ở 32x32, tính như `inference_video.py` gốc của RIFE. Cặp dưới ngưỡng là một cú cắt và không nội suy (lặp source frame gần hơn). `0` không bao giờ phát hiện cắt: mọi cặp đều nội suy. Trên anime 0.2 vẫn trộn vài cú cắt giữa các cảnh có bố cục giống nhau; 0.4 bắt được 89% cú cắt của ba clip OP/ED 90 s, đổi lại có lúc lặp một frame ở vài cú zoom và flash rất nhanh |
| `max_gap` | double | `2.0` | 1..100 | Cặp source frame cách nhau hơn từng này lần thời lượng frame input (khoảng trống trong stream VFR) thì lặp frame, không nội suy |

Cặp đi ngược thời gian, đổi kích thước hoặc format, hoặc cách nhau hơn `max_gap` cũng bị lặp frame, kèm warning.
Bước nhảy hơn 10000 output frame (nhảy timestamp, hoặc stream kết thúc rất lâu sau frame cuối) bị bỏ qua.

## Input và output

- Input: chỉ GPU frame, từ `gpufx_upload` / `hwupload` hoặc hardware decoder: Vulkan, D3D12, D3D11 hoặc
  VideoToolbox, `sw_format` là `nv12`, `p010le`, `rgba` hoặc `rgba64le` (VideoToolbox: `nv12`, `p010le`). GPU
  convert bằng ma trận BT.601, BT.709 hoặc BT.2020; color space khác sẽ dừng với lỗi yêu cầu đặt ma trận được hỗ
  trợ trước khi upload.
- Output: GPU frame cùng format và kích thước, ở frame rate mới. Khi GPU ghi được vào input frame (Vulkan
  storage image, D3D12, texture D3D11 shared) thì output dùng frames context của input và source frame đi qua
  nguyên vẹn. Ngược lại (ví dụ `hwupload` của D3D11) output có frames context riêng và source frame được copy
  vào đó trên GPU qua RGBA 8-bit, hơi mất chất lượng.
- Nếu pool input frame có kích thước cố định, filter cảnh báo có thể cần thêm frame; tăng `extra_hw_frames` khi
  upload, nếu không stream có thể bị treo.
- Vulkan: dùng device mở với `disable_multiplane=1`, và `gpufx_upload` thay vì `hwupload` (host image copy bị từ
  chối trên Intel Windows, xem [INTEL_VULKAN-vi.md](../../INTEL_VULKAN-vi.md)). Vulkan device cần graphics queue.
- D3D12: shader của model cần DXC (`dxcompiler.dll`, có sẵn trong `bin/`); lần chạy đầu compile shader, đặt
  `GPUFX_SHADER_CACHE` để giữ lại.

## Timeline và command

Không hỗ trợ timeline, không có command lúc chạy.

## Ví dụ

```sh
# 12 fps -> 24 fps trên Vulkan
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_framerate=model=packages/gpufx_ai_framerate/rife-v4.6.zip,gpufx_download,format=nv12" out.mp4

# Rate đích tuỳ ý, D3D12 (Windows)
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,hwupload,gpufx_ai_framerate=model=packages/gpufx_ai_framerate/rife-v4.6.zip:fps=60000/1001,hwdownload,format=nv12" out.mp4

# Không phát hiện cắt cảnh, nội suy qua khoảng trống tới 4 lần thời lượng frame
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_framerate=model=packages/gpufx_ai_framerate/rife-v4.6.zip:scene=0:max_gap=4,gpufx_download,format=nv12" out.mp4
```

Model không nằm trong git: file release `gpufx-packages.zip` có sẵn trong `gpufx_ai_framerate/` (bundle ffmpeg không kèm), hoặc tải và convert bằng
`scripts/fetch-models.sh` / `scripts/fetch-models.ps1` (ghi ra `build/packages/<filter>/`).

## Giới hạn

- Chưa kiểm: đường VideoToolbox (macOS) chưa từng chạy trên Mac, và filter cùng `packages/gpufx_ai_framerate/rife-v4.6.zip` của bundle
  linux64 chưa được chạy (chỉ Windows đã chạy).
- Tốc độ (RTX 4060 Laptop): Vulkan khoảng 45 ms mỗi frame 1080p (4K khoảng 174 ms); D3D12 và D3D11 chậm hơn
  khoảng 1,7 lần. Nên dùng Vulkan.
- Frame rate output là cố định: input VFR được lấy mẫu lại theo lưới.
- Danh sách đầy đủ: [LIMITATIONS-vi.md](../../LIMITATIONS-vi.md#nội-suy-khung-hình-gpufx_ai_framerate).

## Xem thêm

- [README: Nội suy khung hình](../../../README-vi.md#nội-suy-khung-hình-gpufx_ai_framerate)
- [NN_MODEL_FORMAT-vi.md](../../NN_MODEL_FORMAT-vi.md), [Kiến trúc, Nội suy khung hình](../README-vi.md#nội-suy-khung-hình-gpufx_ai_framerate-rife-gói-gpufx-nn)
- [gpufx_transfer](gpufx_transfer-vi.md), [gpufx_ai_upscale](gpufx_ai_upscale-vi.md)
