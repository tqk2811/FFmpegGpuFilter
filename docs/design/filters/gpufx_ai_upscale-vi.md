English: [gpufx_ai_upscale.md](gpufx_ai_upscale.md)

# Filter `gpufx_ai_upscale`

Upscale từng frame bằng model super resolution neural (Real-ESRGAN, đã convert sang gói gpufx-nn) chạy trên GPU
qua libgpufx, trên cùng GPU frame và device với `gpufx` (Vulkan, D3D12, D3D11, VideoToolbox). Output lớn gấp
`scale` lần input trên mỗi trục, cùng pixel format với input. Source: `ffmpeg/vf_gpufx_ai_upscale.c`.

Mỗi frame được convert sang RGBA, model upscale theo các tile chồng lấn (để frame 1080p và 4K vừa giới hạn buffer
của GPU) rồi convert ngược lại. Input frame chỉ được đọc.

## Cú pháp

```
gpufx_ai_upscale=model=<path>[:scale=<n>][:tile=<px>][:precision=auto|f32]
```

## Option

| Option | Kiểu | Mặc định | Khoảng/giá trị | Ý nghĩa |
|--------|------|----------|----------------|---------|
| `model` | string | (bắt buộc) | path | Đường dẫn gói hoặc bundle gpufx-nn có `io.json` kind `super_resolution`: `models/realesr-animevideov3.zip` (anime, scale 2, 3, 4) hoặc `models/realesr-general-x4v3.zip` (nội dung thường, scale 4). Thiếu thì filter không khởi động được. Định dạng: [NN_MODEL_FORMAT-vi.md](../../NN_MODEL_FORMAT-vi.md) |
| `scale` | int | `2` | 1..16 | Kích thước output / input trên mỗi trục. Gói phải có scale đó; lỗi sẽ liệt kê các scale gói có. Frame upscale xong quá lớn bị từ chối |
| `tile` | int | `0` | 0..16384 | Cạnh tile lớn nhất tính theo pixel input. `0` chọn số tile ít nhất vừa giới hạn buffer của GPU. Các tile chồng lấn đúng bằng context của model nên kết quả không phụ thuộc cách chia tile (không có đường nối) |
| `precision` | int (hằng) | `auto` | `auto`, `f32` | Kiểu số học của các convolution. `auto`: f16 nếu GPU có (khoảng 57 dB so với bản f32 chuẩn), không thì f32. `f32`: f32 ở mọi nơi (chậm hơn) |

## Input và output

- Input: chỉ GPU frame, từ `gpufx_upload` / `hwupload` hoặc hardware decoder: Vulkan, D3D12, D3D11 hoặc
  VideoToolbox, `sw_format` `nv12`, `p010le`, `rgba` hoặc `rgba64le` (VideoToolbox: `nv12`, `p010le`). Color space
  ngoài BT.601, BT.709 và BT.2020 sẽ dừng với lỗi.
- Output: GPU frame cùng format, lớn gấp `scale` lần, có frames context riêng (Vulkan: storage image, tắt
  multiplane). Frame đi qua RGBA 8-bit (input và output của model), nên input 10-bit mất các bit thừa và alpha
  không được giữ.
- Đổi kích thước giữa stream (`-reinit_filter 0`) cho output frame kích thước mới, kèm warning.
- Vulkan: dùng device mở với `disable_multiplane=1`, và `gpufx_upload` thay vì `hwupload` trên Intel Windows
  ([INTEL_VULKAN-vi.md](../../INTEL_VULKAN-vi.md)). Device cần graphics queue và input frame phải sample được.
- D3D12: shader cần DXC (`dxcompiler.dll`, có sẵn trong `bin/`), như `gpufx_ai_framerate`; đặt
  `GPUFX_SHADER_CACHE` để giữ shader đã compile.

## Timeline và command

Không hỗ trợ timeline, không có command lúc chạy.

## Ví dụ

```sh
# Anime 1080p -> 4K trên Vulkan
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_upscale=model=models/realesr-animevideov3.zip:scale=2,gpufx_download,format=nv12" out.mp4

# Live action x4 trên D3D12 (Windows)
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,hwupload,gpufx_ai_upscale=model=models/realesr-general-x4v3.zip:scale=4,hwdownload,format=nv12" out.mp4

# Tile nhỏ hơn và f32, cho GPU ít bộ nhớ hoặc để kiểm output f16
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_upscale=model=models/realesr-animevideov3.zip:scale=2:tile=256:precision=f32,gpufx_download,format=nv12" out.mp4
```

Model không nằm trong git: bundle win64/linux64 có sẵn trong `models/` (kèm license), hoặc tải và convert bằng
`scripts/fetch-models.sh` / `scripts/fetch-models.ps1` (ghi ra `build/models/`).

## Giới hạn

- Không real time: trên RTX 4060 Laptop, một frame 1080p x2 (realesr-animevideov3) mất khoảng 480-510 ms trên
  D3D11/D3D12 (f16) và khoảng 280 ms trên Vulkan (f16 trên Tensor Core, kể cả device do FFmpeg tạo). Dùng cho
  encode offline.
- Frame đi qua RGBA 8-bit: input 10-bit mất các bit thừa và alpha không được giữ.
- Chưa kiểm: đường VideoToolbox chưa từng chạy. Vulkan, D3D12 và D3D11 khớp bản CPU chuẩn trong bundle win64
  (97,5 dB f32, 57,9 dB f16); linux64 chỉ được test trên lavapipe.
- Danh sách đầy đủ: [LIMITATIONS-vi.md](../../LIMITATIONS-vi.md#tăng-độ-phân-giải-bằng-ai-gpufx_ai_upscale).

## Xem thêm

- [README: Tăng độ phân giải bằng AI](../../../README-vi.md#tăng-độ-phân-giải-bằng-ai-gpufx_ai_upscale)
- [NN_MODEL_FORMAT-vi.md](../../NN_MODEL_FORMAT-vi.md)
- [gpufx_transfer](gpufx_transfer-vi.md), [gpufx_ai_framerate](gpufx_ai_framerate-vi.md)
