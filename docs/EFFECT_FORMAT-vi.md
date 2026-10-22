English: [EFFECT_FORMAT.md](EFFECT_FORMAT.md)

# Định dạng gói hiệu ứng và cách viết shader

## Cấu trúc gói

Một gói là file `.zip` (hoặc một thư mục khi phát triển) có `manifest.json` ở gốc. Đường dẫn
trong manifest tính từ gốc gói, dùng `/`.

```
my-effect/
├── manifest.json
├── shaders/main.wgsl
└── textures/lut.png
```

Đóng gói và kiểm tra:

```sh
gpufx check my-effect            # biên dịch mọi shader, báo lỗi kèm vị trí
gpufx run 'my-effect=strength=0.8' -i in.png -o out.png
gpufx pack my-effect my-effect.zip
```

Đóng gói nhiều hiệu ứng một lúc (không cần build FFmpeg hay Docker):

```sh
scripts/pack-packages.sh                         # mọi thư mục trong packages/gpufx -> dist/packages/gpufx/<group>/<name>.zip
scripts/pack-packages.sh --check -o out my-fx    # biên dịch shader trên GPU trước, ghi vào out/
.\scripts\pack-packages.ps1 -Check                # Windows
```

## manifest.json

| Trường | Kiểu | Bắt buộc | Ý nghĩa |
|--------|------|----------|---------|
| `api` | số | không (1) | Phiên bản định dạng. `1` là giá trị duy nhất; gói có giá trị khác bị từ chối với `unsupported manifest api N` |
| `id` | chuỗi | có | Định danh dạng reverse-DNS |
| `name` | chuỗi | có | Tên hiển thị |
| `used_for` | mảng | có | Các filter FFmpeg dùng package này: effect ghi `["gpufx"]`. Mảng rỗng hoặc tên lạ (tên hợp lệ: `gpufx`, `gpufx_ai_upscale`, `gpufx_ai_framerate`) thì không load được; filter `gpufx` từ chối package mà danh sách không có `gpufx` (`package <id> is for gpufx_ai_upscale, not gpufx`) |
| `version`, `description` | chuỗi | không | |
| `inputs` | mảng | không (`[{"name":"src"}]`) | Các video input, theo thứ tự pad của filter, kèm quy tắc (xem bên dưới) |
| `output` | mảng | không (một output mang tên output chính của pass cuối, mọi format GPU, kích thước input đầu) | Các output của effect, theo thứ tự output pad của filter, kèm quy tắc (xem bên dưới và [Nhiều output](#nhiều-output)) |
| `params` | mảng | không | Tham số, xem bên dưới |
| `textures` | mảng | không | Ảnh PNG đi kèm (LUT, mask, sprite), xem [Texture](#texture) |
| `groups` | mảng | có | Các group pass, mỗi group có pass compute và thiết bị nó cần; dùng group đầu tiên khớp thiết bị, xem [Nhóm pass và yêu cầu thiết bị](#nhóm-pass-và-yêu-cầu-thiết-bị) |

## Quy tắc input/output

Gói có thể khai báo input nhận format/kích thước nào và output ra format nào. Stream
không khớp sẽ **bị báo lỗi** (filter không tự chuyển đổi ngầm), lỗi nêu rõ input và quy tắc:

```
unsupported: input `src` of `Chroma Key`: pixel format `gray` is not supported (accepted: yuv420p, rgba)
unsupported: input `second` of `Crossfade`: size 300x180 must equal the first input (320x180)
```

Mỗi phần tử `inputs`:

| Trường | Mặc định | Ý nghĩa |
|--------|----------|---------|
| `name` | | Tên input, cũng là tên texture trong shader |
| `description` | | Mô tả |
| `formats` | `[]` (mọi format) | Pixel format nhận (tên của FFmpeg: `yuv420p`, `nv12`, `rgba`, `rgb24`...) |
| `width`, `height` | không giới hạn | `{ "min": 16, "max": 4096, "multiple_of": 2 }`, mỗi trường đều tuỳ chọn |
| `same_size` | `false` | Kích thước phải bằng input đầu tiên (không dùng cho input đầu) |
| `mipmaps` | `false` | Texture của input có đủ chuỗi mip, sinh trên GPU mỗi frame, cho shader thu nhỏ ảnh nhiều (`textureSampleLevel(src, smp, uv, lod)`); xem [Mipmap](#mipmap) |
| `repeat` | không có | (chỉ input cuối, chỉ WGSL) `{ "default": 2, "min": 2, "max": 16 }`: input đại diện cho số pad thay đổi được, xem [Số input thay đổi được](#số-input-thay-đổi-được) |

Mỗi phần tử `output` (một mảng; dạng object của bản cũ là lỗi: `` `output` is an array: [{"name": "out", ...}] ``):

| Trường | Mặc định | Ý nghĩa |
|--------|----------|---------|
| `name` | (bắt buộc) | Texture mà một pass ghi (xem [Nhiều output](#nhiều-output)), cũng là tên output pad của effect có nhiều output |
| `formats` | mọi format GPU (bên dưới) | Pixel format output này được có, theo thứ tự ưu tiên |
| `size` | `first` | Kích thước output này: `first`, `hstack` hoặc `vstack` (bên dưới) |
| `bypass` | input đầu | Input mà output này truyền thẳng khi effect bị tắt (`<effect>.enable`) |

`formats`: danh sách pixel format output được phép, theo thứ tự ưu tiên. Không ghi thì
danh sách là `rgba`, `rgba64le`, `nv12`, `p010le`, `yuv420p`, `yuv422p`, `yuv444p`, `yuv420p10le`,
`yuv422p10le`, `yuv444p10le`, `yuva420p`, `yuva444p`: các format gpufx ghi trên GPU. Vì vậy hiệu ứng
không có `formats` có thể xuất YUV không alpha: alpha mà hiệu ứng ghi bị bỏ, trừ khi filter
phía sau nhận format có alpha. **Hiệu ứng tạo ra alpha nên khai báo `formats`** (ví dụ
`["rgba", "yuva420p"]`). FFmpeg
chọn một format trong danh sách khi nối filter; filter phía sau đòi format ngoài danh sách
thì FFmpeg tự chèn bộ chuyển đổi sau `gpufx`.

`size`: `first` (mặc định) — output có kích thước input đầu; `hstack` — mọi input phải cao
bằng input đầu, chiều rộng output là tổng chiều rộng; `vstack` — mọi input phải rộng bằng input đầu, chiều
cao output là tổng chiều cao. Lệch là lỗi giống `same_size` (khi cấu hình và khi kích thước frame đổi):

```
unsupported: input `src1` of `Horizontal Stack`: height 240 must equal the first input's (180) to stack side by side
```

Khi đó output có thể lớn hơn mọi input, tối đa bằng cạnh texture lớn nhất của GPU
(`max_texture_dimension_2d`, từ 8192 trở lên trên GPU desktop); lớn hơn là lỗi. Hiệu ứng phía sau trong chain
hoặc graph thấy kích thước đã ghép, và filter FFmpeg đặt kích thước đó cho output link (frame rate và aspect
ratio vẫn lấy từ input đầu).

```json
"inputs": [
  { "name": "src", "formats": ["yuv420p", "nv12", "rgba"],
    "width": { "min": 64, "multiple_of": 2 }, "height": { "min": 64, "multiple_of": 2 } },
  { "name": "matte", "formats": ["gray"], "same_size": true }
],
"output": [{ "name": "out", "formats": ["yuva420p", "rgba"] }]
```

Cách áp dụng:

- **FFmpeg:** input không có `formats` nhận các format gpufx chuyển trên GPU (danh sách trên, thêm
  `yuvj420p`/`yuvj422p`/`yuvj444p`); FFmpeg đổi format khác sang một trong số đó. Input có
  `formats` nhận nguyên format của stream; khác danh sách thì lỗi khi cấu hình filter graph.
  Muốn chạy thì đổi format trước bằng `format=yuv420p,gpufx=...`. Kích thước được kiểm tra
  khi cấu hình và mỗi khi kích thước frame đổi. Tên format sai chính tả cũng là lỗi.
- **Chuỗi và đồ thị** (`graph='a|b'`, `graph='...'`): mỗi hiệu ứng được kiểm tại chỗ của nó. Hiệu ứng
  đọc hiệu ứng khác thấy kích thước của output nó đọc (kích thước input đầu, hoặc kích thước đã ghép khi có `size`) và format đầu tiên
  trong `formats` của output đó mà hiệu ứng đọc nhận; input pad được nhiều hiệu ứng đọc phải có
  format mà tất cả đều nhận. Vì vậy `same_size` cũng áp dụng giữa hai nhánh của đồ thị.
- **`gpufx run`:** format lấy từ PNG (`rgba`, `rgb24`, `gray`, `ya8`, bản 16-bit là
  `rgba64be`, `rgb48be`, `gray16be`, `ya16be`). CLI luôn ghi PNG RGBA nên không kiểm tra
  `formats` của output.
- Shader luôn thấy RGBA alpha thường (straight), dù format vào/ra là gì: chuyển đổi chạy trên GPU,
  ngoài shader. Texture là `rgba8unorm`, hoặc `rgba16float` khi input hay output của chuỗi trên 8 bit
  (video 10-bit giữ được độ chính xác).

Mỗi phần tử `params`:

| Trường | Ý nghĩa |
|--------|---------|
| `name` | Tên, cũng là tên trường trong `params.<name>` |
| `type` | `float`, `int`, `bool`, `vec2`, `vec3`, `vec4`, `color`, `expr`, `enum` |
| `default` | Số, mảng số, `true/false`, hoặc chuỗi (`"#ff8800"`; biểu thức của `expr`; tên một giá trị của `enum`). `enum` không có `default` thì lấy giá trị đầu tiên |
| `min`, `max` | Giá trị bị kẹp vào khoảng này (không dùng cho `expr` và `enum`) |
| `vars` | Chỉ cho `expr`: tên các biến của biểu thức, theo thứ tự tham số của hàm trong shader |
| `values` | Chỉ cho `enum`: tên các giá trị, xem [Tham số enum](#tham-số-enum) |
| `description` | Mô tả |

Kiểu trong shader: `float`→`f32`/`float`, `int` và `enum`→`i32`/`int`, `bool`→`u32`/`uint` (0 hoặc 1),
`vecN`→`vecNf`/`vecN`, `color`→`vec4f`/`vec4` (RGBA 0..1). `expr` không nằm trong `params` mà trở
thành một hàm, xem [Tham số biểu thức](#tham-số-biểu-thức).

Mỗi phần tử `passes` (của một group):

| Trường | Mặc định | Ý nghĩa |
|--------|----------|---------|
| `shader` | | File shader trong gói |
| `language` | theo đuôi file | `wgsl` hoặc `glsl` (`.glsl`, `.comp` là GLSL) |
| `entry` | `main` | Hàm compute (WGSL; GLSL luôn là `main`) |
| `inputs` | mọi input rồi mọi texture | Texture pass này đọc: tên input, texture, hoặc output của pass trước |
| `output` | `["out"]` | Mảng 1 đến 4 tên texture pass này ghi (chuỗi đơn là lỗi). Tên đầu là output chính |

Pass chạy ở kích thước của output effect mà nó ghi (xem [Nhiều output](#nhiều-output)): kích thước input đầu tiên, trừ khi `size`
của output đó quy định khác. Tên input/texture/param phải là định danh hợp lệ,
không trùng nhau, không bắt đầu bằng `gpufx` và không dùng `globals`, `params`, `out_tex`, `out_tex1`, `out_tex2`, `out_tex3`, `smp`.
Param không được tên `enable` hay `bypass`: các key inline `enable=` và `bypass=` của một effect (`graph='my-effect.zip=enable=lt(t\,2)'`) dùng để bật/tắt một effect của chain hoặc graph.

**Một pass ghi nhiều output.** `output` liệt kê tối đa 4 tên. Tên đầu là output chính (`out_tex`, ghi bằng `gpufx_write`); các
tên sau là `out_tex1`, `out_tex2`, `out_tex3` (ghi bằng `gpufx_write1`..`gpufx_write3`), bind sau các texture input (xem bảng
binding). Chúng cùng format và kích thước với output chính, và các pass sau đọc chúng theo tên. Các tên trong một mảng không được
trùng nhau. Mọi texture một pass ghi phải được pass sau đọc hoặc là output của effect
(`pass 0 writes `x`, which no later pass reads and is no output of the effect`):

```json
"passes": [
  { "shader": "shaders/split.wgsl", "inputs": ["src"], "output": ["base", "detail"] },
  { "shader": "shaders/merge.wgsl", "inputs": ["base", "detail"], "output": ["out"] }
]
```

```wgsl
// shaders/split.wgsl: một input, nên out_tex1 ở binding 5
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(src, smp, gpufx_uv(id), 2.0);
    let full = textureLoad(src, vec2i(id.xy), 0);
    gpufx_write(id, c);                                       // base
    gpufx_write1(id, vec4f(full.rgb - c.rgb + 0.5, full.a)); // detail
}
```

### Nhiều output

`output` liệt kê 1 đến 4 output. Mỗi output là texture cùng tên do một pass ghi, nên một effect có thể cho ảnh màu và
matte từ cùng một dispatch, hoặc lấy matte từ một pass sớm:

```json
"inputs": [{ "name": "src", "formats": ["rgba"] }],
"output": [
  { "name": "color", "formats": ["rgba", "nv12"] },
  { "name": "matte", "formats": ["gray", "rgba"] }
],
"groups": [{ "passes": [
  { "shader": "key.wgsl", "inputs": ["src"], "output": ["color", "matte"] }
]}]
```

Luật:

- Bỏ trống thì `output` là một output mang tên output chính của pass cuối (`[{"name": "out"}]` khi pass cuối không ghi
  `output`), nên effect một output không cần khai báo.
- Mỗi tên output do đúng một pass của mỗi group ghi; pass đó không nhất thiết là pass cuối.
- Tên output là định danh, không trùng nhau, không trùng input, texture, param, và không phải `enable` hay `bypass`.
- Pass chạy ở kích thước của output effect đầu tiên nó ghi, hoặc của output 0 khi nó không ghi output nào (pass làm
  texture cho pass sau); `globals.size`, `gpufx_uv`, `gpufx_in_bounds` theo kích thước đó. Các output một pass ghi
  phải cùng `size`, và texture được nhiều pass ghi thì ghi ở một kích thước.
- `bypass` là tên input mà output truyền thẳng khi effect bị tắt; input đó phải có kích thước của output.

### Số input thay đổi được

Input có `repeat` phải là input cuối. Nó nở thành các pad tên `<name>0`, `<name>1`...
(`src0`, `src1` với input `src`), mỗi label mà node của graph đọc là một pad
(`[0][1][2]hstack.zip[out]` có 3 input, như `hstack` của FFmpeg nhận mọi input nối vào), hoặc `default` pad
khi node không ghi label input nào (chain, `graph='hstack.zip'`), với `min <= N <= max` (`max` tối đa 16, `min`
tối thiểu 1). Các trường khác của input (`formats`, `width`, `height`, `mipmaps`, `same_size`) áp cho mọi pad.
Gói được biên dịch cho đúng số đó; số input pad của filter `gpufx` vẫn suy ra từ graph như mọi khi. Danh sách `inputs` của pass có
tên input này thì đọc mọi pad của nó. `gpufx pack --precompile` chỉ biên dịch sẵn cho số `default`; số khác thì
biên dịch shader lúc nạp graph.

Shader không biết trước tên pad, nên prelude của gói có input `repeat` khai báo thêm (trên các input của
hiệu ứng mà pass đọc, theo thứ tự pad):

```wgsl
fn gpufx_input_count() -> u32                       // số input
fn gpufx_input_size(i: u32) -> vec2u                // textureDimensions của input i (0 khi ngoài khoảng)
fn gpufx_input_load(i: u32, p: vec2i) -> vec4f      // textureLoad của input i ở mức 0 (0 khi ngoài khoảng)
```

Xem `packages/gpufx/ffmpeg/hstack/shaders/hstack.wgsl`.

## Nhóm pass và yêu cầu thiết bị

`groups` (bắt buộc, không rỗng) liệt kê các bộ pass thay thế nhau cho cùng một effect. Mỗi phần tử:

| Trường | Mặc định | Ý nghĩa |
|--------|----------|---------|
| `name` | không có | Nhãn trong thông báo lỗi và `gpufx info`. Nếu có thì không được rỗng và không trùng giữa các group |
| `requires` | `{}` (mọi thiết bị) | Thiết bị mà group này chạy được, xem bên dưới |
| `passes` | | Các pass của group này (không rỗng), như mô tả ở trên |

Group **đầu tiên** có `requires` khớp thiết bị sẽ được dùng; nên đặt group cụ thể nhất lên đầu và group chung ở cuối. Mọi group
phải ghi đủ mọi output của effect (các texture có tên trong `output`). `inputs`, `output`, `params` và `textures` dùng chung cho mọi group, nên các group là một effect với một bộ
tham số; chỉ phần pass khác nhau, và số pass của các group có thể khác nhau. `passes` ở cấp trên cùng của manifest cũ đã bị bỏ: bọc các pass vào một group.
Group dùng được với mọi giá trị `api`.

Các khoá của `requires` (bỏ qua = `"*"`):

| Khoá | Giá trị | Khớp với |
|------|---------|----------|
| `os` | `windows`, `linux`, `macos`, `web` | Hệ điều hành |
| `backend` | `vulkan`, `d3d12`, `metal`, `gl`, `webgpu` | Backend wgpu của thiết bị |
| `vendor` | `nvidia`, `amd`, `intel` | Hãng GPU (vendor id bằng 0 thì đoán từ tên adapter) |
| `features` | `shader-f16`, `cooperative-matrix`, `cooperative-matrix-f16` | Feature của thiết bị |

- `os`, `backend`, `vendor` nhận `"*"` (mọi giá trị) hoặc một danh sách không rỗng, khớp **một trong** các giá trị (OR). `"*"` nằm trong danh sách
  và chuỗi trần khác `"*"` (`"vendor": "nvidia"`; phải viết `["nvidia"]`) đều là lỗi, giá trị hay khoá không biết cũng vậy.
- `features` là danh sách và cần **tất cả** (AND).
- Không group nào khớp thì mở effect lỗi, thông báo liệt kê lý do của từng group (vd `needs backend d3d12; needs feature shader-f16`).

```json
{
  "id": "io.github.tqk2811.glow",
  "name": "Glow",
  "used_for": ["gpufx"],

  "inputs": [{ "name": "src" }],
  "params": [{ "name": "radius", "type": "float", "default": 8, "min": 0, "max": 64 }],
  "groups": [
    {
      "name": "dx12",
      "requires": { "os": ["windows"], "backend": ["d3d12"] },
      "passes": [{ "shader": "shaders/glow_dx12.wgsl", "inputs": ["src"], "output": ["out"] }]
    },
    {
      "name": "tensor-core",
      "requires": { "backend": ["vulkan"], "vendor": ["nvidia"], "features": ["cooperative-matrix-f16"] },
      "passes": [
        { "shader": "shaders/glow_coop.wgsl", "inputs": ["src"], "output": ["tmp"] },
        { "shader": "shaders/glow_coop_merge.wgsl", "inputs": ["src", "tmp"], "output": ["out"] }
      ]
    },
    {
      "name": "generic",
      "passes": [
        { "shader": "shaders/glow_h.wgsl", "inputs": ["src"], "output": ["tmp"] },
        { "shader": "shaders/glow_v.wgsl", "inputs": ["tmp"], "output": ["out"] }
      ]
    }
  ]
}
```

Cách chọn group:

- `gpufx_effect_open` mở effect trước trên **device noop** (pad và format phải biết trước khi có device GPU). Ở đó chỉ kiểm
  `os`: mọi group khớp OS mà noop device có đủ `features` đều được compile để kiểm shader. Group cần feature noop device
  không có (vd `cooperative-matrix`) bị bỏ qua; nếu **mọi** group đều cần feature như vậy thì mở lỗi.
  Đây là hạn chế đã biết (xem [Backlog-vi.md](Backlog-vi.md)).
- Trên device thật (device Vulkan của FFmpeg, hoặc device mặc định) group được chọn theo đủ các khoá `requires`.
- `gpufx pack --precompile` chỉ precompile các group cho phép `d3d12` trên `windows` (cache shader D3D12); group cần
  feature mà WARP không có bị bỏ qua, gói không có group nào như vậy thì không precompile gì cả.
  `gpufx info` liệt kê các group của gói cùng `requires`.

## Viết shader WGSL

Runtime chèn sẵn phần khai báo sau (ví dụ cho gói có input `src` và tham số `strength`):

```wgsl
struct GpufxGlobals {
    size: vec2f,          // kích thước của pass đang chạy (px)
    time: f32,            // thời gian (giây); f32 mất độ chính xác khi clip dài
    frame: u32,           // số frame, đếm riêng mỗi filter (không bền khi seek)
    time_int: i32,        // thời gian chính xác: time_int + time_frac giây,
    time_frac: f32,       //   time_frac trong [0, 1), kể cả khi thời gian âm
    pixel_aspect: f32,    // rộng / cao của một pixel (SAR), 1 với pixel vuông
    gpufx_reserved: f32,
};
struct GpufxParams { strength: f32 };
@group(0) @binding(0) var<uniform> globals: GpufxGlobals;
@group(0) @binding(1) var<uniform> params: GpufxParams;
@group(0) @binding(2) var out_tex: texture_storage_2d<rgba8unorm, write>; // rgba16float khi trên 8 bit
@group(0) @binding(3) var smp: sampler;
@group(0) @binding(4) var src: texture_2d<f32>;
// Texture có `layers` hoặc `grid` là texture_2d_array<f32> (GLSL: texture2DArray).
// Mỗi tham số `expr` thêm fn gpufx_expr_<name>(<vars>: f32...) -> f32.
fn gpufx_in_bounds(id: vec3u) -> bool
fn gpufx_uv(id: vec3u) -> vec2f          // tâm pixel, 0..1
fn gpufx_write(id: vec3u, c: vec4f)      // kẹp 0..1 rồi ghi
```

Chuyển động theo thời gian nên dựa vào `time_int` và `time_frac` nếu clip có thể dài: `time`
là f32 nên sau một ngày chỉ còn bước khoảng 0,008 s. Xem `falling-*/shaders/leaves.wgsl`, đếm
thời gian theo tick số nguyên.

Shader của bạn chỉ cần:

```wgsl
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    gpufx_write(id, vec4f(c.rgb * params.strength, c.a));
}
```

Lưu ý:
- Runtime dispatch theo nhóm **8×8**; hãy dùng `@workgroup_size(8, 8)`.
- Trong compute shader không có đạo hàm, nên dùng `textureSampleLevel(..., 0.0)` hoặc
  `textureLoad` thay cho `textureSample`.
- Màu là RGBA 0..1 (8-bit hoặc half float), không chuyển đổi gamma (giá trị sRGB như trong video).
  Luôn ghi qua `gpufx_write`: storage format của `out_tex` tuỳ theo frame (trong GLSL prelude khai báo
  `rgba8` hoặc `rgba16f`).

## Viết shader GLSL

GLSL 450 compute theo kiểu Vulkan (texture và sampler tách rời). Nếu file có `#version` thì
prelude được chèn ngay sau dòng đó, nếu không runtime tự thêm `#version 450`.

```glsl
#version 450
layout(local_size_x = 8, local_size_y = 8) in;

void main() {
    uvec3 id = gl_GlobalInvocationID;
    if (!gpufx_in_bounds(id)) return;
    vec4 c = textureLod(sampler2D(src, smp), gpufx_uv(id), 0.0);
    gpufx_write(id, vec4(c.rgb * params.strength, c.a));
}
```

## Tham chiếu shader: shader nhận gì ngoài parameter

Mỗi pass là một compute shader. Runtime ghi một prelude trước code của tác giả (`prelude` và `glsl_with_prelude` trong
`crates/gpufx-core/src/runtime.rs`); code của tác giả không được khai báo lại các tên này.
Dạng ngắn của prelude nằm ở [Viết shader WGSL](#viết-shader-wgsl); các bảng dưới đây là tham chiếu đầy đủ.

**Uniform block `globals` có sẵn** (binding 0, 32 byte, ghi lại cho mỗi frame của mỗi effect)

| Field | Kiểu WGSL | Kiểu GLSL | Offset | Ý nghĩa |
|-------|-----------|-----------|--------|---------|
| `size` | `vec2f` | `vec2` | 0 | Size output tính bằng pixel (rộng, cao) dạng float. Là kích thước pass đang chạy: kích thước output effect mà pass ghi (của input đầu, hoặc size xếp chồng với `size` `hstack`/`vstack`), xem [Nhiều output](#nhiều-output) |
| `time` | `f32` | `float` | 8 | Thời điểm hiển thị tính bằng giây (`t` của filter). Mất độ chính xác với clip dài (bước khoảng 0.008 s sau một ngày) |
| `frame` | `u32` | `uint` | 12 | Số frame của instance filter này (cũng là `n` trong expression); về 0 khi seek, nên không dùng cho chuyển động theo thời gian |
| `time_int` | `i32` | `int` | 16 | Số giây nguyên của thời gian (floor; bão hòa ngoài khoảng i32) |
| `time_frac` | `f32` | `float` | 20 | Phần lẻ của thời gian trong [0, 1), kể cả khi thời gian âm. `time_int + time_frac` là thời gian chính xác |
| `pixel_aspect` | `f32` | `float` | 24 | Sample aspect ratio (rộng / cao của một pixel); 1 với pixel vuông hoặc khi giá trị không hợp lệ |
| `gpufx_reserved` | `f32` | `float` | 28 | Luôn bằng 0; để dành |

Thời gian không hữu hạn thành 0.

**Uniform block `params`** (binding 1): `GpufxParams`, mỗi parameter của manifest một field theo thứ tự manifest, tên như parameter.

| Kiểu trong manifest | WGSL | GLSL | Align / size (byte) | Ghi chú |
|---------------------|------|------|---------------------|---------|
| `float` | `f32` | `float` | 4 / 4 | |
| `int` | `i32` | `int` | 4 / 4 | Làm tròn tới số nguyên gần nhất |
| `enum` | `i32` | `int` | 4 / 4 | Số của tên giá trị được chọn |
| `bool` | `u32` | `uint` | 4 / 4 | 0 hoặc 1 |
| `vec2` | `vec2f` | `vec2` | 8 / 8 | |
| `vec3` | `vec3f` | `vec3` | 16 / 12 | Một scalar có thể nằm ở ô thứ tư |
| `vec4`, `color` | `vec4f` | `vec4` | 16 / 16 | `color` là RGBA 0..1 |
| `expr` | không có field | không có field | không | Thành hàm `gpufx_expr_<name>(<vars>)` nhận và trả `f32`/`float` (đối số theo thứ tự `vars`); NaN và vô cực thành 0 |

Size struct làm tròn lên bội của 16 byte. Không có uniform parameter nào thì struct chứa một float `_unused`. Chi tiết về `expr`
(hàm cho phép, giới hạn, build lại pipeline): [Tham số biểu thức](#tham-số-biểu-thức).

**Binding** (bind group 0 cho mọi pass)

| Binding | Tên WGSL / GLSL | Loại | Nội dung |
|---------|-----------------|------|----------|
| 0 | `globals` | uniform buffer | `GpufxGlobals` (ở trên) |
| 1 | `params` | uniform buffer | `GpufxParams` (ở trên) |
| 2 | `out_tex` | storage texture 2D chỉ ghi | Output của pass. `rgba8unorm` (`rgba8` trong GLSL), hoặc `rgba16float` (`rgba16f`) khi một input hoặc output của chuỗi quá 8 bit |
| 3 | `smp` | sampler filtering | Linear, clamp ở mép, linear giữa các mip level; trong GLSL là `sampler` riêng (dùng `sampler2D(tex, smp)`) |
| 4 + i | tên thứ i trong `inputs` của pass | texture đọc, float, filterable | `texture_2d<f32>` (`texture2D`), hoặc `texture_2d_array<f32>` (`texture2DArray`) với texture của package có `layers`/`grid`. Manifest không có `inputs` thì danh sách là mọi input của manifest, rồi mọi texture của package |
| 4 + n + k − 1 | `out_tex{k}`, k = 1..3 (n = số `inputs` của pass) | storage texture 2D chỉ ghi | Output phụ thứ k của pass (`output[k]`), cùng format với `out_tex`; chỉ khai báo khi pass có đủ số output đó |

Một tên trong `inputs` được tra theo thứ tự: input của manifest (frame đã chuyển đổi; chỉ level 0, trừ khi input khai báo
`mipmaps` thì cả chuỗi mip), texture của package (`rgba8unorm`, nạp một lần, chuỗi mip tạo trên CPU khi có `mipmaps`), hoặc
output của pass trước (level 0). Pass không đọc được `out_tex` hay `out_tex1`..`out_tex3`.

Một pass đọc tối đa 16 texture (input của effect, tính cả mọi pad của input `repeat`, texture của package và output của pass
trước; pass không có `inputs` đọc mọi input của effect và mọi texture của package) và ghi tối đa 4 (`out_tex` và
`out_tex1`..`out_tex3`). Đây là giới hạn mặc định của WebGPU (`maxSampledTexturesPerShaderStage` 16,
`maxStorageTexturesPerShaderStage` 4); gpufx xin đúng mức này trên mọi backend dù phần cứng cho nhiều hơn, để một package chạy
giống nhau ở mọi nơi. Manifest hiện chưa kiểm giới hạn 16 lần đọc: vượt thì lỗi lúc tạo bind group layout.

**Dispatch và tọa độ**

| Mục | Giá trị |
|-----|---------|
| Dispatch | Mỗi pass một lần `dispatch_workgroups(ceil(w / 8), ceil(h / 8), 1)`, theo thứ tự trong manifest, tất cả trong một compute pass; `w`, `h` = kích thước của pass (`globals.size`). Shader khai báo `@workgroup_size(8, 8)` (GLSL `local_size_x = 8, local_size_y = 8`); runtime không kiểm tra điều này. Thread vượt mép phải `return`: `gpufx_in_bounds(id)` |
| Tọa độ pixel | `id.xy` của `global_invocation_id`, số nguyên, gốc ở góc trên trái, y hướng xuống; `textureLoad`/`imageStore` dùng `vec2i(x, y)` |
| Tọa độ chuẩn hóa | `gpufx_uv(id) = (id.xy + 0.5) / globals.size`, tâm pixel, 0..1, v hướng xuống |
| Hàm hỗ trợ | `gpufx_in_bounds(id)`, `gpufx_uv(id)`, `gpufx_write(id, color)` (kẹp 0..1 rồi ghi), `gpufx_write1`..`gpufx_write3` cho output phụ. Bản GLSL nhận `uvec3` |
| Đạo hàm | Compute shader không có: dùng `textureSampleLevel` / `textureLod` hoặc `textureLoad` |
| Tên dành riêng | `globals`, `params`, `out_tex`, `out_tex1`, `out_tex2`, `out_tex3`, `smp`, mọi tên bắt đầu bằng `gpufx`; không có parameter tên `enable` hay `bypass` |

**Màu**

| Mục | Giá trị |
|-----|---------|
| Thứ tự kênh và alpha | RGBA, alpha thẳng (straight, không premultiplied); libgpufx chia input premultiplied cho alpha trước shader và nhân lại ở output khi cần |
| Dải giá trị | Float 0..1 (`unorm` 8 bit, hoặc half float khi trên 8 bit) |
| Transfer | Không chuyển gamma: giá trị như trong video (kiểu sRGB / BT.709), không phải ánh sáng tuyến tính; HDR PQ/HLG bị coi như SDR |
| Chuyển format | YUV hay format khác được chuyển sang/từ RGBA trên GPU, ngoài shader; shader không bao giờ thấy format nguồn |
| Texture của package | Luôn `rgba8unorm`; alpha thẳng trừ khi `premultiply: true` (premultiplied; filter đúng); mip level luôn tính theo trọng số alpha |
| Mip level của input | Tạo trên GPU mỗi frame bằng trung bình có trọng số alpha của 2x2 texel |

## Texture

Mỗi phần tử `textures` tạo một texture `rgba8unorm` chỉ đọc từ các file PNG trong gói, gắn theo `name`
(không trùng input, output của pass hay texture khác):

```json
"api": 1,
"textures": [
  { "name": "lut", "path": "textures/lut.png" },
  { "name": "leaves", "layers": ["textures/maple.png", "textures/oak.png"], "mipmaps": true, "premultiply": true },
  { "name": "petals", "path": "textures/petals.png", "grid": [4, 2], "count": 7, "mipmaps": true, "premultiply": true }
]
```

| Trường | Mặc định | Ý nghĩa |
|--------|----------|---------|
| `name` | | Tên trong shader |
| `path` | | Một PNG. Không có `grid` thì là `texture_2d<f32>` (api 1) |
| `layers` | | Các PNG **cùng kích thước**, là các layer của `texture_2d_array<f32>`, theo thứ tự |
| `grid` | | `[cols, rows]` đi với `path`: cắt atlas thành các layer của `texture_2d_array<f32>`, theo từng hàng. Rộng và cao phải chia hết |
| `count` | `cols*rows` | Số ô dùng, khi các ô cuối bỏ trống |
| `mipmaps` | `false` | Sinh đủ chuỗi mip trên CPU khi nạp gói (mỗi mức từ mức trên, lọc tam giác, sau `premultiply`) |
| `premultiply` | `false` | Nhân RGB với alpha khi nạp: shader đọc màu premultiplied |

Quy tắc: có đúng một trong `path`/`layers`; `grid` chỉ đi với `path`, `count` chỉ đi với `grid`; từ 1 đến
256 layer; mỗi ảnh tối đa **4096** pixel mỗi cạnh (runtime cũng kiểm `max_texture_dimension_2d` và
`max_texture_array_layers` của device và báo lỗi, thay vì để wgpu làm sập process); tổng ảnh của gói
giải mã ra tối đa **64 M texel** (256 MiB RGBA8). Kích thước lấy từ header PNG khi mở gói (`gpufx check`
báo luôn), và bộ giải mã bị giới hạn, nên file nhỏ khai ảnh rất lớn bị từ chối trước khi tốn bộ nhớ.

Việc nạp làm một lần cho mỗi gói và device, trên CPU: ảnh đã giải mã, các layer đã cắt và chuỗi mip (thêm
một phần ba) cùng nằm trong RAM tới khi upload, nên đỉnh khoảng gấp đôi kích thước giải mã (tới khoảng
700 MiB với gói chạm giới hạn 64 M texel). PNG 16 bit được giải mã ở 16 bit (gấp đôi số byte, tính vào
giới hạn 256 MiB mỗi ảnh của bộ giải mã) rồi giảm về 8 bit: texture của gói luôn là `rgba8unorm`. Các mức
mip được lọc trên alpha premultiplied kể cả khi tắt `premultiply` (rồi chia lại), nên pixel trong suốt
không làm tối viền.

Texture mảng đọc theo chỉ số layer, chỉ số này có thể khác nhau theo từng pixel:

```wgsl
let n = textureNumLayers(leaves);                              // số layer
let c = textureSampleLevel(leaves, smp, uv, layer, lod);       // layer: u32 hoặc i32
let d = textureLoad(leaves, vec2i(x, y), layer, 0);
```
```glsl
vec4 c = textureLod(sampler2DArray(leaves, smp), vec3(uv, layer), lod);
```

Mỗi layer bị kẹp ở mép của chính nó: khác với atlas tự cắt, lọc tuyến tính và mip không bao giờ lem
sang ảnh bên cạnh.

**Alpha.** Màu PNG là straight alpha, pixel trong suốt thường có RGB = 0: lọc (bilinear, mip) làm tối
viền sprite. Với `premultiply: true` texture giữ màu premultiplied và lọc đúng; ghép bằng
`acc = c + acc * (1 - c.a)` rồi chia lại cho alpha trước `gpufx_write` (nhận straight alpha). Mặc định tắt
để LUT và mask giữ nguyên giá trị.

**Màu.** Giá trị texture được coi là cùng transfer với video (sRGB/BT.709 gamma), không chuyển đổi, như
phần còn lại của engine. Khi pipeline chuyển sang linear, sẽ có trường `colorspace` quy định cách đổi.

### Mipmap

Sampler chung `smp` lọc tuyến tính giữa các mức mip (`mipmap_filter: Linear`); texture chỉ có 1 mức lấy
mẫu y như trước. Compute shader không có đạo hàm nên shader tự chọn mức:
`lod = log2(số texel theo chiều ngang / số pixel trên màn)`, ví dụ tính một lần cho mỗi sprite thay vì
mỗi pixel. Không có mip thì ảnh vẽ nhỏ hơn nhiều so với kích thước thật sẽ nhấp nháy, răng cưa.

Input cũng có mip được (`"mipmaps": true` trong `inputs`): chuỗi mip được sinh trên GPU ngay sau khi
chuyển đổi input, hoặc sau hiệu ứng ghi ra nó trong chuỗi/đồ thị, mỗi frame, ngay trong texture của
frame (tốn thêm một phần ba bộ nhớ của texture đó, không copy). Hiệu ứng đọc cùng frame mà không khai
`mipmaps` chỉ thấy mức 0. Mỗi mức là trung bình 2×2 có trọng số alpha. Dùng khi hiệu ứng thu nhỏ ảnh
nhiều (ảnh 4000 px trong một hộp nhỏ).

## Sprite và hạt

`falling-maple`/`falling-ginkgo` vẽ tới 256 sprite trong một pass compute. Mẫu chung:

- **Không trạng thái:** mỗi hạt là hàm thuần của `(seed, slot, thời gian)`. Mỗi slot lặp một chu kỳ cố
  định; chu kỳ mới là một hạt ngẫu nhiên mới ("sinh lại"), đổi khi hạt ở ngoài khung. Nhờ vậy seek, bỏ
  hoặc lặp frame và encode chia đoạn đều cho cùng ảnh. Dùng `globals.time_int` và `time_frac` (hoặc
  `time`), **không dùng `globals.frame`**: nó đếm riêng mỗi filter và về 0 khi seek. `-ss` trước `-i`
  (không có `-copyts`) đặt thời gian về 0; tham số `offset` giúp bù lại.
- **Cache trong workgroup:** 64 thread của workgroup tính các hạt một lần vào
  `var<workgroup> leaves: array<Leaf, 256>` (ở đây 40 byte mỗi hạt: giữ dưới giới hạn mặc định 16 KiB),
  rồi `workgroupBarrier()`. Barrier phải nằm trong **luồng điều khiển đồng nhất**: gọi
  `gpufx_in_bounds` *sau* barrier, không phải trước.
- **Mỗi pixel:** bỏ qua hạt có vòng tròn bao không chứa pixel, đổi pixel sang không gian sprite, lấy mẫu
  texture mảng ở mức mip tính cho từng sprite, ghép premultiplied.
- **Tham số quyết định chu kỳ** (`speed`, `wind`, `size`, `count`, `life`) không nên là biểu thức
  FFmpeg theo `t`: vị trí là `f(t * speed)` chứ không phải tích phân của speed, nên mọi hạt sẽ nhảy.
  `opacity` và `seed` thì theo `t` được.
- Vị trí tính bằng `sin`/`cos` f32 lệch dưới một pixel giữa các GPU; trên cùng một máy output giống nhau
  từng byte.

## Tham số biểu thức

Tham số `expr` giữ một biểu thức toán, truyền dạng chuỗi như mọi tham số (inline sau tên package trong `graph=` của filter,
`sendcmd`, inline trong `gpufx run`), và được tính trên GPU ở chỗ shader gọi nó, ví dụ mỗi hạt một lần:

```json
{ "name": "path_x", "type": "expr", "vars": ["u", "p", "x0"], "default": "x0 + 0.05*sin(tau*u)" }
```

```wgsl
let x = gpufx_expr_path_x(u, p, x0);   // tham số theo thứ tự `vars`, đều là f32
```

- Chuỗi chỉ được có số (`1`, `0.5`, `2e-3`), các biến đã khai, hằng `pi`, `tau`, `e`, `+ - * /`, `^`
  (lũy thừa), ngoặc và các hàm `sin cos tan asin acos atan atan2 abs sign min max clamp mix step
  smoothstep pow sqrt exp log floor ceil round fract`. Không gì khác: chuỗi được parse thành cây và code
  shader sinh từ cây, không chèn chuỗi thô. Tối đa 1024 byte, 512 số hạng, lồng 32 mức.
- Hàm trả về `f32`. NaN và vô cực (`log(-1)`, `1/0`) được đổi thành **0**, nên shader không bao giờ thấy
  chúng (hạt ở vị trí 0 vẫn có thể nằm trong khung: nên chọn công thức luôn xác định).
- Tên biến là định danh thường: bắt đầu bằng chữ cái, không có `__`.
- Biểu thức mới làm biên dịch lại pipeline của hiệu ứng (vài ms): thỉnh thoảng đổi (`sendcmd`), không
  đổi mỗi frame. Biểu thức được biên dịch ngay lúc đặt, nên chuỗi parse hay biên dịch lỗi báo lỗi tại đó
  (`sendcmd` báo lại) và giữ biểu thức đúng gần nhất; stream vẫn chạy tiếp. Biểu thức mặc định dùng
  pipeline chung của mọi hiệu ứng mở từ gói.
- Trên dòng lệnh FFmpeg, dấu phẩy trong `graph='...'`/`graph='...'` phải escape như mọi option của filter, còn
  các key inline phân tách bằng `&` (không cần escape): `graph='x.zip=angle=max(90*u\,0)&speed=2'`. Dấu `:` kiểu
  FFmpeg cũng được chấp nhận nhưng ở đó phải viết `\:` (`...\,0)\:speed=2`). Trong chuỗi effect, `\&` là `&`
  nguyên văn (tập ký tự escape được: `\ ' : & ; | = [ ]`).

## Tham số enum

Tham số kiểu `enum` nhận một trong các lựa chọn có tên. Trong shader nó là `i32`/`int` giống
`int` (`params.<name>`), giữ số của tên được chọn. `values` liệt kê các tên theo một trong hai dạng:

- mảng tên, đánh số từ 0 theo thứ tự: `"values": ["fade", "wipeleft", "wiperight"]`;
- object gán số cho từng tên (số `i32` bất kỳ, vd để khớp cách đánh số của FFmpeg):
  `"values": {"custom": -1, "fade": 0, "wipeleft": 1}`.

```json
{ "name": "transition", "type": "enum", "values": {"custom": -1, "fade": 0, "wipeleft": 1}, "default": "fade" }
```

Quy tắc: có ít nhất một giá trị; tên gồm chữ, số, `_` hoặc `-`, không phải là số và không trùng nhau;
hai tên không dùng chung một số; `default` (tên hoặc một trong các số) không bắt buộc, thiếu thì lấy
giá trị đầu tiên (phần tử đầu của mảng, số nhỏ nhất của object); không có `min`/`max`.

Mọi chỗ nhận tham số dạng chuỗi (inline `pkg.zip=transition=wipeleft` trong `graph=`, option `params`,
`sendcmd`/`process_command`, chuỗi graph của `gpufx run`, `gpufx_effect_set_param()`) đều nhận tên, và cho
tiện cũng nhận số (`transition=1`). Tên được tra trước; tên lạ báo lỗi kèm danh sách tên hợp lệ
(`unknown value `wipeup` (allowed: custom, fade, wipeleft)`). Trong filter FFmpeg, chuỗi không phải
tên cũng không phải số thì được thử như biểu thức FFmpeg tính lại mỗi frame
(`transition=if(lt(t\,2)\,0\,1)`), giống mọi tham số vô hướng: kết quả được làm tròn và phải là một
trong các số, nếu không thì frame đó lỗi và filter dừng với lỗi. Một số trần không thuộc
danh sách bị từ chối ngay khi đặt option. Số đặt qua `gpufx_effect_set_param_values()`
theo cùng quy tắc. `gpufx info` in các tên kèm số của chúng.

## Ví dụ có sẵn

Các ví dụ nằm trong các thư mục nhóm dưới `packages/gpufx/`: `ffmpeg/` (tương đương filter dựng sẵn và chuyển cảnh `xfade` của FFmpeg), `tqk2811/FFmpegArgs.TanersenerSlideShow/` (viết lại từ [tanersener/ffmpeg-video-slideshow-scripts](https://github.com/tanersener/ffmpeg-video-slideshow-scripts)), `capcut/` (dựng lại chuyển cảnh CapCut), `standalone/` (hiệu ứng tự viết) và nhóm lồng `tqk2811/TqkLibrary.FFmpegTransition/` (port từ [TqkLibrary.FFmpegTransition](https://github.com/tqk2811/TqkLibrary.FFmpegTransition)). Nhóm có thể nằm ở độ sâu bất kỳ: gói là mọi thư mục có `manifest.json`. Xem [packages/gpufx/README.md](../packages/gpufx/README.md). Nhóm chỉ là thư mục: gói vẫn được gọi bằng tên riêng của nó.

| Gói | Minh hoạ |
|-----|----------|
| `packages/gpufx/ffmpeg/vignette` | Tham số `float` + `color` |
| `packages/gpufx/ffmpeg/gaussian-blur` | 2 pass qua texture trung gian `tmp` |
| `packages/gpufx/ffmpeg/wipe-transition` | 2 input (`first`, `second`), tham số `progress` |
| `packages/gpufx/standalone/gradient-map` | Texture PNG đi kèm làm LUT |
| `packages/gpufx/standalone/rgb-split` | GLSL, dùng `globals.frame` làm nhiễu động |
| `packages/gpufx/ffmpeg/color-adjust` | Độ sáng, tương phản, bão hoà, gamma, hue, nhiệt độ màu |
| `packages/gpufx/ffmpeg/grayscale`, `packages/gpufx/ffmpeg/sepia`, `packages/gpufx/ffmpeg/invert` | Lọc màu cơ bản, tham số `amount` |
| `packages/gpufx/ffmpeg/sharpen` | Unsharp mask 3×3 bằng `textureLoad` |
| `packages/gpufx/ffmpeg/edge-detect` | Sobel |
| `packages/gpufx/ffmpeg/pixelate` | Khảm theo khối |
| `packages/gpufx/ffmpeg/mirror` | Lật ngang/dọc, tham số `int` |
| `packages/gpufx/ffmpeg/transform` | Zoom, xoay, pan (Ken Burns), tham số `vec2` |
| `packages/gpufx/ffmpeg/fade` | Fade về một màu |
| `packages/gpufx/ffmpeg/chroma-key` | Phông xanh → alpha; **quy tắc** `formats` input, output `rgba`/`yuva420p`/`yuva444p` |
| `packages/gpufx/ffmpeg/overlay` | Picture-in-picture 2 input, có viền |
| `packages/gpufx/ffmpeg/hstack`, `packages/gpufx/ffmpeg/vstack` | `hstack`/`vstack` của FFmpeg: input `repeat` (bao nhiêu label thì bấy nhiêu input, 2 đến 16) và `size` của output là `hstack`/`vstack`, output lớn hơn input |
| `packages/gpufx/tqk2811/TqkLibrary.FFmpegTransition/crossfade`, `packages/gpufx/ffmpeg/slide-transition`, `packages/gpufx/ffmpeg/circle-reveal` | Chuyển cảnh 2 input; **quy tắc** `same_size` |
| `packages/gpufx/tqk2811/TqkLibrary.FFmpegTransition/clock-wipe` | Chuyển cảnh kim đồng hồ, tham số `bool` `reverse` |
| `packages/gpufx/ffmpeg/blend` | 2 input, tham số `int` `mode` chọn 1 trong 40 công thức |
| `packages/gpufx/ffmpeg/masked-merge` | 3 input (nền, lớp phủ, mask) với **quy tắc** `same_size` |
| `packages/gpufx/ffmpeg/selectivecolor` | Tham số `vec4` |
| `packages/gpufx/ffmpeg/box-blur` | 6 pass; các vòng vượt `power` chép nguyên input sang output |
| `packages/gpufx/ffmpeg/displace` | 3 input, 2 trong số đó làm bản đồ dịch chuyển |
| `packages/gpufx/tqk2811/TqkLibrary.FFmpegTransition/collapse`, `packages/gpufx/tqk2811/TqkLibrary.FFmpegTransition/expand` | Clip đầu thu vào giữa / clip sau nở ra từ giữa: theo chiều ngang, chiều dọc, hộp, hình tròn (`mode`) |
| `packages/gpufx/tqk2811/TqkLibrary.FFmpegTransition/dip-to-color` | Tối dần về một màu (mặc định đen) rồi hiện clip sau |
| `packages/gpufx/ffmpeg/dissolve` | Hạt ngẫu nhiên (hash số nguyên, giống nhau trên mọi GPU) |
| `packages/gpufx/ffmpeg/pixelize-transition`, `packages/gpufx/ffmpeg/zoom-transition`, `packages/gpufx/ffmpeg/fade-grays`, `packages/gpufx/tqk2811/FFmpegArgs.TanersenerSlideShow/blinds` | Chuyển cảnh kiểu `xfade`: vỡ điểm ảnh, zoom, qua ảnh xám, rèm |
| `packages/gpufx/tqk2811/FFmpegArgs.TanersenerSlideShow/checkerboard`, `packages/gpufx/tqk2811/FFmpegArgs.TanersenerSlideShow/push-box`, `packages/gpufx/tqk2811/FFmpegArgs.TanersenerSlideShow/push-film`, `packages/gpufx/tqk2811/FFmpegArgs.TanersenerSlideShow/photo-collection` | Chuyển cảnh slideshow theo [tanersener/ffmpeg-video-slideshow-scripts](https://github.com/tanersener/ffmpeg-video-slideshow-scripts) (viết lại bằng shader): ô vuông lớn dần, hộp thu nhỏ - đẩy - phóng to, cuộn phim có lỗ vẽ bằng shader, ảnh bay vào vừa xoay vừa đáp nghiêng lên clip đầu (nối chuỗi để xếp chồng ảnh) |
| `packages/gpufx/tqk2811/FFmpegArgs.TanersenerSlideShow/box-in`, `packages/gpufx/tqk2811/FFmpegArgs.TanersenerSlideShow/sliding-bars`, `packages/gpufx/tqk2811/FFmpegArgs.TanersenerSlideShow/spin-transition` | Cũng theo các script đó: clip đầu thu nhỏ thành hộp rồi trượt ra, hộp clip sau trượt vào từ cùng phía rồi phóng to (`box_in_*`), các thanh của clip sau lần lượt trượt vào (`stagger`), clip đầu xoay thu nhỏ rồi clip sau xoay phóng to có motion blur (vòng lặp nhiều mẫu theo góc). `slide-transition` có thêm `mode` đẩy / phủ / lộ / đẩy qua khoảng trống màu `color`, `blinds` có `origin` mở từ giữa thanh |
| `packages/gpufx/tqk2811/FFmpegArgs.TanersenerSlideShow/fit` | Các chế độ khung hình của các script đó (giữa, cắt, kéo giãn, nền mờ) cho ảnh kích thước bất kỳ: input đầu chỉ cho kích thước khung; **hai pass**, box blur tách trục với số tap bilinear cố định |
| `packages/gpufx/standalone/falling-maple`, `packages/gpufx/standalone/falling-ginkgo` | Lá phong đỏ / lá rẻ quạt vàng rơi:: atlas 2×2 cắt thành **texture mảng** (`grid`) có **mipmap** và **alpha premultiplied**, mức mip tính cho từng lá, hạt không trạng thái (chỉ phụ thuộc `t`, seek đúng), `var<workgroup>` + `workgroupBarrier`, 4 kiểu chuyển động (`mode`) và quỹ đạo tùy chỉnh (`mode=4`, **tham số `expr`** `path_x`, `path_y`, `angle`). Ảnh gốc và giấy phép ở `assets/leaves/` |
