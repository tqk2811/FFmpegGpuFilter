# Hạn chế và phần chưa kiểm thử

[English](LIMITATIONS.md) · [README](../README-vi.md)

Tổng hợp những gì gpufx chưa làm được và những gì chưa từng chạy thật. Mỗi mục có nhãn **Hạn chế** (đã biết, đang
như vậy) hoặc **Chưa test** (có code nhưng chưa chạy trên phần cứng/môi trường đó). Việc dự định sửa nằm ở
[Backlog-vi.md](Backlog-vi.md).

## Phần cứng và nền tảng đã chạy thật

- Windows: NVIDIA RTX 4060 Laptop và Intel UHD Graphics, với Vulkan, D3D12 và D3D11.
- Linux: chỉ lavapipe (Vulkan phần mềm) trong CI.
- **Chưa test:** GPU AMD (mọi API); GPU thật trên Linux (NVIDIA, RADV, ANV); máy Mac (đường VideoToolbox/Metal mới chỉ
  biên dịch chéo, job CI `ffmpeg-macos` chưa chạy lần nào). Các GPU khác ghi là hỗ trợ trong
  [REQUIREMENTS-vi.md](REQUIREMENTS-vi.md) suy từ bảng tier công khai, chưa thử. Phiên bản Windows/macOS tối thiểu
  chưa kiểm.
- **Chưa test:** CI không chạy được D3D (runner Windows chỉ có WARP), nên test D3D bị bỏ qua.

## Vulkan

- **Hạn chế:** frame một VkImage mỗi plane (`-init_hw_device vulkan=...,disable_multiplane=1`) được đọc tại
  chỗ; input multiplane (decoder Vulkan `-hwaccel vulkan`, hoặc `hwupload` không có `disable_multiplane=1`)
  tốn một lần copy trên GPU cho mỗi plane mỗi frame (nv12, p010, yuv420p/422p/444p và bản 10-bit; cần usage
  `TRANSFER_SRC`). Trên device đó output nv12/p010/yuv cũng là image multiplane, ghi qua một lần
  copy trên GPU mỗi plane (encoder Vulkan chỉ nhận loại này); với `disable_multiplane=1` output mỗi plane một image
  (ghi tại chỗ) và encoder Vulkan không nhận. Đã test: `h264_vulkan`, `hevc_vulkan` (cả p010 main10) trên RTX 4060; `av1_vulkan` ở đó lệch ~20 dB cả khi không có gpufx.
- **Hạn chế:** FFmpeg 9.0 tạo frames context `yuva420p`/`yuva444p` không có usage, nên output Vulkan không ra được
  hai dạng này (input qua `hwupload` vẫn được).
- **Hạn chế:** cần queue family có cả graphics lẫn compute; không chạy trên family chỉ có compute.
- **Hạn chế:** một lần submit bị driver từ chối thì device dùng chung hỏng tới hết tiến trình, không tự phục hồi
  (D3D12 cũng vậy).
- **Hạn chế:** lúc khởi động effect được biên dịch hai lần (device mặc định lúc init, rồi device của FFmpeg lúc
  configure).
- **Hạn chế:** Intel trên Windows (FFmpeg 9): `hwupload`/`hwdownload` hỏng qua host image copy của driver, nên gpufx
  từ chối frame đó. Dùng `gpufx_upload`/`gpufx_download`. Xem [INTEL_VULKAN-vi.md](INTEL_VULKAN-vi.md).
- **Chưa test:** `hwmap` từ CUDA/VAAPI, `gpufx_download` với frame của `-hwaccel vulkan`.

## D3D12 / D3D11

- **Hạn chế:** `gpufx` chỉ đọc/ghi frame D3D dạng `nv12`, `p010le`, `rgba`, `rgba64le`. Frame D3D11 `bgra` và texture
  nhiều mip level bị từ chối.
