English: [README.md](README.md)

# Thiết kế: FFmpegGpuFilter (gpufx)

> Mục tiêu: chạy hiệu ứng video bằng **shader trên GPU** trong `filter_graph` của FFmpeg,
> với hiệu ứng được **nạp từ gói `.zip` bên ngoài** (kiểu CapCut). Thêm hiệu ứng mới không
> cần build lại FFmpeg: chỉ cần đưa gói zip, tham số, và nối input/output trong graph.

## 1. Yêu cầu

| # | Yêu cầu | Cách đáp ứng |
|---|---------|--------------|
| R1 | **Shader là ưu tiên số 1** (lý do dùng GPU) | Mỗi hiệu ứng *là* một chuỗi compute shader. Hỗ trợ WGSL và GLSL ngay từ bản đầu, kiểm tra lỗi shader có số dòng, nhiều pass, texture đi kèm, tham số tự sinh thành `uniform` |
| R2 | Đa hệ điều hành | Windows, Linux, macOS (Android/iOS về sau) |
| R3 | Đa phần cứng / API | Vulkan, DirectX 12, Metal qua **wgpu**; CUDA/D3D11/VAAPI qua interop (giai đoạn 2). Đã bỏ OpenGL: không dùng chung frame với FFmpeg được và không có texture storage R8/R16 cho các plane YUV |
| R4 | Hiệu ứng nạp ngoài, không build lại FFmpeg | Một filter duy nhất `gpufx` build **một lần**; hiệu ứng là gói zip |
| R5 | Dùng Rust hoặc C/C++ | Engine viết bằng **Rust**; phần nối vào FFmpeg là một file C nhỏ |

## 2. Tổng quan kiến trúc

```mermaid
flowchart TB
    cmd["ffmpeg -vf &quot;gpufx=graph='vignette.zip=strength=0.8'&quot;"]
    filter["<b>libavfilter/vf_gpufx.c</b><br/>- option graph<br/>- pad input động theo manifest (1..N input)<br/>- framesync nhiều input<br/>- biểu thức theo t, n<br/>- sendcmd / timeline"]
    lib["<b>libgpufx</b> (Rust, crates/gpufx-ffi)<br/>gpufx-core:<br/>package: đọc zip / thư mục<br/>manifest: schema, kiểm tra<br/>params: layout uniform<br/>runtime: biên dịch shader, chạy pass trên wgpu"]
    wgpu(["wgpu"])
    vk[Vulkan]
    dx[DirectX 12]
    mtl[Metal]
    web["(WebGPU)"]

    cmd --> filter
    filter -- "C ABI (gpufx.h)" --> lib
    lib --> wgpu
    wgpu --> vk
    wgpu --> dx
    wgpu --> mtl
    wgpu --> web
```

**Vì sao chỉ một filter?** FFmpeg không có cơ chế plugin filter lúc chạy: mọi filter phải
được biên dịch vào `libavfilter`. Vì vậy ta thêm *một* filter chung `gpufx` (patch một lần,
xem `ffmpeg/integrate.sh`), còn toàn bộ logic hiệu ứng nằm trong shader của gói zip. Đây
chính là mô hình CapCut: app cố định, hiệu ứng là dữ liệu tải về.

**Vì sao Rust + wgpu?**
- wgpu là lớp trừu tượng GPU đã chín, chạy Vulkan/DX12/Metal/GL từ cùng một mã nguồn.
- Đi kèm **naga**: trình biên dịch shader thuần Rust, đọc WGSL, GLSL, SPIR-V và dịch sang
  SPIR-V/HLSL/MSL/GLSL cho từng backend. Đây là phần quan trọng nhất cho R1: tác giả viết
  shader **một lần**, chạy trên mọi API.
- Rust an toàn bộ nhớ khi đọc gói zip không tin cậy; xuất C ABI ổn định cho FFmpeg.

Phương án đã cân nhắc và loại:

| Phương án | Lý do không chọn làm lõi |
|-----------|---------------------------|
| Vulkan + SPIR-V trực tiếp (như `libplacebo`) | Không chạy native trên macOS/DX; phải tự viết lại phần wgpu đã có |
| Viết riêng CUDA/DX/Vulkan cho từng hiệu ứng | Trái R4: mỗi hiệu ứng × mỗi API |
| OpenCL (`vf_program_opencl`) | Driver kém đồng đều, không có trên macOS mới, không phải shader đồ hoạ |
| Gắn vào `libplacebo` custom shader | Chỉ Vulkan, cú pháp mpv hook, không hỗ trợ nhiều input |

## 3. Gói hiệu ứng (`.zip`)

```
vignette.zip
├── manifest.json        bắt buộc
├── shaders/*.wgsl|*.comp|*.glsl
└── textures/*.png       tuỳ chọn (LUT, mask, overlay)
```

Chi tiết định dạng và cách viết shader: [EFFECT_FORMAT-vi.md](../EFFECT_FORMAT-vi.md).

Tóm tắt `manifest.json`:

```json
{
  "api": 1,
  "id": "io.github.tqk2811.gaussian-blur",
  "name": "Gaussian Blur",
  "used_for": ["gpufx"],
  "inputs": [
    { "name": "src" }
  ],
  "params": [
    {
      "name": "radius",
      "type": "float",
      "default": 6,
      "min": 0,
      "max": 48
    }
  ],
  "groups": [
    {
      "passes": [
        {
          "shader": "shaders/blur_h.wgsl",
          "inputs": ["src"],
          "outputs": ["tmp"]
        },
        {
          "shader": "shaders/blur_v.wgsl",
          "inputs": ["tmp"],
          "outputs": ["out"]
        }
      ]
    }
  ]
}
```

- `inputs` quyết định số pad input của filter (transition dùng 2 input, v.v.). Input cuối có thể mang `repeat`
  (chỉ WGSL, `{default, min, max <= 16}`): nó mở thành các pad `<name>0..N-1`, N = số nhãn mà node graph đọc
  (`default` nếu không có nhãn); prelude thêm `gpufx_input_count/size/load`.
