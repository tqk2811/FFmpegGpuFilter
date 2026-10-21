# Thuật ngữ

## AVHWDeviceContext

Device context của FFmpeg (`libavutil/hwcontext.h`): bọc một GPU đã mở (`VkInstance`/`VkDevice`/queue với Vulkan, `ID3D11Device`/`ID3D12Device` với D3D). Cả chuỗi filter thường dùng chung một device context, gpufx chạy shader trên đúng `VkDevice` của FFmpeg.

## AVHWFramesContext

Frames context của FFmpeg (`libavutil/hwcontext.h`): mô tả và cấp phát một pool frame GPU trên một device context. Mỗi link chở frame GPU gắn một frames context (`hw_frames_ctx`), và mỗi frame GPU cũng trỏ về frames context đã cấp nó. Gồm mô tả chung (`format`, `sw_format`, `width`, `height`, `pool`) và phần riêng từng API ở `hwctx` (Vulkan: `AVVulkanFramesContext` với `tiling`, `usage`, `flags`, `img_flags`, `format[]`, `lock_frame`/`unlock_frame`).

## AVVkFrame

Một frame Vulkan của FFmpeg (`libavutil/hwcontext_vulkan.h`), nằm ở `AVFrame.data[0]`: các `VkImage` + `VkDeviceMemory` của từng plane, kèm trạng thái đồng bộ đi theo image (`layout`, `access`, timeline `sem` + `sem_value`).

## PSNR

Peak Signal-to-Noise Ratio, đo bằng dB: độ giống nhau từng pixel giữa hai ảnh, `10·log10(255² / MSE)` với MSE là trung bình bình phương chênh lệch. Càng cao càng giống; hai ảnh y hệt thì MSE = 0 (`scripts/capcut-compare.py` ghi 99). Mốc thô cho ảnh 8-bit: ≥40 dB gần như không phân biệt, 30–40 dB khá giống, 20–30 dB thấy khác rõ, <20 dB khác nhiều. Chỉ đo sai khác pixel, không phản ánh cảm nhận mắt (lệch 1–2 px ở cạnh sắc cũng tụt mạnh), nên thường đi kèm [SSIM](#L19).

## SSIM

Structural Similarity Index, 0..1 (1 = giống hệt): so độ sáng trung bình, độ tương phản và cấu trúc theo từng ô nhỏ, gần với cảm nhận mắt hơn PSNR.

## Super-resolution

Upscale ảnh/video bằng mạng neural: model đoán chi tiết mới thay vì chỉ nội suy pixel như bilinear/lanczos. Model được train cho một hệ số cố định (x2, x3, x4); đầu vào `C x H x W` cho ra `C x sH x sW`.

## PReLU

Parametric ReLU: `x >= 0 ? x : a_c * x`, hệ số âm `a_c` học được, mỗi kênh một giá trị (khác leaky ReLU dùng chung một hệ số cố định). Layer `PReLU` của ncnn lưu `a` thành một blob `num_slope` phần tử.

## Pixel shuffle

Phép đổi chỗ phần tử để tăng độ phân giải: tensor `C·r² x H x W` thành `C x rH x rW`, mỗi nhóm `r²` kênh trải ra thành một ô `r x r` pixel. Là bước upscale cuối của các model super-resolution nhỏ (ESPCN, SRVGGNet).

## Tile

Cắt ảnh thành các ô (tile) để chạy model từng ô một, khi tensor trung gian của cả frame quá lớn so với VRAM hoặc giới hạn binding buffer. Mỗi tile được nới thêm một viền overlap; output chỉ giữ phần giữa tile để không lộ đường nối, vì pixel ở mép tile thiếu ngữ cảnh của vùng bên cạnh.

## Receptive field

Vùng pixel input mà một pixel output của mạng có thể "nhìn thấy": mỗi convolution 3x3 nới thêm 1 pixel mỗi phía, nên 18 lớp nhìn xa 18 pixel. Khi chạy theo [tile](#L35), overlap phải ít nhất bằng receptive field thì pixel giữ lại mới không bị ảnh hưởng bởi phần pad 0 ở mép tile, và kết quả mới bằng chạy cả frame.

## f16

Số thực dấu phẩy động 16 bit (half precision, 11 bit mantissa, tối đa 65504). Tính convolution bằng f16 nhanh hơn f32 trên nhiều GPU (ít băng thông workgroup memory và thanh ghi hơn) nhưng sai số lớn hơn; WGSL cần `enable f16` và thiết bị có tính năng `SHADER_F16`.

## Pass group

Một bộ pass trong `groups` của manifest effect, kèm `requires` (os, backend, vendor, feature) nói thiết bị nào chạy được. Runtime dùng group đầu tiên khớp thiết bị; các group chia sẻ input, output, param và texture nhưng có thể có số pass khác nhau. Xem [EFFECT_FORMAT-vi.md](EFFECT_FORMAT-vi.md#nhóm-pass-và-yêu-cầu-thiết-bị).
