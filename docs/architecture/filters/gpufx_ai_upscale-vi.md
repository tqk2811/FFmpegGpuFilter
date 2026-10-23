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
| `model` | string | (bắt buộc) | path | Đường dẫn gói hoặc bundle gpufx-nn có `io.json` kind `super_resolution`: `packages/gpufx_ai_upscale/realesr-animevideov3.zip` (anime, scale 2, 3, 4) hoặc `packages/gpufx_ai_upscale/realesr-general-x4v3.zip` (nội dung thường, scale 4). Thiếu thì filter không khởi động được. Định dạng: [NN_MODEL_FORMAT-vi.md](../../NN_MODEL_FORMAT-vi.md) |
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

## Use case và ví dụ

**Model (`model`).** Chọn theo nội dung: `realesr-animevideov3.zip` cho anime và hoạt hình (scale 2, 3, 4),
`realesr-general-x4v3.zip` cho live action và nội dung chung (chỉ scale 4). Package gpufx-nn `super_resolution` khác
cũng chạy được; không có `model` thì filter không khởi động.

```sh
# Anime 1080p -> 4K trên Vulkan
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_upscale=model=packages/gpufx_ai_upscale/realesr-animevideov3.zip:scale=2,gpufx_download,format=nv12" out.mp4

# Live action x4 trên D3D12 (Windows); model general chỉ có scale 4
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,hwupload,gpufx_ai_upscale=model=packages/gpufx_ai_upscale/realesr-general-x4v3.zip:scale=4,hwdownload,format=nv12" out.mp4
```

**`scale`.** Dùng để chọn kích thước output: 2 cho 1080p lên 4K, 4 cho nguồn nhỏ. Xin scale mà package không có thì
filter dừng với lỗi liệt kê các scale có sẵn. Đổi kích thước giữa stream cần `-reinit_filter 0`, output frame theo
kích thước mới.

**`tile` và `precision`.** Dùng `tile` trên GPU ít bộ nhớ (hoặc để giới hạn bộ nhớ với input 4K): tile nhỏ hơn dùng
ít bộ nhớ hơn, kết quả không phụ thuộc cách chia tile. Còn lại để `0`. Dùng `precision=f32` để kiểm output f16 của
`auto` hoặc khi f16 bị artefact; chậm hơn.

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_upscale=model=packages/gpufx_ai_upscale/realesr-animevideov3.zip:scale=2:tile=256:precision=f32,gpufx_download,format=nv12" out.mp4
```

**Vulkan, D3D12, D3D11.** Filter nhận GPU frame của device nó chạy trên. Vulkan nhanh nhất trong số đo (xem Giới
hạn); cần `disable_multiplane=1`, và `gpufx_upload` trên Intel Windows. D3D12 và D3D11 dùng `hwupload` /
`hwdownload`, D3D12 cần DXC cho shader. Dạng D3D11 của lệnh D3D12 ở trên giống hệt nhưng dùng device `d3d11va`
(`-init_hw_device d3d11va=dx -filter_hw_device dx`); bundle test có chạy filter trên D3D11, nhưng đúng dòng lệnh này
không nằm trong đó, nhưng đã chạy được trên RTX 4060 Laptop.

**Nối với `gpufx` (ở lại trên GPU).** Upscale trước, rồi hiệu ứng ở kích thước mới, chỉ một lần upload và một lần
download cho cả chuỗi:

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_upscale=model=packages/gpufx_ai_upscale/realesr-animevideov3.zip:scale=2,gpufx=graph=sepia.zip,gpufx_download,format=nv12" out.mp4
```

**Encode trên GPU không cần download.** Output là GPU frame, nên encoder GPU nhận được loại frame đó có thể lấy
thẳng (không cần `gpufx_download` / `hwdownload`). Bundle test chưa kiểm đường này cho filter này, hãy tự kiểm trên
máy của bạn: output Vulkan là storage image tắt multiplane, và encoder Vulkan nào đó có nhận chúng hay không thì
chưa kiểm chứng. Với device D3D12 và encoder D3D12 thì dạng lệnh như dưới (đã chạy trên RTX 4060 Laptop; `-bf 0` vì encoder D3D12 của NVIDIA lỗi với B-frame):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,hwupload,gpufx_ai_upscale=model=packages/gpufx_ai_upscale/realesr-animevideov3.zip:scale=2" -c:v h264_d3d12va -bf 0 out.mp4
```

Model không nằm trong git: file release `gpufx-packages.zip` có sẵn trong `gpufx_ai_upscale/` (kèm license; bundle ffmpeg không kèm), hoặc tải và convert bằng
`scripts/fetch-models.sh` / `scripts/fetch-models.ps1` (ghi ra `build/packages/<filter>/`).

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
