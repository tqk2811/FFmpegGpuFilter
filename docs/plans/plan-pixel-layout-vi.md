# Kế hoạch: shader làm việc trên YUV gốc (`pixel_layout`)

Ghi 2026-10-23. Làm SAU đợt effect nhiều output (`plan-multi-output-effects-vi.md`). Trạng thái: thiết kế, chưa code.

## Mục tiêu

Chain toàn effect YUV chạy không convert RGBA nào:

```
nv12 -> a -> Y,UV -> b -> Y,UV -> c -> nv12
```

Hiện nay shader luôn thấy RGBA: core convert frame -> RGBA ở đầu graph, RGBA -> frame ở cuối, texture trung gian RGBA (rgba8 4 byte/px, rgba16float 8 byte/px so với 1,5 byte/px của 4:2:0). Với chain dài ở 4K, băng thông là phần tốn.

## Cú pháp manifest

`pixel_layout` trên từng phần tử `inputs[]` và `outputs[]` (đợt nhiều output đã bỏ `formats`). Không ghi = `rgba`.

```json
"inputs":  [ { "name": "src", "pixel_layout": "yuv420" }, { "name": "bg" } ],
"outputs": [ { "name": "comp", "pixel_layout": "yuva420" }, { "name": "matte", "pixel_layout": "y" } ]
```

| `pixel_layout` | Texture shader thấy | Nhận thẳng (không convert) | Format ra mặc định |
|---|---|---|---|
| `rgba` | 1: RGBA | `rgba`, `bgra`, ... | `rgba` |
| `yuv420` / `yuv422` / `yuv444` | 2: Y, UV | `nv12`, `yuv420p`, `p010`, `yuv420p10le` / `yuv422p*` / `yuv444p*` | `nv12` / `yuv422p` / `yuv444p` |
| `yuva420` / `yuva444` | 3: Y, UV, A | `yuva420p*` / `yuva444p*` | `yuva420p` / `yuva444p` |
| `y` | 1: Y | `gray*` | `gray` |

`pixel_layout` không phải tên format: các format cùng loại chỉ khác cách xếp plane / bit depth, shader thấy cùng một bộ texture float.

## Hành vi của core

- **Input**: format frame cùng loại với `pixel_layout` -> nạp plane thẳng; khác loại -> convert sang `pixel_layout` (vd rgba -> yuv420, yuv444p -> yuv420 giảm chroma).
- **Giữa effect / giữa pass**: cùng `pixel_layout` -> chuyển texture thẳng; khác -> core chèn convert đúng chỗ đó.
- **Output**: `out_format` nếu có; không thì format của input đầu nếu cùng loại với `pixel_layout` của output; không thì format mặc định của `pixel_layout`.
- Matrix/range của frame giữ nguyên khi không convert; khi convert dùng matrix/range của input như convert.rs hiện nay.

## Shader

Prelude sinh binding theo `pixel_layout`: `in_<name>_y`, `in_<name>_uv`, `in_<name>_a`; ghi bằng `gpufx_write_y/_uv/_a` (output phụ có hậu tố số như `gpufx_write1`). Ví dụ:

```wgsl
let y  = textureLoad(in_src_y,  p,     0).r;
let uv = textureLoad(in_src_uv, p / 2, 0).rg;
gpufx_write_y(p, y2);
if (all(p % 2u == 0u)) { gpufx_write_uv(p / 2u, uv2); }
```

## Điểm đã chốt (2026-10-23, user bảo làm luôn, lấy theo đề xuất)

Quyết định trong mục này ghi đè các chữ "đề xuất" bên dưới.
- (1) Đếm theo số texture sau khi nở `pixel_layout`.
- (2) Texture trung gian khai ở mảng cấp effect `"intermediates": [{ "name": "tmp", "pixel_layout": "yuv420" }]`; tên output nội bộ không khai = `rgba`.
- (3) Dispatch theo kích thước Y, thread toạ độ chẵn ghi UV.
- (4) Y/UV/A dùng `r16float`/`rg16float` khi adapter hỗ trợ storage cho chúng (kiểm format features), không thì `r32float`/`rg32float`; nạp/ghi 8 và 10 bit đều qua float.
- (6) Kích thước là của Y, UV làm tròn lên.
- (7) Vulkan + D3D12, thêm D3D11 nếu đường hiện có hỗ trợ; không được thì báo lỗi rõ khi load.