- Output cuối cũng có thể mang `repeat` (chỉ WGSL): option node `outputs=N` (mặc định là `default`) nở nó thành các
  output `<name>0..N-1`, tổng cộng tối đa 4 output. Cách hoạt động, cho lập trình viên:
  - **Nở**: [`Manifest::with_output_count`](../../crates/gpufx-core/src/manifest.rs#L835) thay output bằng các bản sao (cùng
    `bypass`) và thay tên trong mọi danh sách `outputs`/`inputs` của pass bằng tên các bản sao, tại chỗ, rồi validate lại,
    nên runtime và graph chỉ thấy manifest có output cố định.
  - **Giữ cả hai số**: [`Package`](../../crates/gpufx-core/src/package.rs#L17) giữ manifest như lúc viết; số bản sao
    lưu thẳng trong package (`input_copies`, `output_copies`), không suy từ hiệu số độ dài; `with_output_count`
    và `with_input_count` nở lại từ đó và giữ nguyên số còn lại, nên node graph vừa gán input `repeat` theo tên vừa có
    `outputs=N` không mất N.
  - **Option**: [graph.rs](../../crates/gpufx-core/src/graph.rs#L1328) lấy `outputs=N` ra khỏi inline option lúc mở package
    của node và dựng lại effect cho N (option không tới phía gọi như một param). Lệnh runtime `node.outputs` bị
    [`find_param`](../../crates/gpufx-core/src/graph.rs#L1958) từ chối: số pad đã chốt. Output pad của graph, tức `nb_outputs` của
    filter `gpufx`, suy ra từ effect đã nở như mọi effect.
  - **Bind**: bản sao là output pass bình thường, bind `out_tex`, `out_tex1`...; chỉ prelude của pass ghi chúng thêm `gpufx_output_count()`
    và `gpufx_write_at(i, ...)`, một `switch` theo output của pass, cùng `gpufx_copy_count()` và `gpufx_write_copy(j, ...)`
    = `gpufx_write_at(first + j, ...)` với `first` là vị trí bản sao đầu trong danh sách của pass
    ([`pass_copies`](../../crates/gpufx-core/src/runtime.rs#L1080), [prelude](../../crates/gpufx-core/src/runtime.rs#L1129)).
    Pass khác không có gì thêm, nên source và key shader cache của chúng giữ như trước khi có tính năng này.
    `gpufx_output_size` chạy một lần cho mỗi bản sao với chỉ số output effect của nó, và luật "một pass, một kích thước"
    có sẵn áp cho các bản sao.
  - **Kiểm lúc nạp**: `max` lớn hơn số vừa bên cạnh các output khác, và tên khác dạng `<name>d+`, bị từ chối ở
    [`validate`](../../crates/gpufx-core/src/manifest.rs#L604); output không ghi `max` thì `parse` đặt bằng số vừa.
- Output có thể `optional`: option node `<name>=off` tắt nó. Cách làm, cho lập trình viên:
  - **Bỏ hẳn, không phải cờ**: [`Manifest::with_outputs_off`](../../crates/gpufx-core/src/manifest.rs#L951) chuyển output
    từ `outputs` sang `off_outputs`, chạy trước `with_output_count` (nên kiểm 4 output sau khi nở chỉ đếm output còn lại);
    graph, FFI và filter `gpufx` thấy một effect ít output hơn, `nb_outputs` theo đó mà phía C không phải sửa.
    [`Package::with_outputs`](../../crates/gpufx-core/src/package.rs#L87) dựng lại từ manifest gốc (giữ cho mọi package có
    output tuỳ chọn) và giữ danh sách tắt cạnh số bản sao.
  - **Pass giữ nguyên binding**: pass vẫn liệt kê texture đó, nên `out_tex{k}` và `gpufx_write{k}` còn nguyên, shader biên
    dịch không đổi; [`make_bound`](../../crates/gpufx-core/src/runtime.rs#L991) bind nó vào một texture thế chỗ 1x1 đúng
    format làm việc, và [`plan`](../../crates/gpufx-core/src/graph.rs#L405) không cấp texture pool cho nó. Ghi storage ngoài
    khoảng bị bỏ (hoặc rơi vào texture thế chỗ), nên ghi vào đó không hiện ra đâu. Pass chỉ ghi output đã tắt thì
    `set_used_outputs` có sẵn bỏ qua (không ai cần).
  - **Không gì đọc output tuỳ chọn** (kiểm ở `validate`): không thì pass sau sẽ đọc texture thế chỗ.
  - **Chỉ số size giữ như đã viết**: `off_indices` giữ vị trí của từng output đã tắt, và
    [`Manifest::size_index`](../../crates/gpufx-core/src/manifest.rs#L987) đổi một output còn lại (hoặc một bản sao,
    sau `with_output_count`) về chỉ số đó cho `gpufx_output_size`, nên shader định kích thước theo chỉ số không cần
    xét `off`. Các bước kiểm kích thước bỏ qua output đã tắt (texture thế chỗ không có kích thước riêng).
  - **Hàm hỗ trợ**: [`output_enabled`](../../crates/gpufx-core/src/runtime.rs#L1102) thêm `gpufx_output_enabled(i)` (mỗi
    output tắt một phép `i != k`, không có thì `true`) chỉ cho pass ghi output tuỳ chọn, giống các hàm của `repeat`: pass
    khác giữ nguyên source và key shader cache.
  - **Option** được lấy ra khỏi inline option ở [graph.rs](../../crates/gpufx-core/src/graph.rs#L1338) cùng `outputs=N`
    (dựng lại effect một lần cho cả hai); lệnh lúc chạy gọi tên output thì `find_param` báo lỗi.
- Kích thước output: mặc định bằng input đầu; shader đặt khác bằng hàm tuỳ chọn `gpufx_output_size(out_index)` của pass
  ghi output đó (chỉ đọc `params`, `gpufx_input_count()`, `gpufx_input_size(i)`). Tính một lần bằng một dispatch GPU lúc configure,
  từ giá trị param khi đó; 0 hoặc quá `max_texture_dimension_2d` của GPU là lỗi, đổi kích thước về sau thì xử lý báo lỗi. Các node graph phía sau thấy size đã lan truyền.
  Cách làm, cho lập trình viên:
  - **Tìm hàm**: pass có định kích thước output khi module naga của shader đã biên dịch có function tên đúng `gpufx_output_size`
    ([runtime.rs](../../crates/gpufx-core/src/runtime.rs#L1263)), không dò chuỗi trong source (comment không tính). Pass đó có thêm một pipeline một thread gọi hàm
    ([runtime.rs](../../crates/gpufx-core/src/runtime.rs#L540)).
  - **Param hàm đọc**: `params_read` ([runtime.rs](../../crates/gpufx-core/src/runtime.rs#L1418)) duyệt IR naga của entry point kích thước và mọi function nó gọi
    (`Statement::Call`, kể cả block lồng, [runtime.rs](../../crates/gpufx-core/src/runtime.rs#L1456)), ghi mỗi `AccessIndex` trên global `params` (group 0, binding 1)
    là đọc một field. Một field là cả một param: param `vec2`/`color` tính là một. Khi không quy được về field (đọc cả block,
    vd truyền hoặc copy cả struct, hay `Access` chỉ số động) thì coi như đọc mọi param: an toàn, không sót.
  - **Khi nào**: `Effect::output_sizes` ([runtime.rs](../../crates/gpufx-core/src/runtime.rs#L711)) tính kích thước một lần bằng dispatch + readback, giữ lại cùng kích
    thước input và giá trị các param đã đọc ([runtime.rs](../../crates/gpufx-core/src/runtime.rs#L604)). Không bao giờ dispatch trên noop device (báo lỗi,
    [runtime.rs](../../crates/gpufx-core/src/runtime.rs#L748)); C API, khi effect còn trên noop device, mở nó một lần trên device của backend để tính kích thước rồi
    dùng lại graph đó khi effect chuyển sang ([lib.rs](../../crates/gpufx-ffi/src/lib.rs#L562), [lib.rs](../../crates/gpufx-ffi/src/lib.rs#L396)). Filter FFmpeg đặt biểu thức param tại
    `t=0`, `n=0` trước khi hỏi ([vf_gpufx.c](../../ffmpeg/vf_gpufx.c#L2539)).
  - **Mỗi frame**: không có việc GPU. Giá trị các param đã đọc được so trên CPU với giá trị đã giữ; khác thì lỗi "parameter `w`
    sets the size of the output ... and must not change while the stream runs", kể cả khi kích thước vẫn như cũ. Param khác đổi
    thoải mái. Kích thước input khác thì tính lại (rồi bước kiểm kích thước của graph báo lỗi nếu đổi).
- `params` được runtime **tự sinh** thành struct `params` trong shader, đúng quy tắc căn lề
  uniform của WGSL/std140; tác giả chỉ việc dùng `params.radius`.
- `passes` chạy tuần tự; output của pass trước là texture đọc được ở pass sau; pass cuối là
  đầu ra.
- Effect có `groups`, các bộ pass thay thế nhau kèm `requires` về thiết bị (xem
  [EFFECT_FORMAT-vi.md](../EFFECT_FORMAT-vi.md#nhóm-pass-và-yêu-cầu-thiết-bị)). `Program::new` chọn group đầu tiên khớp
  thiết bị; trên device noop chỉ kiểm `os` và compile mọi group khớp OS mà noop device compile được để kiểm shader, nên việc mở
  gồm hai bước: device noop ở `gpufx_effect_open`, device thật sau đó.

## 4. Mô hình shader (trọng tâm)

Mỗi pass là một **compute shader**. Trước mã của tác giả, runtime chèn một *prelude* sinh tự
động (giống cách Shadertoy cung cấp `iResolution`, `iTime`):

| Binding | Tên trong shader | Ý nghĩa |
|---------|------------------|---------|
| 0 | `globals.size`, `globals.time`, `globals.frame`, `globals.time_int`, `globals.time_frac`, `globals.pixel_aspect` | Kích thước output (px), thời gian (giây, f32), số frame, thời gian chính xác (giây nguyên + phần lẻ), tỉ lệ cạnh của pixel (SAR) |
| 1 | `params.<tên>` | Tham số từ manifest |
| 2 | `out_tex` | Texture ghi kết quả (`rgba8unorm`, hoặc `rgba16float` khi chuỗi có frame trên 8 bit) |
| 3 | `smp` | Sampler tuyến tính, clamp, tuyến tính giữa các mức mip |
| 4.. | tên input/texture/pass | Texture đọc (`texture_2d<f32>`; `texture_2d_array<f32>` cho texture của gói có `layers`/`grid`) |

Sampler `smp` lọc tuyến tính cả giữa các mức mip. Texture của gói có thể là texture mảng
(`layers`, hoặc atlas cắt theo `grid`), có chuỗi mip sinh trên CPU và alpha premultiplied, làm một lần
khi nạp `Program`; kích thước ảnh được kiểm từ header PNG (4096 mỗi cạnh, 64 M texel mỗi gói, giới hạn
của device) trước khi giải mã. Input khai `mipmaps` được sinh chuỗi mip trên GPU mỗi frame ngay trong
texture của nó (slot input, hoặc texture trong pool của hiệu ứng ghi ra nó; texture có mip và không có
mip nằm ở hai pool riêng), không copy. Tham số `expr` được biên dịch vào shader thành
`gpufx_expr_<name>`, sinh từ cây đã parse; hiệu ứng có biểu thức khác mặc định tự dựng pipeline riêng khi
biểu thức đổi (`Program` giữ pipeline mặc định). Xem [EFFECT_FORMAT-vi.md](../EFFECT_FORMAT-vi.md).

Kèm hàm tiện ích `gpufx_in_bounds(id)`, `gpufx_uv(id)`, `gpufx_write(id, color)`.

Vì sao compute thay vì fragment shader: không cần render pass/vertex buffer, dễ làm nhiều
pass, đọc/ghi tự do (blur tách trục, histogram, reduce) và ánh xạ thẳng sang CUDA/Metal
compute khi cần.

Ngôn ngữ shader:

| Ngôn ngữ | Trạng thái | Ghi chú |
|----------|-----------|---------|
| WGSL | ✅ prototype | Ngôn ngữ chuẩn của WebGPU, lỗi rõ ràng nhất |
| GLSL 450 (compute) | ✅ prototype | Thuận tiện để port shader có sẵn (GL Transitions, Shadertoy) |
| SPIR-V (biên dịch sẵn) | Kế hoạch | Cho tác giả dùng HLSL/Slang → SPIR-V bằng công cụ ngoài |
| HLSL / Slang | Kế hoạch | Biên dịch trong `gpufx pack` sang SPIR-V/WGSL |
| Fragment shader kiểu Shadertoy (`mainImage`) | Kế hoạch | Bọc tự động thành compute |

Kiểm tra shader trước khi chạy: naga phân tích và validate, lỗi trả về kèm tên file và vị
trí trong mã (thử: `gpufx check <gói>`). Filter FFmpeg in lỗi đó qua `av_log` và từ chối khởi
tạo graph thay vì chạy sai.

## 5. Filter FFmpeg `gpufx`

Tham chiếu đầy đủ (cú pháp, option, lệnh runtime, ví dụ): [filters/gpufx-vi.md](filters/gpufx-vi.md).
Các filter khác: [gpufx_upload / gpufx_download](filters/gpufx_transfer-vi.md),
[gpufx_ai_framerate](filters/gpufx_ai_framerate-vi.md), [gpufx_ai_upscale](filters/gpufx_ai_upscale-vi.md).

Lý do thiết kế:

- **Một option duy nhất, `graph`.** Một effect, một chuỗi (`a.zip|b.zip`) và cả graph có nhãn nhiều input và output đều là
  một chuỗi, qua cùng một đường parse (một effect là graph tuyến tính một node). Số input pad và output pad lấy từ
  graph, nên `-filter_complex` của FFmpeg nối filter này như mọi filter khác.
- **Một lần submit GPU cho mỗi sự kiện.** Mọi pass của mọi effect trong filter, với texture trung gian lấy từ pool, chạy
  trong một lần submit; giữa các effect không có frame nào rời GPU và không có gì phải chuyển đổi. Nhiều filter `gpufx`
  nối nhau cũng giữ frame trên GPU (`out_format=rgba` bỏ chuyển đổi YUV ở giữa).
- **Chỉ trả ra frame GPU**, giống các filter `*_cuda`: output là hardware frame của API của device (Vulkan, D3D12, D3D11,
  VideoToolbox), nên `hwdownload` / `gpufx_download` đứng trước filter CPU và encoder. Input CPU do chính filter upload,
  nên pipeline một filter không cần `hwupload`. Device lấy từ input GPU, không thì `-filter_hw_device`; loại device quyết
  định API. Thêm một API là thêm một dòng vào `hw_apis[]` và các nhánh trong các switch theo API của `vf_gpufx.c`.
- **Tham số là biểu thức FFmpeg**, viết inline cạnh package và tính mỗi frame (`t`, `n`, `w`, `h`...), nên keyframe và
  transition không cần tool ngoài; `sendcmd` / `zmq` đổi chúng trong khi stream chạy.
- **Tắt một effect không cấp phát gì.** `enable=` / `bypass=` inline biến effect thành bản copy của một input, nên plan,
  texture trong pool và binding giữ nguyên, bật/tắt không cấp phát. `enable=` ở mức filter có thể đưa texture input đi
  tiếp mà không copy trên GPU (`passthrough`), và `bypass=auto` phục vụ transition cần tiếp tục hiện clip nó kết thúc ở đó.
- **Framesync khi có nhiều input.** Input đầu quyết định độ dài, frame rate, SAR và (trừ khi `gpufx_output_size` của effect cho kích thước khác) kích thước; input khác lặp, bỏ hoặc giữ frame để theo nó.
- **Kiểm chặt lúc configure**, báo lỗi nêu tên effect, input và key, thay vì chuyển đổi lặng lẽ.

Đường đi của frame phía sau nằm ở [mục 6](#6-đường-đi-của-frame-và-hiệu-năng). Shader nhận gì (prelude, binding, dispatch,
màu): [EFFECT_FORMAT-vi.md](../EFFECT_FORMAT-vi.md#tham-chiếu-shader-shader-nhận-gì-ngoài-parameter).

## 6. Đường đi của frame và hiệu năng

**Hiện tại (P1 xong):** các plane của frame trong RAM → upload texture → pass chuyển đổi dựng sẵn →
các pass của hiệu ứng → pass chuyển đổi dựng sẵn → copy về RAM. libgpufx tự chuyển `rgba`,
`rgba64le`, `nv12`, `p010le`, `yuv420p`/`yuv422p`/`yuv444p` và bản `10le`, `yuva420p`, `yuva444p`
(và tên gọi `yuvj`):

- Mỗi plane được upload vào một texture số nguyên (`r8uint`, `rg8uint`, `r16uint`, `rg16uint`,
  `rgba16uint`: format cơ bản của WebGPU, có trên mọi backend, khác với `r16unorm` cần feature chỉ có
  trên native). Một pass compute áp ma trận (BT.601, BT.709, BT.2020 non-constant luminance) và range
  (limited/full) của `AVFrame`, nội suy chroma bilinear theo vị trí chroma (left, center, top-left,
  top, bottom-left, bottom; không rõ thì left) rồi ghi texture RGBA mà hiệu ứng đầu đọc thẳng. RGBA
  8-bit straight bỏ qua pass này.
- Ở output, một pass đổi kết quả RGBA sang format output (chroma lấy mẫu xuống bằng lọc tam giác,
  `[1 3 3 1]` khi ở giữa, `[1 2 1]` khi co-sited), đóng gói từng plane vào storage buffer, copy sang
  một buffer map được rồi đọc về.
- Texture RGBA là `rgba16float` khi chuỗi có frame (input hoặc output) trên 8 bit, nên 10-bit giữ
  được qua chuỗi; còn lại là `rgba8unorm`. PNG trong gói vẫn là `rgba8unorm`.
- Filter: input nhận thẳng các format này (FFmpeg đổi format khác sang một trong
  số đó; manifest không có trường `formats`, shader luôn thấy RGBA). Format, ma trận (FCC, SMPTE 240M, YCgCo…) và BT.2020
  constant luminance mà libgpufx không xử lý thì vẫn đổi bằng `swscale` sang `rgba` (hoặc `rgba64le`
  khi trên 8 bit) như trước. Output không bao giờ qua swscale: filter chỉ xuất frame GPU (xem "Format GPU không chuyển
  được"). Output được xuất mọi format này (mặc định: format của input nguồn, xem bên dưới), nên encoder CPU nhận `yuv420p`
  cần `hwdownload` sau `gpufx` nhưng không cần `scale`. Output đó có thể là YUV không alpha, bỏ alpha mà hiệu ứng ghi:
  muốn giữ thì dùng `out_format=rgba` (hoặc `yuva420p`).
- Vị trí chroma không rõ thì là center với frame full range (JPEG/MJPEG), còn lại là left.
- Mỗi gói biên dịch pipeline `rgba8unorm` lúc nạp, pipeline `rgba16float` khi gặp frame trên 8 bit
  đầu tiên (frame đó chờ biên dịch; lỗi có ghi tên gói).
- `GPUFX_API_VERSION` chỉ tăng khi thêm mới: filter nhận thư viện có version không nhỏ hơn header.
- Filter bị tắt (timeline) đổi input 0 sang format output trên GPU mà không chạy hiệu ứng.

Các filter `gpufx` trong cùng process dùng chung một GPU device.

Device xin giới hạn mặc định của wgpu, trừ kích thước buffer (`device_limits` trong `crates/gpufx-core/src/runtime.rs`, dùng ở
chỗ `runtime.rs` tạo device và ở `vulkan.rs` cho `VkDevice` dùng chung của FFmpeg). Đây là chủ ý: package thấy cùng một giới hạn
(16 texture đọc và 4 texture ghi mỗi pass...) trên mọi GPU nên chạy được ở mọi nơi. Muốn nâng sau này thì phải xin giới hạn của
adapter dưới một mức trần chung và kiểm từng pass theo device.

Gói đã nạp cũng được dùng chung. Mỗi gói (khoá theo đường dẫn tuyệt đối và GPU device) chỉ
được đọc và biên dịch một lần trong process: `Program` gồm manifest, pipeline, texture PNG,
sampler. Mỗi filter giữ một `Effect` riêng gồm giá trị tham số, uniform buffer và texture
frame. Khi không còn filter nào dùng gói thì `Program` được giải phóng, lần mở sau đọc lại
file. Sửa file zip khi vẫn còn filter dùng gói đó thì không có tác dụng, kể cả với filter
mở gói sau khi sửa.

Chi phí chính là upload/readback và chuyển màu trên CPU. Lộ trình bỏ dần:

| Giai đoạn | Thay đổi | Lợi ích |
|-----------|----------|---------|
| P1 (xong) | Chuyển YUV (NV12/P010/yuv420p…) ↔ RGBA trên GPU trong runtime; texture `rgba16float` khi có frame trên 8 bit | Bỏ `swscale`, hỗ trợ 10-bit/HDR |
| P2 (xong, theo cách khác) | Filter `gpufx` chỉ xuất frame GPU nên không còn readback bên trong. Đọc về RAM do `gpufx_download` lo: nó gửi copy rồi chưa chờ ngay, giữ một vòng staging buffer (option `latency`, mặc định 2 frame) | Không chặn chờ frame trước khi đưa ra RAM |
| P3 (xong) | **Zero-copy** với `AV_PIX_FMT_VULKAN`: wgpu device tạo từ `AVVulkanDeviceContext` (`wgpu-hal` `device_from_raw`), đọc và ghi thẳng các `VkImage` của `AVVkFrame` (xem "Frame Vulkan" dưới đây) | Không qua RAM khi decode/encode bằng Vulkan |
| P4 (bỏ) | Interop **CUDA** (NVDEC/NVENC). Không làm: cần thêm một device wgpu bên cạnh CUDA context của FFmpeg (tốn thêm VRAM và RAM), semaphore dùng chung giữa hai API và mỗi chiều một lần copy GPU, mà không được thêm sức tính: Tensor Core đã gọi được từ WGSL qua cooperative matrix của Vulkan. Encode NVENC thì dùng `gpufx_download` (NVENC tự upload frame) | — |
| P5 (xong, chưa chạy trên phần cứng) | Frame **D3D12** tại chỗ trên `ID3D12Device` của FFmpeg; **D3D11** qua shared NT handle sang DX12 của wgpu (xem "Frame D3D12 và D3D11" bên dưới) | Dùng được với `hwupload` trên d3d12va/d3d11va; frame decoder tốn một lần copy GPU |
| P6 (xong VideoToolbox, chưa chạy trên máy Mac) | VideoToolbox (`CVPixelBuffer` → IOSurface → `MTLTexture`, xem "Frame VideoToolbox" bên dưới); VAAPI/DRM-PRIME (Linux) | Phủ hết hwaccel phổ biến |

Ở mọi giai đoạn, **định dạng gói và shader không đổi**: tác giả không cần biết frame đến từ
CPU hay CUDA.

### Chuyển đổi format dựng sẵn (format của frame ↔ RGBA)

Hiệu ứng không bao giờ thấy format của frame. gpufx-core bọc mỗi graph bằng hai stage compute dựng sẵn, ghi vào
cùng một lần submit GPU với các pass hiệu ứng (`run` cho frame CPU, [graph.rs](../../crates/gpufx-core/src/graph.rs#L680), và `run_gpu` cho frame GPU,
[graph.rs](../../crates/gpufx-core/src/graph.rs#L847)):

```mermaid
flowchart TD
    A["frame planes<br/>nv12, yuv420p10le, rgba64le ..."] --> B["convert in (convert_in*.wgsl)<br/>một texture RGBA cho mỗi input, alpha straight"]
    B --> C["effect passes<br/>luôn là rgba8unorm hoặc rgba16float, không bao giờ là plane YUV"]
    C --> D["convert out (convert_out*.wgsl)<br/>các plane của format output"]
    D --> E["frame planes của output"]
```

1. **Convert in**: `InputSlot::encode` ([convert.rs](../../crates/gpufx-core/src/convert.rs#L604)) ghi một dispatch cho
   mỗi input, đổi các plane thành texture RGBA mà pass hiệu ứng đầu tiên sample.
2. **Hiệu ứng**: texture của các pass là `rgba8unorm`, hoặc `rgba16float` khi graph "deep" (quy tắc bên dưới). Tác giả
   shader luôn thấy cùng một texture màu dù frame ban đầu là gì.
3. **Convert out**: với mỗi output của graph, một dispatch cho mỗi plane (đường buffer và image) hoặc một dispatch cho
   tất cả plane (đường fused YUV) ghi các plane của format output từ kết quả RGBA.

Stage nào chỉ là một bản copy thì bị bỏ qua. Input `rgba` straight từ CPU được upload thành `rgba8unorm` và đọc tại chỗ
(`InputKey::direct`, [convert.rs](../../crates/gpufx-core/src/convert.rs#L427), gán ở
[graph.rs](../../crates/gpufx-core/src/graph.rs#L535)). Input `rgba` straight là frame Vulkan được đọc tại chỗ khi graph
không deep và không hiệu ứng nào đọc mip chain của nó ([graph.rs](../../crates/gpufx-core/src/graph.rs#L548)); output GPU
`rgba` straight có thể do chính pass cuối của hiệu ứng ghi (`direct_out`, mô tả ở mục "Frame Vulkan").

Việc chuyển đổi **không** làm: không có transfer function (gamma/PQ/HLG) và không đổi primaries. Các giá trị trong
texture RGBA là R'G'B' phi tuyến mà ma trận cho ra, bất kể transfer là gì. Không có gì trong `gpufx-core` xử lý chúng
(`ColorInfo` của frame chỉ mang ma trận, range, vị trí chroma và cờ premultiplied), shader chỉ áp ma trận và range. Lớp C
sao primaries và transfer sang phía RGBA của một lần đổi bằng swscale để swscale cũng không ánh xạ chúng (`set_rgba_props`, [vf_gpufx.c](../../ffmpeg/vf_gpufx.c#L683)). Hiệu ứng nào cần
ánh sáng tuyến tính thì tự đổi transfer.

#### Các file

| File | Vai trò |
|------|---------|
| [convert.rs](../../crates/gpufx-core/src/convert.rs) | Phía Rust: `Converter` (pipeline theo device, [L52](../../crates/gpufx-core/src/convert.rs#L52)), `InputSlot` (stage input, [L440](../../crates/gpufx-core/src/convert.rs#L440)), `GpuOutputSlot` (output frame GPU, [L617](../../crates/gpufx-core/src/convert.rs#L617)), `OutputSlot` và `read_outputs` (output đọc về CPU, [L748](../../crates/gpufx-core/src/convert.rs#L748), [L875](../../crates/gpufx-core/src/convert.rs#L875)), `uniform` ([L370](../../crates/gpufx-core/src/convert.rs#L370)) |
| [convert.wgsl](../../crates/gpufx-core/src/convert.wgsl) | Ghép vào đầu mọi shader chuyển đổi: struct uniform `Conv` ([L5](../../crates/gpufx-core/src/convert.wgsl#L5)) và các hàm `code_max`, `code_scale`, `kg` |
| [convert_in.wgsl](../../crates/gpufx-core/src/convert_in.wgsl) | `pixel(id)`: plane sang RGBA straight của một pixel (range, upsample chroma, ma trận, alpha). Không có entry point |
| [convert_in_plain.wgsl](../../crates/gpufx-core/src/convert_in_plain.wgsl) | Entry point, workgroup 8x8, chroma đọc thẳng từ plane (frame upload từ CPU) |
| [convert_in_tiled.wgsl](../../crates/gpufx-core/src/convert_in_tiled.wgsl) | Entry point, workgroup 16x16, chroma nạp một lần vào workgroup memory (frame GPU) |
| [convert_out.wgsl](../../crates/gpufx-core/src/convert_out.wgsl) | Dùng chung cho mọi đường output: `fetch` (clamp, premultiply), `yuv`, `sample` (lấy mẫu xuống chroma), `encode` (range, depth, shift), `channel`. Không có entry point |
| [convert_out_buffer.wgsl](../../crates/gpufx-core/src/convert_out_buffer.wgsl) | Entry point: một plane đóng gói vào các word `u32` của storage buffer (đọc về CPU) |
| [convert_out_image.wgsl](../../crates/gpufx-core/src/convert_out_image.wgsl) | Entry point: một plane vào storage texture unorm (frame GPU, format RGBA) |
| [convert_out_fused.wgsl](../../crates/gpufx-core/src/convert_out_fused.wgsl) | Entry point: mọi plane của frame GPU YUV trong một dispatch |
| [frame.rs](../../crates/gpufx-core/src/frame.rs) | `PixelFormat` và `Layout` ([L11](../../crates/gpufx-core/src/frame.rs#L11), [L110](../../crates/gpufx-core/src/frame.rs#L110)): loại plane, depth, shift, subsampling, alpha; `Matrix`, `Range`, `ChromaLocation`, `ColorInfo` |

#### Pipeline được dựng thế nào

Toàn bộ text shader được ghép trong Rust và biên dịch theo device bởi `Converter` (tạo cùng context ở
[runtime.rs](../../crates/gpufx-core/src/runtime.rs#L229)):

- `pipeline()` ([convert.rs](../../crates/gpufx-core/src/convert.rs#L92)) nối `convert.wgsl` với một body (`include_str!`),
  parse bằng naga rồi gọi `ShaderCache::compute_pipeline`. Toàn bộ source nằm trong key của cache
  (`&["convert", "main", &source]`), nên cache trên đĩa (xem "Cache shader trên đĩa") không cần cơ chế vô hiệu hoá thêm
  khi sửa file `.wgsl`. Các pipeline này được dựng không kèm package (`pkg = None`), nên `gpufx pack --precompile` không
  làm nóng cũng không lưu chúng: chúng được biên dịch (hoặc đọc từ cache trên đĩa) khi context tạo ra chúng, hoặc ở lần dùng
  đầu với loại lazy.
- Input ([convert.rs](../../crates/gpufx-core/src/convert.rs#L120)): `convert_in_source(deep, unorm)` sinh bốn binding plane
  `plane0..3` (binding 2..5) và các hàm `load0..3`, rồi nối `convert_in.wgsl`, rồi entry point plain hoặc tiled. `unorm`
  chọn kiểu texture plane: `texture_2d<u32>` cho upload từ CPU (load trả về mã đã lưu) hoặc `texture_2d<f32>` cho frame
  GPU (`round(texel * 255 hoặc 65535)` cho lại mã). `deep` thay text `rgba16float` bằng `rgba8unorm` trong
  `convert_in.wgsl`, nên mọi chỗ có chữ `rgba16float` trong file đó đều bị thay. Tổng cộng bốn pipeline (CPU hoặc GPU,
  8-bit hoặc deep). Cặp CPU dựng trong `Converter::new`; cặp GPU dựng ở frame GPU đầu tiên (`OnceLock`).
- Output ra buffer ([convert.rs](../../crates/gpufx-core/src/convert.rs#L180)): `convert_out.wgsl` và
  `convert_out_buffer.wgsl`, một pipeline cho mọi format và mọi plane; khác biệt giữa các plane nằm hết trong uniform.
  Nó đọc RGBA bằng `textureLoad` trên texture float non-filterable, nên nguồn `rgba8unorm` và `rgba16float` dùng chung.
- Output ra image của plane ([convert.rs](../../crates/gpufx-core/src/convert.rs#L236)): `convert_out_image.wgsl` với
  text `STORAGE_FORMAT` được thay bằng tên storage format WGSL trong `PLANE_FORMATS`
  ([L72](../../crates/gpufx-core/src/convert.rs#L72): `r8unorm`, `rg8unorm`, `rgba8unorm` và ba bản 16-bit). Mỗi format
  texture của plane có một pipeline dựng lazy.
- Output YUV fused ([convert.rs](../../crates/gpufx-core/src/convert.rs#L269); `fused_source`,
  [L283](../../crates/gpufx-core/src/convert.rs#L283)): mỗi `PixelFormat` một pipeline dựng lazy (mảng cỡ `PIXEL_FORMATS`,
  [L315](../../crates/gpufx-core/src/convert.rs#L315)). Rust sinh các binding storage `dst0..` của các plane của format và hai
  hàm shader gọi: `store_luma` (plane 0, thêm plane 3 cho alpha của `yuva*`) và `store_chroma` (plane 1 và 2, hoặc
  plane 1 hai kênh của semi-planar). Kênh nào texture plane có mà format không dùng thì ghi 0, alpha 1.
- Bind group được cache: `InputSlot` giữ một LRU các bind group theo texture plane của các frame GPU gần đây, và
  `GpuOutputSlot` giữ một LRU theo cặp (source, planes) gần đây, nên pool frame quay vòng chỉ bind một lần.

Uniform `Conv` ([convert.rs](../../crates/gpufx-core/src/convert.rs#L370), 112 byte) mang kích thước frame, kích thước chroma
và subsampling, loại plane, cờ alpha, depth, shift, range, cờ premultiplied, `kr`/`kb`, vị trí chroma (siting) và, với
output, hình học của plane cùng việc mỗi mẫu xen kẽ chứa kênh nào (Y/R, U/G, V/B, A). Struct WGSL
([convert.wgsl](../../crates/gpufx-core/src/convert.wgsl#L5)) và danh sách word bên Rust phải cùng thứ tự; đổi kích thước
thì đổi luôn `UNIFORM_SIZE`.

#### Đường input

Theo từng pixel, `pixel()` trong [convert_in.wgsl](../../crates/gpufx-core/src/convert_in.wgsl#L45):

1. Đọc (các) mã đã lưu. `value()` bỏ shift của P010 (`raw >> shift`).
2. **Format RGBA** (`kind` 0): chia cho `code_max()` (`rgba64le` là 16 bit).
3. **Format YUV**: luma được chuẩn hoá theo range (`luma`, [L12](../../crates/gpufx-core/src/convert_in.wgsl#L12): limited
   `(c - 16s) / 219s` với `s` = `code_scale()`, full `c / max`); chroma tương tự (`chroma`,
   [L19](../../crates/gpufx-core/src/convert_in.wgsl#L19): `(c - 128s) / 224s`, hoặc `(c - mid) / max`). Chroma được upsample
   **bilinear**: `chroma_pos` ([L37](../../crates/gpufx-core/src/convert_in.wgsl#L37)) cho toạ độ chroma phân số dưới tâm
   pixel từ siting (`ChromaLocation::siting`, [frame.rs](../../crates/gpufx-core/src/frame.rs#L209)), trộn bốn mẫu lân cận,
   và toạ độ bị clamp vào plane (`load_uv`, [L27](../../crates/gpufx-core/src/convert_in.wgsl#L27); semi-planar đọc một texel
   `rg`, planar đọc hai texture). Sau đó `R = Y + 2(1-kr)V`, `B = Y + 2(1-kb)U`, `G = (Y - kr R - kb B) / kg`, với
   `kr`/`kb` lấy từ `Matrix` của frame (`kr_kb`, [frame.rs](../../crates/gpufx-core/src/frame.rs#L173)).
4. Alpha: `yuva*` đọc plane 3 (kích thước đầy đủ, chia `code_max`); format khác cho 1.
5. Màu bị clamp về 0..1 (giá trị super-white, super-black và ngoài gamut mất ở đây). Nếu frame là `premultiplied`, RGB
   được chia cho alpha (0 khi alpha bằng 0), nên hiệu ứng luôn thấy alpha straight.

Hai entry point khác nhau ở cách lấy chroma. `convert_in_plain` là một invocation cho mỗi pixel, mỗi pixel có tới bốn
lần load chroma có clamp. `convert_in_tiled` (frame GPU) để mỗi workgroup 16x16 nạp các mẫu chroma nó cần một lần vào
`uv_tile` (tối đa 18x18 phần tử; `uv_width = 15 / sub_x + 3`), chờ ở barrier, rồi gọi cùng `pixel()`; giá trị giống hệt.
`in_group()` ([convert.rs](../../crates/gpufx-core/src/convert.rs#L40)) quyết định kích thước dispatch và phải khớp
`workgroup_size` của entry point đang dùng.

Frame CPU: `InputSlot::pool_keys` ([L461](../../crates/gpufx-core/src/convert.rs#L461)) liệt kê các texture upload (mỗi plane
một cái, format số nguyên từ `plane_format`, [L356](../../crates/gpufx-core/src/convert.rs#L356)) và đích RGBA; `upload`
([L568](../../crates/gpufx-core/src/convert.rs#L568)) ghi các plane và uniform. Frame GPU: `use_gpu_frame`
([L586](../../crates/gpufx-core/src/convert.rs#L586)) bind thẳng texture plane của frame và chỉ upload uniform. Plane mà
format không có được bind vào một texture dummy 1x1 (`Converter::dummy`).

**Deep hay không** (`work_format`, [convert.rs](../../crates/gpufx-core/src/convert.rs#L22)): format có `depth > 8` đòi
`rgba16float`. Graph là deep khi có input hoặc output nào đòi nó ([graph.rs](../../crates/gpufx-core/src/graph.rs#L543));
texture của mọi pass trong graph và các pipeline chuyển đổi đi theo. `rgba16float` giữ khoảng 11 bit, nên `rgba64le`
vào và ra không giữ được đủ 16 bit.

#### Các đường output

`sample()` trong [convert_out.wgsl](../../crates/gpufx-core/src/convert_out.wgsl#L22) cho Y/U/V/A (hoặc R/G/B/A) của một
mẫu trong plane, còn `encode()` ([L51](../../crates/gpufx-core/src/convert_out.wgsl#L51)) đổi giá trị 0..1 thành mã lưu
(scale theo range, depth, làm tròn, clamp, `<< shift`). Có ba cách ghi:

| Đường | Dùng cho | Độ mịn | Kết quả |
|-------|----------|--------|---------|
| Buffer (`OutputSlot`, `convert_out_buffer.wgsl`) | Frame CPU (`run`) | Một dispatch mỗi plane, một invocation cho mỗi word `u32` output, đóng gói 4 hoặc 2 mẫu qua `channel()` | Các word trong storage buffer lấy từ pool, copy vào một buffer map được dùng chung cho mọi output; `read_outputs` copy từng dòng vào plane của người gọi |
| Image (`GpuOutputSlot`, `convert_out_image.wgsl`) | Frame GPU, format RGBA (`rgba`, `rgba64le`) | Một dispatch mỗi plane, một invocation mỗi mẫu | `textureStore` vào texture unorm của plane (mã / 255 hoặc / 65535) |
| Fused (`GpuOutputSlot`, `convert_out_fused.wgsl`) | Frame GPU, mọi format YUV | Một dispatch cho mọi plane, một invocation mỗi mẫu **chroma** (nó ghi luôn `sub_x * sub_y` mẫu luma của block và alpha) | `store_luma` / `store_chroma` vào các texture plane |

- **Lấy mẫu xuống chroma**: với plane subsampled, `sample()` áp bộ lọc tam giác lên các pixel quanh mẫu chroma
  (4x4 tap, trọng số `max(1-d, 0)` mỗi trục, chuẩn hoá), đặt theo cùng siting. Nó là chuyển vị của upsample bilinear:
  `[1 3 3 1]` khi siting ở giữa, `[1 2 1]` khi co-sited. `convert_out_fused.wgsl` tính cùng tổng theo cùng thứ tự, nhưng
  đổi các pixel của workgroup sang YUV một lần vào `px` (20x20 với 4:2:0), nên byte ra bằng đường buffer (frame CPU); `yuv_gpu_frames_match_cpu_frames_across_tiles`
  ([tests/gpu_frames.rs](../../crates/gpufx-core/tests/gpu_frames.rs#L508)) so frame GPU với đường CPU từng byte trên mọi
  backend trừ Metal (fast math, lệch một bước). Luma không bao
  giờ bị lọc. Chroma kích thước đầy đủ (4:4:4) chỉ là `yuv()` thẳng.
- **Ma trận và range**: `yuv()` ([L16](../../crates/gpufx-core/src/convert_out.wgsl#L16)) là nghịch đảo của ma trận input,
  dùng `kr`/`kb` của `ColorInfo` frame output; `encode()` áp limited (scale 219/224 cộng offset) hoặc full range cho từng
  kênh. Alpha luôn full range.
- **Alpha**: `fetch()` ([L7](../../crates/gpufx-core/src/convert_out.wgsl#L7)) clamp vào frame và, nếu output là
  `premultiplied`, nhân RGB với alpha trước ma trận (xem `ColorInfo`). Format có kênh hoặc plane alpha (`rgba`,
  `rgba64le`, `yuva420p`, `yuva444p`) lưu alpha ở độ phân giải đầy đủ, không lọc; format không có thì bỏ alpha.
- **Depth**: `encode()` làm tròn gần nhất rồi clamp. Format planar 10-bit lưu mã ở các bit thấp, P010 dịch lên bit cao
  (`shift` = 6). Mẫu dài 1 hoặc 2 byte (`bytes`); đường buffer đóng gói little-endian.
- **Giới hạn kích thước**: `OutputSlot::new` báo lỗi nếu một plane cần hơn `max_storage_buffer_binding_size`
  ([convert.rs](../../crates/gpufx-core/src/convert.rs#L759)); các đường image ghi texture nên không có giới hạn này.

#### Format output được chọn thế nào

Core không chọn; nó dựng convert-out khớp với frame output được đưa vào (`GpuOutputSlot::new` và `OutputSlot::new` nhận
format của frame). Việc chọn nằm ở filter C:

1. **Manifest**: không có danh sách format. Manifest không có trường `formats` ở `inputs` hay `outputs` (ghi vào là lỗi
   "unknown field"); mỗi output có thể là mọi format libgpufx chuyển được. Hiệu ứng ghi alpha có ý nghĩa cần
   `out_format=rgba` (hoặc `yuva420p`) khi format input không có alpha.
2. **Option `out_format` của filter**: một mục, hoặc mỗi output pad một mục cách nhau bằng `|`; có thể là bất kỳ
   format nào GPU chuyển được (kiểm tra cũ "phải nằm trong format output" đã bỏ). Format libgpufx không chuyển được thì cấu hình lỗi.
3. **Thứ tự ứng viên** (`config_vulkan_output`, [vf_gpufx.c](../../ffmpeg/vf_gpufx.c#L949); `config_d3d_output`,
   [L1224](../../ffmpeg/vf_gpufx.c#L1224)): `out_format` nếu đặt, không thì `sw_format` của input
   `source[k]` (`hw_in_fmt[source[k]]`) nếu libgpufx ghi được, không thì `rgba`. `source[k]` lấy từ `gpufx_effect_output_source`
   ([vf_gpufx.c](../../ffmpeg/vf_gpufx.c#L587)): input đầu, hoặc input `bypass` của output,
   tìm bằng cách đi ngược graph từ output qua input đầu của mỗi hiệu ứng. Ứng viên bị bỏ qua khi
   libgpufx không chuyển được hoặc API không ghi được. Có `out_format` thì không có phương án
   dự phòng: đúng format đó hoặc lỗi.
4. **Giới hạn theo API**: Vulkan cần FFmpeg tạo được image mỗi plane một cái có storage usage cho format đó
   (`av_vkfmt_from_pixfmt`, `VK_IMAGE_USAGE_STORAGE_BIT`). D3D12 và D3D11 nhận `nv12`, `p010le`, `rgba`, `rgba64le`;
   VideoToolbox nhận `nv12`, `p010le` (`sw_format_ok`, [vf_gpufx.c](../../ffmpeg/vf_gpufx.c#L1101)).
5. Format được ghi vào `AVHWFramesContext` của output. Với mỗi frame, filter đưa cho libgpufx tên format và `ColorInfo`
   dựng từ frame (`gpu_color_fmt`, [vf_gpufx_frames.h](../../ffmpeg/vf_gpufx_frames.h#L87)), và core dựng hoặc dùng lại slot
   cho cặp (format, kích thước) đó.

Vậy input `yuv420p10le` của hiệu ứng có liệt kê nó thì ra `yuv420p10le`, còn hiệu ứng chỉ liệt kê `rgba` thì luôn ra `rgba`.

**Mất gì khi đi từ RGBA sang format không có alpha** (ví dụ `nv12`): alpha hiệu ứng ghi bị bỏ. Nó không được trộn lên
nền nào cả, nên pixel trong suốt giữ nguyên RGB hiệu ứng để lại dưới nó (thường là đen). Ngoài alpha: độ phân giải
chroma (4:2:0 và 4:2:2 lấy trung bình các pixel quanh mỗi mẫu), limited range chỉ còn 219 / 224 mức, giá trị bị làm tròn
theo depth của format, và RGB ngoài gamut của ma trận bị cắt. Nếu chuỗi là 8-bit (`rgba8unorm`) mà format là 10-bit thì
các bit thêm chỉ là các bước làm tròn của giá trị 8-bit.

#### Format GPU không chuyển được (swscale)

Lớp C chỉ cho qua những format GPU đọc được và dùng swscale cho phần còn lại:

- `query_formats` ([vf_gpufx.c](../../ffmpeg/vf_gpufx.c#L2248)): input chỉ
  đưa ra các format libgpufx chuyển được (`gpufx_format_supported`), nên bước đàm phán của FFmpeg tự chèn `scale`
  (swscale) phía trước cho các format khác (`gray`, `rgb24`, `yuv411p`...). Format nào vẫn lọt tới input mà không chuyển được
  thì lỗi ``pixel format `x` is not converted on the GPU (supported: ...)``.
- Frame phần mềm được `upload_input` ([L1619](../../ffmpeg/vf_gpufx.c#L1619)) upload vào frame GPU có format do
  `config_upload` ([L1574](../../ffmpeg/vf_gpufx.c#L1574)) chọn: format của chính input nếu device nhận, không thì
  `nv12` / `p010le` cho YUV 4:2:0 không alpha, không thì `rgba` / `rgba64le` (`rgba_for`,
  [L711](../../ffmpeg/vf_gpufx.c#L711)). Khi frame không ở format upload, hoặc ma trận của nó là loại GPU không có
  (`gpu_matrix`, [vf_gpufx_frames.h](../../ffmpeg/vf_gpufx_frames.h#L46): họ BT.601, BT.709 và BT.2020 non-constant được
  xử lý; FCC, SMPTE 240M, YCgCo và BT.2020 constant luminance thì không), `sws_convert`
  ([L700](../../ffmpeg/vf_gpufx.c#L700)) đổi nó trước: sang format upload, hoặc sang RGBA full range khi vấn đề là ma trận.
  swscale giữ nguyên alpha premultiplied; GPU un-premultiply sau đó.
- Frame GPU (Vulkan, D3D, VideoToolbox) không bao giờ qua swscale: `sw_format` hoặc ma trận không hỗ trợ là lỗi cấu hình
  hoặc lỗi frame, báo người dùng chuyển đổi trước khi upload.
- Output không có swscale dự phòng: nó luôn là frame GPU ở format libgpufx ghi được (comment đầu
  [vf_gpufx.c](../../ffmpeg/vf_gpufx.c#L10): đặt `hwdownload` hoặc `gpufx_download` trước filter CPU và encoder).

#### Thêm một pixel format

1. [frame.rs](../../crates/gpufx-core/src/frame.rs): thêm variant `PixelFormat`, dòng `NAMES`, tăng cả hai hằng `12`
   (`NAMES`, `ALL`) và thêm một dòng `layout()` (kind, depth, shift, subsampling, alpha). Đặt variant **ở cuối** và đổi
   `PIXEL_FORMATS` trong [convert.rs](../../crates/gpufx-core/src/convert.rs#L315) (`Yuva444p as usize + 1`) sang variant
   cuối mới. Nếu format là tổ hợp của thứ đã có (YUV hoặc RGBA planar hay semi-planar, depth tới 16, subsampling 1 hoặc 2,
   plane alpha tuỳ chọn) thì `plane_dims`, `plane_texture_format`, `plane_format`, `uniform` và các shader không cần
   sửa; `from_name` và `gpufx_format_supported` đi theo `NAMES`.
2. **Layout** mới (YUV packed như `yuyv422`, RGB 3 kênh, subsampling 4) cần một `PlaneKind` mới và sửa ở
   `plane_dims` / `plane_count`; `uniform` (bảng kênh `ch`); chú thích `kind` của `convert.wgsl`; `load_uv` và `pixel` của
   `convert_in.wgsl`; `sample` và `channel` của `convert_out.wgsl`; `fused_source`; và kích thước tile của
   `convert_in_tiled.wgsl` và `convert_out_fused.wgsl`, vốn giả định subsampling tối đa 2. Texture plane bị giới hạn
   trong `PLANE_FORMATS` (1, 2 hoặc 4 kênh, 8 hoặc 16 bit).
3. [vf_gpufx.c](../../ffmpeg/vf_gpufx.c): D3D và VideoToolbox chỉ nhận format qua `sw_format_ok` (thêm vào đó và vào
   `sw_format_list`); Vulkan cần FFmpeg cho image storage từng plane cho format đó. Xem lại các ứng viên của
   `config_upload` nếu format nên được upload nguyên dạng. `gpufx_format_supported` đã cho qua sẵn.
4. Test: thêm format vào các danh sách trong [tests/color.rs](../../crates/gpufx-core/tests/color.rs#L300) (chuyển đổi CPU)
   và [tests/gpu_frames.rs](../../crates/gpufx-core/tests/gpu_frames.rs#L281) (frame GPU so với đường CPU). Tên format còn
   được liệt kê trong văn bản mục 6 phía trên và trong chú thích `gpufx_format_name` của
   [gpufx.h](../../crates/gpufx-ffi/include/gpufx.h#L133).

### Đồ thị GPU trong một filter (xong)

Một `gpufx` chạy cả đồ thị hiệu ứng, nên nhánh phức tạp ở lại trên GPU với mọi backend
(Vulkan, D3D12, Metal), không cần hw frame:

```sh
ffmpeg -i a.mp4 -i b.mp4 -filter_complex "[0:v][1:v]gpufx=graph='[0]split[a][b]; [a]gaussian-blur.zip[ba]; [b]grayscale.zip|vignette.zip[gb]; [ba][gb]crossfade.zip[x]; [x][1]wipe-transition.zip[out]'[v]" -map "[v]" out.mp4
```

Dấu nháy đơn che `;` và `[]` khỏi filter graph bên ngoài. Quy tắc:

- Các câu cách nhau bởi `;`; mỗi câu đọc nhãn, chạy một nút rồi ghi nhãn.
- `[0]`, `[1]`... là input pad của filter (tên `in0`, `in1`...). Mọi pad tới pad cao nhất đều phải được đọc.
- Có thể bỏ nhãn, như filtergraph của FFmpeg, nhưng ở mỗi phía của câu lệnh thì bỏ hết hoặc ghi đủ. Input không nhãn
  gắn vào các input pad thấp nhất mà không nhãn nào ở bất kỳ đâu trong graph chỉ tới, kể cả các câu phía sau
  (`[1]a.zip[x]; b.zip[y]` cho `b.zip` pad `[0]`). Khác với `ffmpeg -filter_complex`, vốn gắn stream chưa dùng đầu
  tiên theo thứ tự mà không nhìn trước; gpufx nhìn trước vì mỗi pad chỉ được đọc một lần. Output không nhãn thành
  output của graph tên `out0`, `out1`..., bỏ qua nhãn graph đã dùng; `split` không nhãn ghi hai output.
- Chỉ mô tả gồm một câu lệnh hoàn toàn không nhãn mà nút là chain package (không phải `split`/`null`) mới chạy như
  chain cũ: pad đặt theo input của manifest đầu, output `default`. Thêm bất kỳ nhãn nào thì tên pad thành `in0`,
  `in1`... và output `out0`. `null` đứng một mình là graph hợp lệ, không làm gì.
- Nhãn khác (chữ, số, `_`, `-`; không có `.` vì trùng với `nhãn.tham_số`) được ghi đúng một lần và đọc nhiều nhất một lần (muốn đọc hai lần thì `split`).
- **Output**: các nhãn không câu nào đọc là output pad của filter, theo thứ tự được ghi (được phép
  nhiều output; tên pad là nhãn). Không có danh sách output riêng: nhãn gõ sai thành output pad thừa,
  FFmpeg báo là chưa nối.
- Nút là `split` (một nhãn vào, bao nhiêu nhãn ra cũng được), `null` (một vào, một ra), hoặc các gói
  nối bằng `|` như `graph=`, đọc số nhãn bằng số input của gói đầu. Hiệu ứng có thể có nhiều output
  (mảng `outputs` của manifest): nhãn sau nó đặt tên output theo vị trí hoặc `[tên=nhãn]`, output đầu chưa
  có nhãn đi tiếp theo chuỗi, hiệu ứng cuối không nhãn ghi mọi output, output khác không nhãn bị bỏ cùng các
  pass chỉ phục vụ nó. Trong engine một cạnh là `Source::Node(effect, output)`; mỗi output có texture, kích
  thước, format, input bypass và frame ghi tại chỗ riêng. `split` và
  `null` không tốn gì: output của chúng *chính là* input (hai cạnh cùng đọc một texture).
- Hiệu ứng ghi kích thước input đầu của nó (hoặc size từ `gpufx_output_size`, lan truyền tới các node phía sau); output pad k lấy SAR và frame rate của input
  pad mà nguồn của nó đi ra. Frame ra theo sự kiện của input 0 (framesync như khi có nhiều input).
- Mỗi input pad upload một lần, mỗi output pad readback một lần, mọi output qua một buffer readback
  dùng chung; cả đồ thị chạy trong một lần submit, hiệu ứng theo thứ tự topo. Các frame output của
  một sự kiện được gửi cùng nhau.
- `graph='a.zip|b.zip'` là đồ thị thẳng: `EffectGraph::parse` dựng nó, và một hiệu ứng đơn cũng chạy
  qua cùng đoạn mã. `graph` là option duy nhất của filter.
- Tham số viết inline sau từng gói của một nút (`[b]grayscale.zip|vignette.zip=strength=0.6[gb]`, xem "Tham số
  inline" trong [filters/gpufx-vi.md](filters/gpufx-vi.md)), nên ví dụ graph có giá trị là
  `graph='[0]split[a][b]; [a]gaussian-blur.zip=radius=8[ba]; [b]grayscale.zip|vignette.zip=strength=0.6[gb]; [ba][gb]crossfade.zip=progress=clip((t-1)/1.5\,0\,1)&enable=between(t\,1\,3)&bypass=auto[x]'`.
  `sendcmd` gọi giá trị lúc chạy bằng `nút.tên=value` trên mọi gói của đồ thị theo thứ tự câu (label gói, chỉ số
  từ 0, tên trơn, hoặc nhãn output của nút: `ba.radius`; `gb.strength` tìm hiệu ứng duy nhất trong
  `grayscale|vignette` có `strength`).
- Kiểm lúc tạo filter: vòng lặp, nhãn đọc mà chưa ghi, ghi hai lần hoặc đọc hai lần, input pad không
  được đọc, số nhãn so với số input của nút, nhãn output là số. Kiểm lúc configure: quy tắc kích
  thước và format trong manifest của mọi nút (một cạnh mang kích thước của hiệu ứng ghi nó và format
  negotiate giữa hai hiệu ứng), và input pad được các hiệu ứng không có format chung đọc.
- Với `enable=`, đồ thị bị tắt gửi input pad nguồn của mỗi output (hoặc pad do `bypass` chọn),
  chuyển sang format của output.
- Đường dẫn trong đồ thị không được chứa `[`, `]`, `;` hoặc `|`.

C API (v5, chỉ thêm): `gpufx_effect_open_graph` (hàm open duy nhất), `gpufx_effect_output_count`, `gpufx_effect_output_name`,
`gpufx_effect_output_source`, `gpufx_effect_output_pad_format[_count]`, `gpufx_effect_process_graph`,
`gpufx_effect_convert_graph`, `gpufx_effect_output_size(fx, output, streams, count, &w, &h)` (size của một output
theo size các input; `config_output` của `vf_gpufx` đặt size outlink từ nó); xem `gpufx.h`.
Tham số inline: `gpufx_effect_open_graph` nhận chúng ở mọi nút, còn `gpufx_effect_option_count` /
`gpufx_effect_option` đọc lại chúng (hằng số đã được áp; biểu thức, `enable` và `bypass` do bên gọi tự tính).

### Frame Vulkan (xong)

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,hwupload,gpufx=graph=vignette.zip,gpufx=graph=sepia.zip,hwdownload,format=nv12" out.mp4
```

- Mọi pad input nhận thêm `AV_PIX_FMT_VULKAN`, pad output chỉ nhận format GPU ([mục 5](#5-filter-ffmpeg-gpufx)). Input có thể trộn frame
  Vulkan và frame CPU (filter tự upload frame CPU lên cùng device).
  sw_format của từng input Vulkan phải là format libgpufx chuyển được (`nv12`, `p010le`, `yuv420p`, `rgba`…) và
  được kiểm theo quy tắc của manifest như format phần mềm. Filter có cờ `FF_FILTER_FLAG_HWFRAME_AWARE`.
- **Một device.** `init` mở gói trên device noop của wgpu (pad và format phải biết trước khi negotiate, chưa
  tạo device GPU nào); filter không bao giờ tạo device riêng (`gpufx_effect_use_default_device` vẫn còn trong
  C API cho nơi gọi khác); khi các link được
  configure, `gpufx_effect_use_vulkan` chuyển effect sang device của FFmpeg: libgpufx bọc các handle của
  `AVVulkanDeviceContext` bằng `wgpu-hal` (`Instance::from_raw`, `expose_adapter`, `Adapter::device_from_raw`,
  rồi `create_device_from_hal`), biên dịch lại gói cho device đó (dùng chung theo `VkDevice` như mọi device) và
  chép giá trị tham số. Không thứ gì của FFmpeg bị huỷ theo (drop callback rỗng); filter giữ tham chiếu tới
  device cho tới khi effect được giải phóng.
- **wgpu chỉ dùng những gì device đã bật.** wgpu-hal chọn tính năng (và bỏ kiểm tra biên của chính nó khi có
  `robustBufferAccess`) theo những gì *physical device* hỗ trợ, nhưng FFmpeg chỉ bật một phần. Vì vậy wgpu
  nhìn device qua một `vkGetInstanceProcAddr` bọc lại: `vkEnumerateDeviceExtensionProperties` chỉ liệt kê
  extension đã bật trên device, `vkGetPhysicalDeviceFeatures[2]` AND feature lõi với feature đã bật và mỗi
  struct feature của extension với struct cùng loại trong chuỗi tạo device của FFmpeg (struct đã nâng lên lõi, như timeline
  semaphore, lấy trường từ `VkPhysicalDeviceVulkan11/12/13Features` của FFmpeg). Queue tạo với cờ
  (`VK_KHR_internally_synchronized_queues`) được lấy bằng `vkGetDeviceQueue2`.
- **Queue.** Họ queue đầu tiên có cả graphics lẫn compute, queue 0 (wgpu ghi render pass và barrier đồ hoạ: trên họ
  chỉ có compute mà NVIDIA liệt kê trước thì device bị lost; libgpufx từ chối họ như vậy). Filter giữ `lock_queue` của FFmpeg quanh mỗi lần gọi, nên
  lệnh submit của FFmpeg (hwupload, filter Vulkan khác) không tranh với wgpu.
- **Frame.** Mỗi plane một `VkImage`, theo format từng plane của FFmpeg (`R8`, `R8G8`, `R8G8B8A8`, `R16`,
  `R16G16`, `R16G16B16A16` `_UNORM`): input cần device có `disable_multiplane=1` (hoặc frame tạo theo cách đó);
  frames context output do gpufx tạo dùng `AV_VK_FRAME_FLAG_DISABLE_MULTIPLANE` và cần usage `STORAGE`.
  Image multiplane bị từ chối lúc configure kèm thông báo, frame input không có usage `SAMPLED` cũng vậy. FFmpeg 9.0 mặc định tạo
  frames context `yuva420p`/`yuva444p` không có usage nào (của `hwupload` thì dùng được), nên output chuyển sang
  format khác, ví dụ `rgba`. sw_format của output là của input nguồn nếu libgpufx ghi được
  và FFmpeg tạo được storage image cho nó, không thì `rgba`.
  `out_format` thay cho cách chọn đó (đúng format ấy, hoặc lỗi lúc configure). Chuỗi nhiều filter rời giữ
  RGBA ở giữa bằng `out_format=rgba` trên mọi filter trừ cái cuối (số đo ở [BENCHMARK-vi.md](../BENCHMARK-vi.md)).
- **Mỗi frame**, CPU không chờ: filter khoá mỗi `AVVkFrame` một lần (`lock_frame`; một frame `split` phía
  trước có thể nằm trên hai pad), libgpufx bọc mỗi image thành texture wgpu (`texture_from_raw`, bộ nhớ
  ngoài, callback drop rỗng) hoặc dùng lại wrapper đã tạo ở frame trước (LRU 16 frame mỗi pad, khoá theo
  image, semaphore, format, kích thước; bind group dựng từ chúng cũng cache như vậy, nên pool frame quay
  vòng chỉ bind một lần). Giữa các lần gọi wgpu thấy mọi wrapper ở `GENERAL`; image bị để ở layout khác
  (bởi `hwupload`, `hwdownload`, filter khác) được chuyển sang `GENERAL` bằng barrier thô trong command
  buffer submit trước (output thì từ `UNDEFINED`). Filter giữ frames context của input và output tới khi
  effect bị giải phóng, nên image không bị giải phóng trước wrapper. Rồi libgpufx ghi pass chuyển đổi input
  (plane đọc như texture unorm), các hiệu ứng và pass chuyển đổi output (plane ghi như storage texture),
  chuyển mọi image về `GENERAL`, rồi submit một lần, chờ timeline semaphore của mọi image ở `sem_value` và
  signal `sem_value + 1` (`add_wait_semaphore`/`add_signal_semaphore`, mỗi semaphore một lần). Sau đó filter
  ghi `layout`, `sem_value`, `access` vào `AVVkFrame` rồi mở khoá.
- **VRAM:** không texture upload, không storage buffer output, không buffer readback; texture pass trong pool
  giống hệt đường phần mềm; mỗi input giữ một texture RGBA đã chuyển (như khi upload), còn output chính là
  frame trong pool của FFmpeg. Input `rgba` thẳng của graph không deep, không hiệu ứng nào đọc mip chain của
  nó, thì không cần cả hai: hiệu ứng sample thẳng image (không pass copy-in), và các hiệu ứng đọc nó được bind
  lại vào image mới mỗi frame. Tương tự, output `rgba` thẳng (`out_format=rgba`) của graph như vậy do pass cuối
  của hiệu ứng tạo ra nó ghi thẳng, không texture trong pool và không pass copy-out, khi không gì khác đọc
  output của hiệu ứng đó (hiệu ứng khác hay output khác của graph, mip chain, pass khác của chính hiệu ứng).
  Mọi trường hợp khác, và frame bị bypass, vẫn đi đường copy.
- **Pass chuyển đổi của frame GPU** (Vulkan và D3D12): pass vào của frame YUV chuyển 16x16 pixel mỗi
  workgroup, các mẫu chroma mà chúng đọc được nạp một lần vào bộ nhớ workgroup (thay vì bốn lần load có
  clamp mỗi pixel). Output YUV được ghi bằng một pass cho mọi plane: mỗi invocation ghi một mẫu chroma và
  các mẫu luma (và alpha) của khối của nó, từ một tile pixel đã đổi sang YUV một lần, trọng số bộ lọc
  chroma tính theo hàng và cột. Pass ghi plane RGBA chọn kênh bằng `select`, không dùng chỉ số vector chỉ
  biết lúc chạy (NVIDIA đẩy sang local memory). Byte ra giống hệt trước (test so với đường CPU). Đo với
  một vignette trên texture wgpu 1080p (RTX 4060 Laptop, 3000 frame): nv12 copy-in 0.108 → 0.087 ms,
  copy-out 0.130 → 0.105 ms; rgba copy-out 0.087 → 0.049 ms. Không gộp chuyển đổi vào pass đầu/cuối của
  hiệu ứng: hiệu ứng lấy mẫu input qua sampler tuyến tính (lọc trên plane YUV không ra cùng RGB như bản
  copy) và mỗi pass hiệu ứng sẽ cần một pipeline cho mỗi format frame.
- **Đo thời gian:** `GPUFX_PROFILE=1` xin device timestamp query và khi giải phóng mỗi graph thì in thời gian GPU
  mỗi frame của copy-in, hiệu ứng, copy-out, cùng thời gian CPU mỗi frame (prepare, bind, record, import,
  submit). Nó tách frame thành ba compute pass và chờ frame trễ bốn frame, nên khi bật thì thời gian chạy
  tổng không còn đúng.
- Filter bị tắt (timeline) luôn chuyển frame trên GPU sang frames context của output (không đưa tham chiếu
  vì output có frames context riêng). Input chưa bắt đầu hiện frame đen upload một lần (đục với format có
  alpha); input CPU cũng vậy, ở format upload của nó.
- Rust: `GpuFrame` (texture từng plane trên device của effect) và `EffectGraph::encode_gpu`, ghi cả đồ thị vào
  command encoder của người gọi mà không submit (không phụ thuộc backend, nền cho bước D3D12);
  `GpuContext::from_vulkan` và `EffectGraph::process_vulkan` (`gpufx_core::vulkan`, Linux và Windows) thêm phần
  dùng chung và đồng bộ Vulkan. C API (v6, chỉ thêm): `gpufx_vulkan_supported`, `gpufx_effect_use_vulkan`,
  `gpufx_effect_process_vulkan`; xem `gpufx.h`.
- Build: `scripts/build-prebuilt.sh` configure libavfilter với `--enable-vulkan` khi `libavutil` build sẵn có
  Vulkan và tìm được Vulkan-Headers của Khronos (clone tag `v1.4.321`; FFmpeg cần header mới hơn bản của Ubuntu
  noble), và giữ `hwupload`, `hwdownload`, `hwmap`. Không thì gpufx được build không có frame Vulkan và test bỏ
  qua phần đó.
- **Decoder:** decoder Vulkan (`-hwaccel vulkan`) xuất image multiplane nên frame của nó hiện bị từ chối (cần
  `hwdownload,hwupload` hoặc copy trên GPU sang image từng plane; xem Backlog).
- **Submit** trên một device dùng chung được tuần tự hoá bằng mutex trong libgpufx, giữ từ lúc đặt semaphore
  tới `queue.submit` (ngoài `lock_queue` của FFmpeg), trong một error scope của wgpu; submit bị wgpu từ chối
  được lấy lại semaphore và làm các frame Vulkan sau trên device đó báo lỗi rõ ràng.
- Đã chạy trên lavapipe: test bundle so framemd5 của `hwupload,gpufx,…,hwdownload` với frame CPU do gpufx tự upload (rgba,
  nv12, yuv420p, yuv444p, p010le, yuv420p10le, rgba64le, đồ thị có hai input là cùng một frame split, hai filter
  liền nhau, đổi format output): giống hệt. Test Rust so `encode_gpu` với đường CPU từng byte.

### Filter truyền frame `gpufx_upload` / `gpufx_download` (Vulkan)

Cách dùng và option: [filters/gpufx_transfer-vi.md](filters/gpufx_transfer-vi.md).

Thay thẳng cho `hwupload` / `hwdownload` trên device Vulkan (`ffmpeg/vf_gpufx_transfer.c`, C thuần dùng
helper Vulkan nội bộ của FFmpeg `libavutil/vulkan.h`, không cần libgpufx). Lý do: trên NVIDIA, FFmpeg 9.0
copy qua staging buffer (tắt host image copy và import bộ nhớ host), và `hwdownload` chờ trên CPU từng lần
copy (`ff_vk_exec_wait`), nên CPU và GPU chạy lần lượt. Trên driver Intel Windows, host image copy của
FFmpeg 9 bị lỗi; các frames context do gpufx tạo bỏ cờ usage host-transfer, và `gpufx` từ chối frame của
`hwupload` trên driver đó ([INTEL_VULKAN-vi.md](../INTEL_VULKAN-vi.md)).

- **gpufx_upload** (`depth`, mặc định 3): frames context tạo trên `-filter_hw_device` như `hwupload` (format
  vào: sw format của device mà plane khớp 1:1 với plane Vulkan). Vòng `depth` staging buffer map sẵn,
  host-coherent, mỗi execution context một cái: memcpy vào slot, barrier + `vkCmdCopyBufferToImage` từng
  plane, submit không chờ. CPU chỉ chờ khi quay lại slot mà lần copy trước chưa xong (`ff_vk_exec_start`
  chờ fence của slot đó).
- **gpufx_download** (`latency`, mặc định 2): filter `activate`. Frame k được submit (`vkCmdCopyImageToBuffer`
  vào slot k mod (latency+1), bộ nhớ host-cached), frame k-latency được chờ (thường đã xong), invalidate,
  chép vào buffer của `ff_get_video_buffer` rồi gửi đi kèm props. Gặp EOF thì xả hết frame đang bay rồi mới
  chuyển status. Format ra phải là sw_format của frame (thêm `format=<sw_format>` phía sau, như `hwdownload`).
  Input thưa (nguồn live) thì mỗi frame ra trễ `latency` frame; `latency=0` tắt pipelining. Cả hai filter
  không nhận đổi kích thước frame giữa chừng (`hwupload`/`hwdownload` thì nhận): graph dừng với EINVAL.
- **Đồng bộ**: `ff_vk_exec_add_dep_frame` (lock_frame, chờ timeline semaphore của từng image ở `sem_value`,
  signal `sem_value + 1`), `ff_vk_frame_barrier` không chuyển queue family, và `ff_vk_exec_submit` (giữ
  `lock_queue` của FFmpeg), trên họ queue graphics của FFmpeg, cùng họ mà `gpufx` và wgpu dùng. Vì vậy trộn
  được với `hwupload`, `hwdownload`, `gpufx` và các filter `*_vulkan`. Execution giữ tham chiếu frame tới khi
  đọc xong bản copy.
- **Plane**: image multiplane (aspect `PLANE_n`) và mỗi plane một image (`disable_multiplane=1`) đều chạy.
  Mỗi plane có vùng riêng trong staging buffer: hàng căn theo `optimalBufferCopyRowPitchAlignment` (và là
  bội của cỡ texel, vì `bufferRowLength` tính bằng texel), offset plane căn theo
  `optimalBufferCopyOffsetAlignment` (ít nhất 16). Kích thước copy là kích thước link (frames context của
  decoder có thể lớn hơn).
- **Queue**: `ff_vk_exec_pool_init` lấy queue với cờ mà libavfilter được biên dịch; libavutil prebuilt tạo
  queue với `VK_KHR_internally_synchronized_queues`, header Vulkan của bản build không biết cờ này, nên
  `vkGetDeviceQueue2` không trả queue nào. Filter lấy lại queue với `queue_flags` của device (validation layer
  vẫn báo một lần cho lần gọi đầu của pool, VUID-06225).
- Build: `integrate.sh` thêm `vf_gpufx_transfer.o vulkan.o` (bản `libavutil/vulkan.c` của libavfilter) và
  `gpufx_upload/download_filter_deps="vulkan"`; `docker/keep-filters.txt` (`FFMPEG_FILTERS=keep`) giữ cả hai.
- Test (`scripts/test-bundle.sh`): vòng nv12, yuv420p, rgba khớp từng bit, multiplane lẫn
  `disable_multiplane=1`, trộn với `hwupload` / `hwdownload`; `gpufx` ở giữa khớp đường phần mềm; `latency=4`
  vẫn ra đủ frame. Kiểm tay thêm: p010, validation layer (bản copy không sinh VUID nào; `hwupload`/`hwdownload`
  gốc sinh VUID-00174/00191).

Số đo trên clip 90 s (RTX 4060 Laptop, GPU rảnh): xem [BENCHMARK-vi.md](../BENCHMARK-vi.md).

### Frame D3D12 và D3D11 (đã build và cross-compile, chỉ job CI Windows chạy thử)

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 \
  -vf "format=nv12,hwupload,gpufx=graph=vignette.zip,hwdownload,format=nv12" out.mp4
ffmpeg -init_hw_device d3d11va=dx -filter_hw_device dx -i a.mp4 \
  -vf "format=nv12,hwupload,gpufx=graph=vignette.zip,hwdownload,format=nv12" out.mp4
```

- Pad nhận thêm `AV_PIX_FMT_D3D12` và `AV_PIX_FMT_D3D11` (khi libavfilter build có d3d12va/d3d11va và libgpufx
  là bản Windows). Quy tắc như Vulkan: mọi input/output là frame của cùng một API, hoặc không cái nào.
  sw_format: thực tế là `nv12` và `p010le` (d3d12va của FFmpeg chỉ làm hai format này, và của d3d11va gpufx chỉ
  đọc hai format này); libgpufx cũng nhận resource RGBA8/RGBA16 (`rgba`, `rgba64le`) từ chương trình khác. Format
  khác bị từ chối lúc configure (BGRA của d3d11va cần đảo kênh: backlog). Texture có hơn một mip level bị từ chối.
- **Không có alpha.** Không sw_format nào trong số này có alpha, nên output có alpha của effect mất alpha ở
  `hwdownload`, còn `out_format` có alpha thì lỗi lúc FFmpeg tạo frame. Package `alpha-extract` đưa alpha thành ảnh
  xám `nv12` qua một output của graph; `alphamerge` ghép lại trên CPU.
- **D3D12, một device.** wgpu-hal 30 không có `device_from_raw` cho DX12, nhưng device D3D12 là singleton theo
  adapter trong một process: libgpufx mở adapter DX12 của wgpu có LUID trùng với device
  (`ID3D12Device::GetAdapterLuid`) rồi kiểm tra wgpu nhận đúng `ID3D12Device` đó (so COM identity); nếu không
  (runtime D3D12 khác như Agility SDK, adapter wgpu bỏ qua như bản "Microsoft Basic Render Driver" trùng WARP
  khi chạy headless) thì từ chối kèm thông báo. wgpu có command queue riêng trên device đó.
- **Frame D3D12 tại chỗ.** `AVD3D12VAFrame.texture` được bọc một lần cho mỗi plane (`texture_from_raw` +
  `with_plane_slice`: view R8/RG8 hoặc R16/RG16 của resource NV12/P010). Frame nằm ở
  `D3D12_RESOURCE_STATE_COMMON` (quy ước của FFmpeg); libgpufx tự ghi barrier sang state cần dùng và quay lại,
  theo từng subresource của slice, trong command list riêng trước và sau của wgpu, và tạo wrapper ở sẵn state
  đó nên wgpu không ghi barrier nào (wgpu sẽ chuyển cả resource một lần cho mỗi wrapper plane). Một lần submit
  chờ `sync_ctx.fence` của mỗi frame tại `fence_value` và signal `fence_value + 1` (mỗi fence một lần); filter
  lưu lại giá trị. Upload D3D12 của FFmpeg không chờ fence của frame trước khi ghi, nên mỗi lần gọi trước hết
  chờ trên CPU lần submit trước (một event đang chạy).
- **Một lần copy trên GPU khi không dùng tại chỗ được**, vào texture libgpufx giữ theo pad và plane (VRAM: một
  frame cho mỗi pad như vậy): input là một slice của texture array (`AV_D3D12VA_FRAME_FLAG_TEXTURE_ARRAY`,
  decoder), lớn hơn frame hoặc cấm shader đọc, và output không có `D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS`.
  Frames context output do gpufx tạo xin unordered access trước, không được thì dùng frame ghi bằng copy
  (có thông báo verbose); mỗi frames context thử được kiểm bằng một lần `av_hwframe_get_buffer`, vì device có thể
  nhận context nhưng không tạo được texture.
- **D3D11.** wgpu không có backend D3D11: hiệu ứng chạy trên device D3D12 của wgpu cùng adapter với device
  D3D11 (LUID qua `IDXGIDevice`). Texture có `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` được mở sang đó bằng
  `CreateSharedHandle`/`OpenSharedHandle`, không copy (giữ mở tối đa 64 cái, có giữ tham chiếu tới texture).
  Frames context output gpufx tạo là loại texture này (`SHARED | SHARED_NTHANDLE`, bind
  `SHADER_RESOURCE | UNORDERED_ACCESS`, bỏ UAV nếu device không cho: khi đó dùng copy D3D12 ở trên), nên output
  không bị copy. Input từ `hwupload` hay decoder không share được nên được copy một lần trên immediate context
  D3D11 (`CopySubresourceRegion`, đồng thời tách slice của array) vào texture share libgpufx giữ cho mỗi pad
  input (VRAM: một frame cho mỗi pad input). Không dùng D3D11On12: nó bọc resource D3D12 cho D3D11, còn ở đây
  frame do device D3D11 của FFmpeg tạo; keyed mutex cũng được nhưng cần texture `SHARED_KEYEDMUTEX` và
  acquire/release phía CPU. Thứ tự: một fence D3D12 share với device D3D11 (`ID3D11Device5::OpenSharedFence`,
  D3D11.4): immediate context signal `v` rồi flush, lần submit D3D12 chờ `v` và signal `v + 1`, immediate context
  chờ `v + 1`, nên việc D3D11 sau đó của FFmpeg (`hwdownload`, encoder) chờ trên GPU, không chờ CPU. Filter giữ
  `AVD3D11VADeviceContext.lock` trong lúc gọi.
- Rust: `GpuContext::from_d3d12` / `from_d3d11`, `EffectGraph::process_d3d12` / `process_d3d11`
  (`gpufx_core::d3d12`, `cfg(windows)`, dựa trên `encode_gpu`). C API (v7, chỉ thêm): `gpufx_d3d12_supported`,
  `gpufx_effect_use_d3d12`, `gpufx_effect_process_d3d12`, `gpufx_effect_use_d3d11`,
  `gpufx_effect_process_d3d11`; trên hệ khác các hàm này báo lỗi.
- Build: `scripts/build-prebuilt.sh win64` thêm `--enable-d3d11va --enable-d3d12va` khi `libavutil` build sẵn có
  chúng (có), tải `d3d12.h`, `d3d12sdklayers.h`, `d3d12video.h` của mingw-w64 v12.0.0 khi mingw-w64 đã cài
  (Ubuntu noble: 11) không có `d3d12video.h`.
- Test: `test-bundle.sh` chạy vignette nv12/p010le, hai filter liên tiếp, đồ thị có hai input là cùng một
  frame split, timeline, input thứ hai đến muộn và từ chối input trộn, cho cả hai API, thử adapter 0-3, bỏ qua
  khi không có device hoặc wgpu không share được. Job CI `ffmpeg-windows` chạy chúng trên WARP; chưa chạy trên
  phần cứng thật. Với `REQUIRE_D3D=1` (đặt ở cả hai job CI win64), skip làm test hỏng (D3D12 được miễn khi FFmpeg không có hwdevice d3d12va, vì frame D3D của FFmpeg là D3D11), và build không có frame
  D3D12/D3D11 (thiếu d3d12va/d3d11va, tải header lỗi hoặc sai sha256) làm build hỏng; test in một dòng các API đã
  chạy và đã bỏ qua.
- Frame đen của input chưa bắt đầu (mọi API GPU, kể cả Vulkan) lấy từ một frames context nhỏ riêng của filter,
  tạo giống của input (device, sw_format, cờ image), không lấy từ pool của input, vì pool phía trên có thể có
  kích thước cố định.
- Instance DX12 dùng chung bỏ `VALIDATION`, `GPU_BASED_VALIDATION` và `DEBUG` lấy từ biến môi trường: device
  cũng là của FFmpeg.

### Frame VideoToolbox (macOS, đã biên dịch nhưng chưa chạy trên máy Mac)

```sh
ffmpeg -init_hw_device videotoolbox=vt -filter_hw_device vt -i a.mp4 \
  -vf "format=nv12,hwupload,gpufx=graph=vignette.zip,hwdownload,format=nv12" out.mp4
```

- Pad nhận thêm `AV_PIX_FMT_VIDEOTOOLBOX` (khi libavfilter build có videotoolbox và libgpufx là bản macOS).
  sw_format: `nv12` (`420v`/`420f`) và `p010le` (`x420`/`xf20`); pixel format của từng `CVPixelBuffer` được kiểm
  khớp với frames context. Format khác (BGRA...) bị từ chối lúc configure, và input CPU không phải 4:2:0 thì
  không upload được (backlog).
- **Device.** Frame là `IOSurface`, device Metal nào cũng mở được: libgpufx chạy trên adapter Metal của wgpu
  (ưu tiên hiệu năng cao), một context cho cả process; device VideoToolbox của FFmpeg chỉ được giữ ref.
- **Tại chỗ.** `CVPixelBufferGetIOSurface`, rồi mỗi plane một texture Metal bằng
  `newTextureWithDescriptor:iosurface:plane:` (R8 + RG8 hoặc R16 + RG16, usage shader read/write, storage
  shared; chỉ nhận GPU unified memory vì texture managed cần một blit đồng bộ mà wgpu không ghi), bọc bằng `wgpu_hal::metal::Device::texture_from_raw`
  và `create_texture_from_hal`. Texture giữ ref tới surface, nên wrapper được cache theo pad bằng `IOSurfaceID`
  (16 frame × 4) như image Vulkan, bỏ wrapper thì nhả surface. Plane IOSurface lớn hơn frame thì dùng phần góc
  trên trái.
- **Không có fence.** Frame VideoToolbox của FFmpeg không có đối tượng đồng bộ GPU (upload/download khoá nó
  trên CPU), nên mỗi lần gọi chờ (`device.poll`) tới khi submit xong mới trả về.
- **Ghi p010le** cần storage texture R16/RG16 (`TEXTURE_FORMAT_16BIT_NORM` và format feature của adapter): GPU
  Apple có; GPU không có thì output p010le báo lỗi kèm tên format (chưa có đường dự phòng: backlog).
- Rust: `GpuContext::from_videotoolbox`, `EffectGraph::process_videotoolbox`
  (`gpufx_core::videotoolbox`, `cfg(target_vendor = "apple")`, dựng trên `encode_gpu`). C API (v9, chỉ thêm):
  `gpufx_videotoolbox_supported`, `gpufx_effect_use_videotoolbox`, `GpufxVtFrame`,
  `gpufx_effect_process_videotoolbox`; hệ điều hành khác thì báo lỗi.
- Test: `test-bundle.sh` chỉ trên macOS chạy vignette nv12/p010le so với lượt Vulkan hoặc frame CPU, hai filter
  liền nhau, graph có một frame split, input CPU đến muộn và việc từ chối BGRA. Job CI `ffmpeg-macos` build FFmpeg
  từ submodule có VideoToolbox và chạy với `REQUIRE_VT=1`: bị bỏ qua là hỏng, trừ khi FFmpeg không tạo được
  device hoặc không có adapter Metal.

### Nội suy khung hình `gpufx_ai_framerate` (RIFE, gói gpufx-nn)

Cách dùng và option: [filters/gpufx_ai_framerate-vi.md](filters/gpufx_ai_framerate-vi.md).

Filter `gpufx_ai_framerate` (`ffmpeg/vf_gpufx_ai_framerate.c`) tăng frame rate bằng một mạng nơ-ron do libgpufx chạy
trên cùng loại frame GPU và device như `gpufx` (Vulkan, D3D12, D3D11, VideoToolbox). Model là gói gpufx-nn
(`docs/NN_MODEL_FORMAT-vi.md`) có `io.json` kind `frame_interp` (RIFE v4.6 do `gpufx-nnconv` chuyển từ ncnn); các
layer chạy bằng compute shader WGSL, biên dịch qua cache shader.

Filter đổi mỗi điểm của lưới frame rate đầu ra thành một thời điểm giữa hai frame nguồn rồi nhờ libgpufx tạo frame
tại thời điểm đó. FFI (`gpufx.h`, kiểu mờ `GpufxAiInterp`):

- `gpufx_ai_interp_open(model)` / `gpufx_ai_interp_free`: kiểm đường dẫn gói; model được nạp sau.
- `gpufx_ai_interp_use_vulkan` / `_d3d12` / `_d3d11` / `_videotoolbox`: nạp model lên device của bên gọi (một lần
  cho mỗi device); `gpufx_ai_interp_device` cho biết tên device.
- `gpufx_ai_interp_process_vulkan` / `_d3d12` / `_d3d11` / `_videotoolbox`: nhận frame nguồn kế tiếp và tạo
  `nb_outputs` frame giữa frame nguồn trước và nó, tại `times[k]` trong (0, 1]; thời điểm 1 là copy frame nguồn.
  Frame nguồn được đổi sang RGBA một lần và giữ trên GPU cho lần gọi sau. Semaphore, layout và fence xử lý như
  `gpufx_effect_process_*`.
- `gpufx_ai_interp_set_scene(threshold)`: ngưỡng chuyển cảnh là SSIM trong 0..1, tính như `inference_video.py` của
  RIFE gốc (hai frame thu bilinear về 32x32, `ssim_matlab` trên RGB); cặp thấp hơn ngưỡng là cảnh cắt và mỗi frame
  tạo ra là frame nguồn gần hơn (RIFE lặp frame 0; RIFE thu nhỏ frame đã pad 0, ở đây thu frame chưa pad). `gpufx_ai_interp_reset` quên frame trước (gián đoạn).

### Ngân sách VRAM (quy tắc cho mọi giai đoạn)

VRAM có hạn, nên bộ nhớ GPU giữ ở mức thấp nhất và không nhân bản:

- Không chép thêm khi vào/ra: texture các plane YUV và texture RGBA sau chuyển đổi được dùng
  lại qua các frame; hiệu ứng đầu tiên đọc thẳng texture đã chuyển đổi.
- Texture trung gian (output của pass, chỗ nối chuỗi, cạnh của đồ thị) lấy từ pool theo kích
  thước và format: chuỗi 1 input, 2 hiệu ứng mỗi cái một pass cấp hai texture output, hiệu ứng thứ
  ba dùng lại texture đầu. Texture có thời gian sống không chồng nhau dùng chung bộ nhớ (ping-pong);
  texture trả về pool ngay sau lần đọc cuối, tính trên cả đồ thị theo thứ tự chạy. Output của pass
  mà cũng là output của đồ thị được giữ tới lúc readback. Kế hoạch được tính trước khi cấp gì
  (`EffectGraph::memory_plan`), nên đồ thị rộng chỉ tốn số texture sống đồng thời, không phải một cái
  mỗi nút. Ví dụ đồ thị hình thoi `[0]split[a][b]; [a]gaussian-blur[ba]; [b]grayscale|vignette[gb];
  [ba][gb]crossfade[out]`: năm output của pass dùng chung **3** texture trong pool (hai pass của blur
  và frame xám sống cùng lúc; vignette dùng lại pass đầu của blur, crossfade dùng lại frame xám), thêm
  một texture upload (RGBA thẳng được đọc trực tiếp) và một buffer readback: 5 lần cấp cỡ một frame
  (1920x1080 `rgba8unorm`: 3 x 7,9 MiB trong pool, tổng 41,5 MB), so với 8 nếu mỗi output của pass
  một texture và `split` chép một bản (5 + 1 + upload + readback).
- `rgba16float` (gấp đôi `rgba8unorm`) chỉ dùng khi cần độ chính xác (input/output trên
  8 bit); chuỗi toàn 8 bit giữ `rgba8unorm`.
- Buffer staging và readback dùng chung, không theo từng hiệu ứng: một buffer readback chứa mọi output của đồ thị. Texture được giải phóng khi
  kích thước frame đổi.
- Texture của gói (PNG) thuộc `Program` dùng chung, nạp một lần cho mỗi device.

### Cache shader trên đĩa (`GPUFX_SHADER_CACHE`)
- `GPUFX_SHADER_CACHE=<thư mục>` giữ pipeline đã biên dịch giữa các process; không đặt thì không ghi gì.
  Thư mục chưa có thì tạo; không ghi được thì cảnh báo một lần rồi chạy tiếp không cache.
- Mỗi pipeline một file (`<sha256>.gpucache`), hash gồm nguồn shader cuối cùng (có prelude), ngôn ngữ,
  entry point, format output (`rgba8unorm`/`rgba16float`), phiên bản gpufx và wgpu, backend và adapter
  (name, vendor, device, driver, driver_info). Không kiểm mtime.
- Vulkan: device xin `Features::PIPELINE_CACHE` khi adapter có, mỗi pipeline của pass được tạo với
  một `wgpu::PipelineCache` nạp từ file của nó (`fallback: true`, dữ liệu của driver/wgpu khác bị wgpu
  bỏ qua khi kiểm header) rồi bỏ ngay sau đó, không giữ gì trong bộ nhớ. Ghi qua file tạm + rename;
  file không đọc được hoặc hỏng thì bỏ qua và ghi lại. `GPUFX_SHADER_CACHE_MAX_MB` (mặc định 256)
  giới hạn dung lượng thư mục, xoá file lâu không dùng nhất trước.
- Mỗi file là blob của wgpu kèm SHA-256 của nó ở cuối, kiểm trước khi đưa cho wgpu (không khớp thì bỏ
  qua, biên dịch lại, ghi lại). Thư mục phải riêng của người dùng: trên Unix thư mục mà người khác ghi
  được sẽ bị từ chối kèm cảnh báo, vì file đi thẳng tới driver. File tạm cũ (quá 1 giờ) và giới hạn
  dung lượng được dọn một lần mỗi device.
- Khoá còn gồm phiên bản chính xác của naga, wgpu-core và wgpu-hal (`build.rs` đọc từ `Cargo.lock`).
  Pass của hiệu ứng và pipeline chuyển đổi dựng sẵn đều đi qua cache.
- D3D12: wgpu 30 không có cache pipeline ra đĩa ở đây. Khi tìm thấy `dxcompiler.dll` trên đường tìm DLL,
  gpufx tự sinh HLSL bằng naga (register khớp root signature của wgpu-hal, `dxil.rs`), biên dịch ra DXIL
  (`cs_6_0`), lưu thành `<sha256>.dxil` (khoá thêm phiên bản DXC và shader model) rồi nạp lại bằng
  `Features::PASSTHROUGH_SHADERS` (chỉ xin trên D3D12 khi có cấu hình cache). Blob bị D3D12 từ chối thì
  biên dịch lại; nếu DXIL vừa biên dịch cũng bị từ chối (thiếu `dxil.dll`...) thì xoá file; đủ hai shader
  khác nhau bị từ chối như vậy thì device đó thôi dùng DXIL. Không có DXC thì đi đường thường.
- `gpufx pack --precompile <dir> <out.zip>` biên dịch mọi pass (output 8 bit và `rgba16float`, giá trị
  `expr` mặc định) trên device D3D12 (WARP là đủ) và lưu `compiled/dx12/<sha256>.dxil` (kèm checksum)
  vào gói; khoá không có adapter, driver hay phiên bản DXC nên máy không có DXC vẫn dùng được. Thư mục
  `compiled/` có sẵn trong `<dir>` không bao giờ được chép. Lúc chạy chỉ dùng blob khi
  `GPUFX_TRUST_PRECOMPILED=1` (khi đó không cần `GPUFX_SHADER_CACHE`): gói chưa được ký và passthrough
  shader không được wgpu kiểm. Biến này được đọc lúc tạo context, sau đó tin mọi gói context đó mở;
  SHA-256 nối cuối chỉ chứng minh file nguyên vẹn, không chứng minh ai dựng gói. Blob thiếu hoặc bị từ
  chối thì đi đường thường (blob bị từ chối được log một lần);
  `ShaderCacheStats::precompiled` đếm số lần dùng được.
- Metal: wgpu 30 không có cache ra đĩa, chỉ dựa vào cache của driver.

## 7. Bảo mật gói hiệu ứng

Gói zip là dữ liệu không tin cậy (tải từ chợ hiệu ứng):
- Chặn path traversal (`..`, đường dẫn tuyệt đối), giới hạn số file và tổng dung lượng giải nén.
- Không có mã native trong gói: chỉ shader, được naga validate trước khi đưa xuống driver.
- wgpu kiểm tra truy cập buffer/texture; vòng lặp vô hạn trong shader có thể treo GPU →
  giai đoạn sau: giới hạn thời gian dispatch, ký số gói (`signature` trong manifest).

## 8. Cấu trúc repo

```
crates/gpufx-core   engine Rust: package, manifest, params, runtime (wgpu)
crates/gpufx-ffi    libgpufx (.so/.dll/.dylib + .a) và include/gpufx.h
crates/gpufx-cli    lệnh `gpufx`: info, check, pack, run (test hiệu ứng không cần FFmpeg)
ffmpeg/             vf_gpufx.c và integrate.sh (thêm filter vào cây nguồn FFmpeg)
external/FFmpeg     submodule FFmpeg, ghim n9.0-2-g03d9533176 (release/9.0) = commit của bản build sẵn
docker/, build.sh   build FFmpeg + gpufx một lệnh trong Docker (linux64, win64)
packages/gpufx    38 hiệu ứng (nhóm ffmpeg, slideshow, standalone): chỉnh màu, blur, sharpen, chroma key, overlay, chuyển cảnh, hstack/vstack (số input thay đổi, output lớn hơn input)...
scripts/            build-prebuilt.sh (chỉ build libavfilter, thay vào FFmpeg build sẵn),
                    test-bundle.sh (chạy hiệu ứng qua ffmpeg của gói),
                    install-libgpufx.sh (build + cài .pc cho pkg-config),
                    pack-packages.sh/.ps1 (chỉ đóng gói hiệu ứng thành zip)
```

## 9. Bản build phân phối

**Cách nhanh (CI dùng cách này):** `scripts/build-prebuilt.sh [linux64|win64]` tải bản FFmpeg
9.0 shared build sẵn (tqk2811/FFmpegBuild), build `libgpufx` và **chỉ `libavfilter`** từ
submodule với `--disable-everything` + mọi filter (`FFMPEG_FILTERS=all`, mặc định; `keep` giới hạn còn
`docker/keep-filters.txt`) + gpufx, rồi thay
`libavfilter.so.12` / `avfilter-12.dll` trong gói. Điều kiện để dùng chung ABI:

- cùng commit FFmpeg với bản build sẵn (submodule ghim `03d9533176`, script kiểm tra);
- cùng tên major (`libavfilter.so.12`, `avfilter-12.dll`); script dừng nếu bản build sẵn
  không có file trùng tên;
- ffmpeg CLI chỉ dùng API công khai và tìm filter theo tên lúc chạy, nên bớt filter không
  làm hỏng việc nạp thư viện. Với `FFMPEG_FILTERS=keep`, danh sách giữ lại phải có các filter CLI tự chèn: `null`/`anull`,
  `format`/`aformat`, `scale`/`aresample`, `trim`/`atrim`, `apad`, `crop`, `hflip`, `vflip`,
  `transpose`, `rotate`.
- Linux: RUNPATH của `libavfilter` là `$ORIGIN` (đặt bằng `patchelf`, vì configure của FFmpeg
  biến `$$` thành PID), và mọi file trong `bin/` được sửa RPATH thành `$ORIGIN/../lib`.
  Trước khi thay, script so bảng export (`nm -D`) của `libavfilter` mới với bản build sẵn: thiếu
  symbol nào thì dừng.
- `libavfilter` build lại (`--disable-autodetect`, mặc định LGPL) chỉ link `avutil`, `swscale`, `swresample`,
  nên không build `avcodec`/`avformat`/`avdevice`. Filter cần chúng, thư viện ngoài (`drawtext`, `zscale`,
  `subtitles`…) hoặc GPL (`boxblur`…) vẫn thiếu dù đã bật mọi filter (win64: 440 filter thay vì 62, dll
  `avfilter` 1,2 MB -> 6 MB, build lâu thêm khoảng một phút). Có `nasm` thì bật SIMD.
- win64: `avfilter-12.dll` dùng `msvcrt.dll` còn bản build sẵn dùng UCRT (xem
  [Backlog-vi.md](../Backlog-vi.md)).
- win64: `bin/` có `dxcompiler.dll` (DXC, tải từ NuGet bằng `scripts/fetch-dxc.sh`, kiểm
  sha256). wgpu tìm nó cạnh `ffmpeg.exe` để biên dịch shader cho D3D12; thiếu nó thì wgpu
  dùng FXC cũ, chậm tới vài phút với shader nhiều vòng lặp (lá rơi). `WGPU_DX12_COMPILER=fxc`
  ép dùng FXC.

`scripts/test-bundle.sh dist/<target>` chạy mọi hiệu ứng, biểu thức, `sendcmd`, timeline và
các ca quy tắc phải báo lỗi qua `ffmpeg` của gói. CI chạy nó cho linux64 (lavapipe) và cho
win64 trên runner `windows-latest`.

**Build đầy đủ:** `./build.sh [linux64|win64|all]` (hoặc `build.ps1` trên Windows) dựng image Docker, build
`libgpufx` bằng Rust, chép submodule `external/FFmpeg` ra thư mục tạm (submodule giữ
nguyên), chạy `integrate.sh`, rồi configure FFmpeg với:

- Mặc định build mọi filter (`FFMPEG_FILTERS=all`). Với `FFMPEG_FILTERS=keep` thì dùng
  `--disable-filters` rồi bật lại **mọi filter audio** cùng danh sách tối thiểu trong
  `docker/keep-filters.txt` (`null`, `format`, `scale`, `trim`, `crop`, `hflip`, `vflip`,
  `transpose`, `rotate`, `sendcmd`, `split`, `gpufx`). Các filter video còn giữ là hạ tầng
  mà ffmpeg CLI tự chèn (trim cho `-ss/-t`, xoay theo metadata) hoặc gpufx cần (đổi
  YUV ↔ RGBA). gpufx đã tự chuyển các format YUV thông dụng trên GPU (P1); `scale` còn giữ cho
  các format khác.
- `libgpufx` được link động: Linux dùng `rpath=$ORIGIN` để tìm `libgpufx.so` cạnh `ffmpeg`,
  Windows đặt `gpufx.dll` cạnh `ffmpeg.exe`. DLL chỉ phụ thuộc DLL hệ thống
  (đã kiểm tra bằng `objdump`). Bản win64 còn có `dxcompiler.dll` và các file license của nó trong `bin/`
  (`scripts/fetch-dxc.sh`, như luồng prebuilt).
- win64 cross-compile bằng mingw-w64 như BtbN/FFmpeg-Builds. Chưa có bản build macOS; job CI `ffmpeg-macos` build FFmpeg từ
  mã nguồn trên runner macOS chỉ để kiểm đường VideoToolbox.

## 10. Lộ trình

1. **M0 – Prototype (PR này):** gói zip, WGSL + GLSL, nhiều pass, nhiều input, texture,
   tham số + biểu thức, filter FFmpeg 9.0, CLI, 5 hiệu ứng mẫu, test tự động. Sau đó:
   texture mảng, mipmap (texture của gói và input), texture premultiplied, tham số `expr` biên dịch
   vào shader; sprite/hạt bằng shader không trạng thái (`falling-*`).
2. **M1 – Shader:** SPIR-V/HLSL/Slang, wrapper Shadertoy `mainImage`, `#include` thư viện
   shader chung (màu, noise, blend mode), hot-reload khi phát triển, output size khác input
   (crop/zoom/pad), sampler tuỳ chọn (nearest/repeat/mirror).
3. **M2 – Hiệu năng:** P1–P2 ở mục 6, benchmark trên NVIDIA/AMD/Intel/Apple.
4. **M3 – Zero-copy:** P3–P6.
5. **M4 – Hệ sinh thái:** ký gói, kho hiệu ứng, công cụ preview/chỉnh tham số trực quan,
   công cụ chuyển đổi một số định dạng hiệu ứng phổ biến (GL Transitions, `.cube` LUT).
