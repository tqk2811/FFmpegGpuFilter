# Kế hoạch: shader làm việc trên YUV gốc (`space`)

Ghi 2026-10-23. Làm SAU đợt effect nhiều output (`plan-multi-output-effects-vi.md`). Trạng thái: thiết kế, chưa code.

## Mục tiêu

Chain toàn effect YUV chạy không convert RGBA nào:

```
nv12 -> a -> Y,UV -> b -> Y,UV -> c -> nv12
```

Hiện nay shader luôn thấy RGBA: core convert frame -> RGBA ở đầu graph, RGBA -> frame ở cuối, texture trung gian RGBA (rgba8 4 byte/px, rgba16float 8 byte/px so với 1,5 byte/px của 4:2:0). Với chain dài ở 4K, băng thông là phần tốn.

## Cú pháp manifest

`space` trên từng phần tử `inputs[]` và `outputs[]` (đợt nhiều output đã bỏ `formats`). Không ghi = `rgba`.

```json
"inputs":  [ { "name": "src", "space": "yuv420" }, { "name": "bg" } ],
"outputs": [ { "name": "comp", "space": "yuva420" }, { "name": "matte", "space": "y" } ]
```

| `space` | Texture shader thấy | Nhận thẳng (không convert) | Format ra mặc định |
|---|---|---|---|
| `rgba` | 1: RGBA | `rgba`, `bgra`, ... | `rgba` |
| `yuv420` / `yuv422` / `yuv444` | 2: Y, UV | `nv12`, `yuv420p`, `p010`, `yuv420p10le` / `yuv422p*` / `yuv444p*` | `nv12` / `yuv422p` / `yuv444p` |
| `yuva420` / `yuva444` | 3: Y, UV, A | `yuva420p*` / `yuva444p*` | `yuva420p` / `yuva444p` |
| `y` | 1: Y | `gray*` | `gray` |

`space` không phải tên format: các format cùng loại chỉ khác cách xếp plane / bit depth, shader thấy cùng một bộ texture float.

## Hành vi của core

- **Input**: format frame cùng loại với `space` -> nạp plane thẳng; khác loại -> convert sang `space` (vd rgba -> yuv420, yuv444p -> yuv420 giảm chroma).
- **Giữa effect / giữa pass**: cùng `space` -> chuyển texture thẳng; khác -> core chèn convert đúng chỗ đó.
- **Output**: `out_format` nếu có; không thì format của input đầu nếu cùng loại với `space` của output; không thì format mặc định của `space`.
- Matrix/range của frame giữ nguyên khi không convert; khi convert dùng matrix/range của input như convert.rs hiện nay.

## Shader

Prelude sinh binding theo `space`: `in_<name>_y`, `in_<name>_uv`, `in_<name>_a`; ghi bằng `gpufx_write_y/_uv/_a` (output phụ có hậu tố số như `gpufx_write1`). Ví dụ:

```wgsl
let y  = textureLoad(in_src_y,  p,     0).r;
let uv = textureLoad(in_src_uv, p / 2, 0).rg;
gpufx_write_y(p, y2);
if (all(p % 2u == 0u)) { gpufx_write_uv(p / 2u, uv2); }
```

## Điểm đã chốt (2026-10-23, user bảo làm luôn, lấy theo đề xuất)

Quyết định trong mục này ghi đè các chữ "đề xuất" bên dưới.
- (1) Đếm theo số texture sau khi nở `space`.
- (2) Texture trung gian khai ở mảng cấp effect `"intermediates": [{ "name": "tmp", "space": "yuv420" }]`; tên output nội bộ không khai = `rgba`.
- (3) Dispatch theo kích thước Y, thread toạ độ chẵn ghi UV.
- (4) Y/UV/A dùng `r16float`/`rg16float` khi adapter hỗ trợ storage cho chúng (kiểm format features), không thì `r32float`/`rg32float`; nạp/ghi 8 và 10 bit đều qua float.
- (6) Kích thước là của Y, UV làm tròn lên.
- (7) Vulkan + D3D12, thêm D3D11 nếu đường hiện có hỗ trợ; không được thì báo lỗi rõ khi load.

## Điểm cần chốt khi làm

1. **Giới hạn 4 storage texture mỗi pass** tính theo số texture: `yuva420` chiếm 3. Manifest kiểm theo số texture sau khi nở `space`.
2. **Texture trung gian giữa các pass** (vd `tmp` của gaussian blur): khai `space` ở đâu. Đề xuất: output nội bộ của pass khai `"space"` ở cấp pass, mặc định `rgba`.
3. **Dispatch plane UV nửa độ phân giải**: đề xuất dispatch theo kích thước Y, thread toạ độ chẵn ghi UV; hoặc cho dispatch riêng mỗi plane.
4. **Format storage texture**: Y/UV dùng `r8unorm`/`rg8unorm` hay `r16float`/`rg16float` (10 bit cần 16). Kiểm hỗ trợ storage của từng format trên Vulkan/D3D12.
5. **convert.rs**: thêm nạp/ghi plane thẳng và convert giữa các `space` (yuv420 <-> rgba, yuv444 -> yuv420...).
6. **`gpufx_output_size`** với output YUV: kích thước trả về là kích thước Y; UV suy ra theo subsampling; kích thước lẻ với 4:2:0 làm tròn lên như FFmpeg.
7. Backend Vulkan + D3D12 (+ D3D11 nếu đang hỗ trợ).

## Chỗ phải sửa (dự kiến)

- `crates/gpufx-core/src/manifest.rs`: trường `space`, kiểm giới hạn binding theo texture.
- `crates/gpufx-core/src/runtime.rs`: prelude WGSL/GLSL theo `space`, binding nhiều plane.
- `crates/gpufx-core/src/convert.rs` + `convert_*.wgsl`: nạp/ghi plane, convert giữa space.
- `crates/gpufx-core/src/graph.rs`: pool theo (kích thước, space), chèn convert khi space lệch.
- `ffmpeg/vf_gpufx.c`: chọn sw_format ra theo space.
- Tài liệu EFFECT_FORMAT(.md/-vi.md), DESIGN, gói mẫu YUV (vd chroma key trên YUV).

## Test

- Chain 3 effect `yuv420` từ nv12: không có dispatch convert nào (đếm pass), pixel khớp bản RGBA trong sai số.
- Space lệch giữa effect: core chèn đúng một convert.
- Input rgba vào effect `yuv420`; input yuv444p vào `yuv420`.
- Output `y` ra gray, `yuva420` ra yuva420p; `out_format` ghi đè.
- Pass vượt 4 storage texture sau khi nở space -> lỗi manifest.
- Kích thước lẻ với 4:2:0.