- (9) Bước A (2026-10-23) chọn thêm: ghi plane bằng `gpufx_write{k}_<plane>(p: vec2u, v)` với `p` là texel của chính plane (đúng ví dụ trên), kèm `gpufx_chroma_scale{k}()`; input/output `rgba` trong pass có plane giữ tên cũ. Plane chỉ cho WGSL, không cho input `mipmaps`/`repeat` và output lặp. Plane 32 bit khai `filterable: false` (chỉ `textureLoad`). Graph từ chối effect có plane tới khi bước B nối convert/pool.
- (8) Bộ convert hiện KHÔNG ghi được `gray` trên GPU (test-bundle 2026-10-23: `out_format=gray is not converted on the GPU`). Layout `y` phải thêm đường ghi gray vào convert, hoặc đổi format ra mặc định của `y`.
- (10) Bước B1 (2026-10-23) chọn thêm: plane giữ mã Y'CbCr lưu trữ chuẩn hoá 0..1 theo thang 8 bit (limited: Y = (16 + 219y)/255, C = (128 + 224c)/255; full: C = c + 128/255), matrix và range lấy từ frame input đầu của graph. Giảm chroma = trung bình các pixel của texel UV, tăng = texel gần nhất. Convert dùng chung cho các bên đọc cùng nguồn cùng layout; nguồn khác layout của effect bị tắt đi qua layout convert thay copy. Input pad cấp cho input có plane không đọc tại chỗ (GPU), output có plane không ghi thẳng frame; output có plane cấp cho input `mipmaps` báo lỗi. B2 phải giữ đúng quy ước mã này khi nạp/ghi plane frame (10 bit: mã / 1023 lệch nhẹ so với thang 8 bit, cần chốt).

## Điểm cần chốt khi làm

1. **Giới hạn 4 storage texture mỗi pass** tính theo số texture: `yuva420` chiếm 3. Manifest kiểm theo số texture sau khi nở `pixel_layout`.
2. **Texture trung gian giữa các pass** (vd `tmp` của gaussian blur): khai `pixel_layout` ở đâu. Đề xuất: output nội bộ của pass khai `"pixel_layout"` ở cấp pass, mặc định `rgba`.
3. **Dispatch plane UV nửa độ phân giải**: đề xuất dispatch theo kích thước Y, thread toạ độ chẵn ghi UV; hoặc cho dispatch riêng mỗi plane.
4. **Format storage texture**: Y/UV dùng `r8unorm`/`rg8unorm` hay `r16float`/`rg16float` (10 bit cần 16). Kiểm hỗ trợ storage của từng format trên Vulkan/D3D12.
5. **convert.rs**: thêm nạp/ghi plane thẳng và convert giữa các `pixel_layout` (yuv420 <-> rgba, yuv444 -> yuv420...).
6. **`gpufx_output_size`** với output YUV: kích thước trả về là kích thước Y; UV suy ra theo subsampling; kích thước lẻ với 4:2:0 làm tròn lên như FFmpeg.
7. Backend Vulkan + D3D12 (+ D3D11 nếu đang hỗ trợ).

## Chỗ phải sửa (dự kiến)

- `crates/gpufx-core/src/manifest.rs`: trường `pixel_layout`, kiểm giới hạn binding theo texture.
- `crates/gpufx-core/src/runtime.rs`: prelude WGSL/GLSL theo `pixel_layout`, binding nhiều plane.
- `crates/gpufx-core/src/convert.rs` + `convert_*.wgsl`: nạp/ghi plane, convert giữa pixel_layout.
- `crates/gpufx-core/src/graph.rs`: pool theo (kích thước, pixel_layout), chèn convert khi pixel_layout lệch.
- `ffmpeg/vf_gpufx.c`: chọn sw_format ra theo pixel_layout.
- 5 gói keying (mất alpha từ khi bỏ `formats`, xem README của chúng): output khai `"pixel_layout": "yuva420"` (input yuv) hoặc `rgba` để lấy lại alpha; bỏ ghi chú `out_format=rgba` trong README. User chốt 2026-10-23.
- Tài liệu EFFECT_FORMAT(.md/-vi.md), docs/architecture/README, gói mẫu YUV (vd chroma key trên YUV).

## Test

- Chain 3 effect `yuv420` từ nv12: không có dispatch convert nào (đếm pass), pixel khớp bản RGBA trong sai số.
- Space lệch giữa effect: core chèn đúng một convert.
- Input rgba vào effect `yuv420`; input yuv444p vào `yuv420`.
- Output `y` ra gray, `yuva420` ra yuva420p; `out_format` ghi đè.
- Pass vượt 4 storage texture sau khi nở pixel_layout -> lỗi manifest.
- Kích thước lẻ với 4:2:0.