- **Hạn chế:** FFmpeg không có bản vá của repo này (vd FFmpeg tải nơi khác rồi tự build gpufx vào) không có frame
  D3D có alpha; bundle của repo có bản vá. Chi tiết ở [Định dạng frame D3D11/D3D12](#định-dạng-frame-d3d11d3d12).
- **Hạn chế:** D3D12 cần feature level 11_0 và resource binding tier 2 (không có Intel Haswell/Broadwell).
- **Hạn chế:** frame D3D11 chạy trên device D3D12 cùng adapter qua shared NT handle: cần Windows 10 1703+ và shared
  fence của D3D11.4, `d3d12.dll` được giữ tới hết tiến trình; dùng Agility SDK hay runtime D3D12 khác thì bị từ chối.
- **Hạn chế:** D3D12 chờ CPU tới khi lần submit trước xong ở mỗi frame (mất một frame chồng việc), vì upload D3D12 của
  FFmpeg không chờ fence.
- **Hạn chế:** texture array, frame lớn hơn kích thước link, output không có UAV, và input D3D11 không share được
  (`hwupload`, decoder) phải chép thêm trên GPU.
- **Đã test (RTX 4060 Laptop, Intel UHD):** decode `-hwaccel d3d12va` -> gpufx -> `h264_d3d12va`/`hevc_d3d12va` (nv12,
  p010 main10) không cần `hwdownload`; encoder nhận nguyên frame của gpufx (có UAV). Trên NVIDIA thêm `-bf 0`:
  encoder D3D12 của nó lỗi khi có B-frame (driver 617.42, không có gpufx cũng lỗi). `av1_d3d12va` không được driver
  RTX 4060 Laptop hỗ trợ.
- **Đã test:** decode `-hwaccel d3d11va` -> gpufx -> `h264_nvenc`/`hevc_nvenc` (RTX 4060) và, qua
  `hwmap=derive_device=qsv,format=qsv`, `h264_qsv` (Intel UHD). NVENC và QSV đọc texture ngoài immediate context, nên
  gpufx chờ trên CPU tới khi output D3D11 xong (không chồng lấn với frame sau).
- **Hạn chế:** `out_api=d3d11` (input D3D12, output D3D11) cần một device D3D11 cùng adapter làm `-filter_hw_device`
  (`-init_hw_device d3d11va=d11:N -filter_hw_device d11`); thiếu thì filter từ chối.
- **Đã test:** `out_api=d3d11` với decode `-hwaccel d3d12va` -> gpufx -> `h264_nvenc`/`hevc_nvenc` (cả p010 main10)
  trên RTX 4060 Laptop (2026-10-24).
- `out_api=d3d11` -> `h264_qsv` đã chạy tay trên Intel UHD (bộ test chạy adapter 0 là NVIDIA nên bỏ qua). Decoder H.264 `d3d12va` của FFmpeg treo trên driver Intel đó khi decode đa luồng, có hay không có gpufx: thêm `-threads 1` trước `-i`, hoặc decode bằng `d3d11va`.

## VideoToolbox (macOS)

- **Chưa test:** toàn bộ đường VideoToolbox/Metal (xem phần trên); không có bundle macOS để tải.
- **Hạn chế:** cần Apple silicon (unified memory), chỉ `nv12`/`p010le`; Mac Intel bị từ chối. Input CPU không phải
  4:2:0 và frame VideoToolbox BGRA/RGBA không nhận. Output `p010le` cần storage R16/RG16 (GPU không phải Apple thì
  lỗi). Không có fence: mỗi frame chờ CPU.
- **Hạn chế:** Metal không có cache shader trên đĩa.

## Nội suy khung hình (`gpufx_ai_framerate`)

- **Chưa test:** đường VideoToolbox (macOS) của `gpufx_ai_framerate` (`gpufx_ai_interp_*_videotoolbox`); chưa từng
  chạy trên máy Mac.
- **Chưa test:** `gpufx_ai_framerate` và `packages/gpufx_ai_framerate/rife-v4.6.zip` trong bundle linux64; mới chỉ chạy filter trên Windows.
- **Hạn chế:** D3D12 và D3D11 chậm hơn Vulkan khoảng 1,7 lần trên cùng GPU (RTX 4060 Laptop, 1080p: Vulkan khoảng
  45 ms mỗi frame, 4K khoảng 174 ms); nên dùng Vulkan.

## Tăng độ phân giải bằng AI (`gpufx_ai_upscale`)

- **Chưa test:** đường VideoToolbox chưa từng chạy. Vulkan, D3D12 và D3D11 khớp bản tham chiếu CPU trong bundle win64
  (97,5 dB f32, 57,9 dB f16); linux64 mới chạy trên lavapipe.
- **Hạn chế:** không realtime: một frame 1080p x2 mất khoảng 480-510 ms trên D3D11/D3D12 (f16) và khoảng 690 ms trên
  Vulkan, RTX 4060 Laptop.
- **Hạn chế:** trên device Vulkan do FFmpeg tạo, `precision=auto` chạy f32: device đó không bật các tính năng 16-bit mà
  wgpu cần cho f16.
- **Hạn chế:** frame đi qua RGBA 8-bit (đầu vào và đầu ra của model): input 10-bit mất phần bit thêm, alpha không
  được giữ.

## Định dạng, màu, alpha, HDR

- **Hạn chế:** GPU chỉ chuyển `nv12`, `p010le`, `yuv420p`/`422p`/`444p` (cả bản `10le`), `yuva420p`/`444p`, `rgba`,
  `rgba64le`. Các dạng khác (12/16 bit, `p016`, `nv21`, `nv16`, `gray`...) và các matrix FCC, SMPTE240M, YCgCo,
  BT.2020 constant luminance đi qua swscale. swscale coi `gray` là full range, nên gray limited range bị đổi sai.
- **Hạn chế:** HDR (PQ/HLG) được xử lý như SDR, không tonemap, chỉ có cảnh báo; output mất metadata HDR10 (mastering
  display, content light level), ICC, film grain, motion vector.
- **Hạn chế:** input trên 10 bit tính bằng half float (khoảng 11 bit); input interlaced bị coi là một frame; EXR float
  premultiplied qua swscale thành `rgba64le`, mất giá trị ngoài 0..1.
- **Hạn chế:** lọc chroma khác swscale (lệch trung bình khoảng 1,4 mức 8-bit ở cạnh sắc); frame YUV không gắn tag màu
  được đoán khác FFmpeg (đặt `setparams=range=tv:colorspace=bt709` để khớp).
- **Hạn chế:** `passthrough=off` (hoặc khi không gắn nhãn được) thì gpufx đang tắt vẫn chép qua YUV→RGBA→YUV; 5 lần
  liên tiếp làm chroma còn khoảng 37 dB.
- **Hạn chế:** mẫu 16 bit đọc theo little-endian; máy big-endian cho màu sai (chưa có máy để thử).

## Upload / download

- **Hạn chế:** `gpufx` chỉ xuất frame GPU; input CPU được nó tự upload, và upload lại ở mỗi event kể cả khi input
  phụ chỉ lặp lại frame cũ. Ảnh tĩnh thành video: đặt `loop` sau `hwupload` để chỉ upload một lần.
- **Hạn chế:** `gpufx_upload`/`gpufx_download` chỉ có cho Vulkan; đổi kích thước frame giữa chừng trả EINVAL; với
  input thưa (live) mỗi frame trễ `latency` frame.

## Effect, tham số, biểu thức, graph

- **Hạn chế:** texture trong gói luôn là `rgba8unorm` (PNG 16 bit bị hạ còn 8 bit), tối đa 4096 px mỗi cạnh và 64 M
  texel mỗi gói. Particle tối đa khoảng 256 sprite mỗi pass, không có particle có trạng thái.
- **Hạn chế:** effect thu nhỏ ảnh (`fit`, `push-box`, `photo-collection`) không dùng mipmap của input, ảnh lớn có
  thể răng cưa hoặc nhấp nháy.
- **Hạn chế:** biểu thức tham số không có vector, phép so sánh hay `if`; biểu thức FFmpeg hợp lệ mà gpufx không hiểu
  (vd `random`) chỉ báo lỗi ở frame đầu; đổi biểu thức thì biên dịch lại pipeline của effect đó.
- **Hạn chế:** trong chuỗi `a.zip|b.zip` chỉ effect đầu được có nhiều input; đổi kích thước hay định dạng input giữa
  chừng là lỗi.
- **Hạn chế (graph):** framesync bám theo output 0, output 0 đóng trước thì mọi output dừng; pts và thuộc tính frame
  của mọi output lấy từ input 0; nhãn gõ sai thành output thừa; đường dẫn gói trong `graph=` không được chứa
  `[ ] ; |`; mỗi filter `gpufx` có pool texture riêng (nhiều filter tốn VRAM hơn một `graph=`).
- **Hạn chế:** cache gói giữ lock toàn cục lúc nạp và không phát hiện file gói đổi.

## Shader cache, gói, an toàn

- **Hạn chế:** shader D3D12 biên dịch sẵn trong gói (`gpufx pack --precompile`) chỉ được dùng khi đặt
  `GPUFX_TRUST_PRECOMPILED=1`, và cờ này tin mọi gói; gói chưa được ký. Blob biên dịch sẵn chỉ ứng với giá trị
  `expr` mặc định. Cache DXIL cần `dxcompiler.dll` trên đường dẫn DLL.
- **Hạn chế:** shader lặp vô hạn có thể treo GPU; chưa có giới hạn thời gian dispatch.

## Build và bundle

- **Hạn chế:** chưa có bundle macOS. Bundle prebuilt dùng FFmpeg dựng sẵn của FFmpegBuild; libavutil được build lại
  (có bản vá) trong docker image của BtbN (`ghcr.io/btbn/ffmpeg-builds/<target>-lgpl-9.0`, ghim theo digest), nên
  build cần docker. Image đó chỉ có tag `latest`: BtbN xoá bản cũ thì phải đổi digest.
  `avfilter-12.dll`/`gpufx.dll` dùng msvcrt trong khi các DLL khác dùng UCRT.
- **Hạn chế:** `build-prebuilt.sh` tải bản FFmpeg dựng sẵn không kiểm sha256.
- **Hạn chế:** build mặc định `FFMPEG_FILTERS=all` có filter GPL; `FFMPEG_FILTERS=keep` cho bản nhỏ.

## Định dạng frame D3D11/D3D12

FFmpeg gốc chỉ cho frame D3D12 dạng `nv12`/`p010le`, còn D3D11 không có `rgba` (chỉ có `bgra`). Vì vậy ảnh hay
video có alpha không lên được D3D, kể cả qua `hwupload` hay bước upload có sẵn trong `gpufx`. Bản vá trong
[`ffmpeg/patches/`](../ffmpeg/patches) cho hai backend nhận mọi định dạng có ở cả DXGI lẫn FFmpeg CPU.
[`ffmpeg/integrate.sh`](../ffmpeg/integrate.sh) áp bản vá bằng `patch -p1` lên bản sao source lúc build;
`external/FFmpeg` không bị sửa.

### Định dạng được thêm

| DXGI | FFmpeg | D3D11 | D3D12 |
|---|---|---|---|
| R8G8B8A8_UNORM | `rgba` | thêm | thêm |
| B8G8R8A8_UNORM | `bgra` | có sẵn | thêm |
| B8G8R8X8_UNORM | `bgr0` | thêm | thêm |
| R10G10B10A2_UNORM | `x2bgr10le` | có sẵn | thêm |
| R16G16B16A16_UNORM | `rgba64le` | thêm | thêm |
| R16G16B16A16_FLOAT | `rgbaf16le` | có sẵn | thêm |
| R32G32B32A32_FLOAT | `rgbaf32le` | thêm | thêm |
| R32G32B32_FLOAT | `rgbf32le` | thêm | thêm |
| B5G6R5_UNORM | `rgb565le` | thêm | thêm |
| R8 / R16 / R16_FLOAT / R32_FLOAT | `gray` / `gray16le` / `grayf16le` / `grayf32le` | thêm | thêm |
| NV12, P010 | `nv12`, `p010le` | có sẵn | có sẵn |
| P016 | `p016le`, `p012le` | có sẵn | thêm |
| P208 | `nv16` | thêm | thêm |
| YUY2 | `yuyv422` | có sẵn | thêm |
| Y210 / Y216 | `y210le` / `y216le`, `y212le` | có sẵn | thêm |
| AYUV | `vuyx`, `vuya` | `vuya` thêm | thêm |
| Y410 / Y416 | `xv30le` / `xv48le`, `xv36le` | có sẵn | thêm |

D3D12 còn được viết lại phần chép dữ liệu (`d3d12va_transfer_data`): layout lấy từ `GetCopyableFootprints` và chép
theo từng plane, thay cho layout viết cứng NV12/P010. Frame nằm trong texture array được chép đúng slice của nó;
code cũ luôn chép slice 0.

### Đã test

Dữ liệu ngẫu nhiên qua `hwupload` → `hwdownload`, so `framemd5` với input. Phải giống từng bit. Dùng một
`ffmpeg.exe` tĩnh thu gọn build từ submodule đã áp vá (FFmpeg n9.0), kích thước 320x240 và 318x238.

| | NVIDIA RTX 4060 Laptop | Intel UHD Graphics |
|---|---|---|
| D3D11 | đạt mọi định dạng trong bảng, trừ các định dạng GPU không hỗ trợ (dưới đây) | đạt các định dạng đã thử, kể cả `p016le`/`p012le` |
| D3D12 | như D3D11 | như D3D11 |

Trên Intel chỉ thử `nv12`, `p010le`, `p016le`, `p012le`, `nv16`, `rgba`, `bgra`, `rgbaf16le`, `gray`, `yuyv422`,
`vuya`.

Bundle win64 (libavutil build lại có bản vá): `test-bundle.sh` kiểm round-trip `rgba`, `bgra`, `gray`, `gray16le`,
`rgba64le`, `yuyv422` và ảnh PNG có alpha qua `rgba,hwupload,loop,gpufx=...:out_format=rgba,hwdownload` trên
D3D11 và D3D12 (giữ alpha, giống kết quả Vulkan); `-init_hw_device list` vẫn đủ 9 loại thiết bị.

### Hạn chế

- **FFmpeg không có bản vá: frame D3D không có alpha.** `hwdownload` chỉ ra `nv12`/`p010le`
  (D3D12) hoặc không có `rgba` (D3D11), nên output có alpha mất alpha ở đây, và `out_format=rgba`, `yuva420p` hay
  `yuva444p` báo lỗi (`Unsupported pixel format: rgba`). Vulkan giữ alpha với `out_format=rgba`. Trên D3D, tách kết
  quả làm hai và cho một bản đi qua [alpha-extract](../packages/gpufx/ffmpeg/alpha-extract/README.md) để lấy alpha
  thành ảnh xám, rồi ghép hai bản trên CPU bằng `alphamerge`.
- **libavutil của bundle prebuilt là bản build lại.** `scripts/build-avutil.sh` build lại libavutil trong image
  của BtbN với đúng dòng configure lưu trong bản dựng sẵn, rồi kiểm export, thư viện nạp lúc chạy và các loại thiết
  bị phần cứng không đổi. Thư viện phụ thuộc trong image có thể mới hơn bản FFmpegBuild đã dùng (được link tĩnh
  vào libavutil). Bản build Docker đầy đủ (`build.sh`) có bản vá nhưng không có D3D12 (mingw của Ubuntu thiếu
  `d3d12video.h`).
- **GPU không hỗ trợ định dạng thì định dạng đó bị loại.** Danh sách định dạng được lọc qua
  `CheckFormatSupport`/`CheckFeatureSupport`. Định dạng bị loại không báo lỗi: FFmpeg tự chuyển sang định dạng khác
  (vd RTX 4060 không có `p016le`/`p012le`, nên `hwupload` nhận `y216le` sau một bước chuyển của swscale).
- **Filter D3D dùng video processor có thể nhận định dạng chúng không xử lý được.** `scale_d3d12`,
  `deinterlace_d3d12`... chọn định dạng theo danh sách của frames context, nay dài hơn trước. Lỗi chỉ lộ lúc chạy,
  không lộ lúc chọn định dạng. Chuyển về `nv12` trước các filter đó.
- **`gpufx` chưa đọc hết các định dạng mới.** `bgra`, gray, float... lên được D3D nhưng `gpufx` từ chối.
- **Bản vá D3D12 lớn.** Phần chép dữ liệu được viết lại, nên dễ không áp được khi nâng FFmpeg. Khi đó
  `integrate.sh` dừng build và báo tên bản vá.

### Chưa test

- **`nv16` (DXGI P208):** cả hai GPU đã thử đều không hỗ trợ texture P208, nên dòng này chưa chạy thật lần nào.
- **Frame trong texture array (D3D12):** chỉ gặp khi decode bằng D3D12 (`-hwaccel d3d12va`) rồi `hwdownload`;
  chưa thử. Chỉ số subresource tính là `slice + plane × initial_pool_size`, đúng với texture array do chính frames
  context tạo (một mip level).
- **Định dạng ngoài danh sách đã thử trên Intel UHD:** chỉ thử trên RTX 4060.
- **Các filter dùng video processor** (`scale_d3d12`, `deinterlace_d3d12`, `scale_d3d11`) với các định dạng mới.
- **libavutil build lại trên Linux:** mới kiểm export, thư viện nạp và loại thiết bị lúc build; vaapi/cuda/qsv/
  opencl chưa chạy thật với nó. Trên Windows mới chạy thật Vulkan/D3D11/D3D12.
