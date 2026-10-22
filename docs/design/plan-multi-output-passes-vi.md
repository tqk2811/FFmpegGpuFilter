# Kế hoạch: pass ghi nhiều output (`output` dạng mảng)

Ngày ghi: 2026-10-22. Branch làm việc: tạo mới từ `master`, ví dụ `feat/multi-output-passes`.

## Mục tiêu

Một pass trong `manifest.json` ghi được nhiều texture trong cùng một dispatch:

```json
{ "shader": "split.wgsl", "inputs": ["src"], "output": ["base", "detail"] }
```

Các pass sau đọc `base` và `detail` qua `inputs` như output bình thường. Bỏ trống `output` vẫn là `["out"]`; dạng chuỗi `"output": "tmp"` bị từ chối.

## Quyết định đã chốt

1. **Cú pháp**: `output` CHỈ nhận mảng chuỗi; dạng chuỗi bị bỏ, không giữ tương thích bản cũ (mọi manifest/test/tài liệu đổi `"output": "x"` thành `["x"]`). Không thêm trường mới `outputs`. Mảng có từ 1 đến 4 phần tử (4 là mức tối thiểu WebGPU bảo đảm cho `maxStorageTexturesPerShaderStage`). Bỏ trống thì vẫn là `["out"]`.
2. **Output chính** là phần tử đầu `output[0]`:
   - Vẫn ở binding 2, vẫn tên `out_tex`, `gpufx_write` vẫn ghi vào nó. Shader cũ không phải sửa gì.
   - Output cuối của effect là `output[0]` của pass cuối (thay cho `output` của pass cuối như hiện nay).
3. **Output phụ** `output[k]` (k = 1..3):
   - Binding `FIRST_TEXTURE_BINDING + số input của pass + (k - 1)`, tức nằm SAU các texture input. Binding của input giữ nguyên, nên các shader cũ không bị dời binding.
   - Tên biến trong shader là `out_tex1`, `out_tex2`, `out_tex3`, có hàm `gpufx_write1(id, c)`... với cùng cách clamp như `gpufx_write`. GLSL làm tương tự, dùng `image2D` writeonly.
   - Format giống `out_tex` (`rgba8unorm`, hoặc `rgba16float` khi `deep`). Kích thước giống output chính (kích thước effect).
4. **Kiểm tra manifest**, mở rộng các luật hiện có cho mọi phần tử của mảng:
   - Mỗi tên phải là identifier, không được trùng với input hay texture, và pass không được đọc output của chính nó.
   - Thêm luật mới: các tên trong cùng một mảng không được trùng nhau, và mảng không được rỗng hoặc dài quá 4.
   - Thêm luật mới: **pass cuối chỉ được có một output**. Output phụ của pass cuối không ai đọc được, nên báo lỗi rõ thay vì lặng lẽ cấp texture.
   - Thêm `out_tex1`..`out_tex3` vào danh sách tên dành riêng (cạnh `globals`, `params`, `out_tex`, `smp`).
5. **`GPUFX_API_VERSION` giữ nguyên 1**: đang pre-release nên không bump. Không ràng buộc mảng theo `api`.

## Các chỗ phải sửa (đều trong `D:\IT\Github\tqk2811\FFmpegGpuFilter\crates\gpufx-core\src`)

### manifest.rs
- `PassDef.output` ở dòng 378-380 và `default_output` ở dòng 410-411: đổi thành `outputs: Vec<String>`. Dùng một hàm `deserialize_with` riêng (hoặc enum `#[serde(untagged)]` cho chuỗi/mảng), giữ tên khoá JSON là `output` qua `#[serde(rename = "output")]`. Để tiện cho các chỗ gọi, thêm hàm `fn output(&self) -> &str { &self.outputs[0] }`.
- Phần kiểm tra ở dòng 636-647: lặp qua từng tên trong `outputs`, rồi thêm các luật mới ở mục 4.
- Tìm danh sách tên dành riêng (grep `"out_tex"` trong crate) và thêm `out_tex1..3`.
- Test trong `mod tests` của file: viết bài cho dạng chuỗi, dạng mảng, mảng rỗng, mảng dài 5, trùng tên trong mảng, pass cuối có 2 output, và đọc output phụ từ pass sau.

### runtime.rs
- `struct Pass` (gần dòng 369): `output: String` đổi thành `outputs: Vec<String>`. Gán ở dòng 968.
- `prelude` (dòng 788 trở đi) và `glsl_with_prelude` (dòng 826-840): nhận thêm số output phụ (hoặc `n_inputs` và `n_outputs`), sinh khai báo `out_tex{k}` và `gpufx_write{k}` với binding như mục 3.
- `compile_pass` (dòng 917-948): thêm `BindGroupLayoutEntry` StorageTexture WriteOnly cho từng output phụ. Format lấy theo `deep` như binding 2.
- `make_bound` (dòng 722-741): thêm `BindGroupEntry` cho từng output phụ, view lấy bằng `level0(&outputs[name])`.
- `rebind` (dòng 755) và `output()` (dòng 770): đổi thành `passes.last().output()`, tức `output[0]`.
- Grep `outputs.insert` và các nơi khác trong file tạo `HashMap<String, wgpu::Texture>` cho pass outputs, rồi bảo đảm mọi output phụ đều được cấp texture.

### graph.rs
- Dòng 286-287 (xét ghi thẳng vào frame): `p.output == last.output` đổi thành `p.outputs.contains(last.output())`, và `p.inputs.contains(&last.output)` đổi thành `last.output()`.
- `plan` ở dòng 307-376:
  - `finals` lấy `output()`.
  - Dòng 329: `find(|p| p.outputs.contains(name))`.
  - Dòng 338: `bump` cho MỌI output của pass.
  - Dòng 362-372: cấp slot cho MỌI output chưa có trong `assign[k]`. Biến `in_place` và cờ mip chỉ áp cho tên bằng `finals[k]`.
  - Lưu ý: output phụ không ai đọc vẫn phải có `last` để `live.push` không panic (đã được `bump` ở dòng 338 sửa lại).
- Dòng 644: đổi `.output` thành `.output()`.

### Chỗ khác
- Chạy `cargo build --workspace` để compiler chỉ ra những chỗ còn dùng `pass.output`. Grep đã thấy `crates/gpufx-core/tests/graph.rs`. Trong `gpufx-nnconv` và `nn/` cũng có trường `output`, nhưng là của op NN, KHÔNG liên quan nên đừng đụng.

## Test bắt buộc
- Thêm vào `crates/gpufx-core/tests/graph.rs` (mẫu ở dòng 442) một effect hai pass:
  - pass 1 ghi `["a", "b"]`, trong đó `a` dùng một màu hằng và `b` một màu khác, ghi bằng `gpufx_write` và `gpufx_write1`;
  - pass 2 đọc `["a", "b"]` rồi cộng lại hoặc ghép nửa trái/phải.
  - Kiểm pixel đầu ra, chạy cả WGSL lẫn GLSL nếu các test hiện có cũng làm vậy.
- Thêm một bài kiểm pool: output phụ không bị pool cấp trùng slot với texture còn đang được đọc.
- Toàn bộ bộ test cũ phải xanh (manifest cũ không đổi hành vi).

## Tài liệu
- `docs/EFFECT_FORMAT.md` và `docs/EFFECT_FORMAT-vi.md`:
  - Phần mô tả `output` của pass: sửa cho nói được dạng mảng.
  - Bảng binding ở dòng 355: thêm hàng cho các binding `out_tex1..3`.
  - Dòng 148: thêm các tên dành riêng mới.
  - Thêm một ví dụ JSON ngắn và một ví dụ WGSL.
- Sửa cả hai bản ngôn ngữ cho khớp.

## Luật cho agent thực hiện
- Line ending: giữ CRLF/LF đúng như từng file đang có. Trước commit so `git diff --stat` với `git diff --stat --ignore-cr-at-eol`, hai kết quả phải khớp.
- Trước commit chạy `cargo fmt --all` và `cargo clippy --workspace --all-targets -- -D warnings` (CI fail ở bước fmt).
- Ghi log test đầy đủ ra file rồi mới lọc, không chạy chế độ quiet.
- Đây là thay đổi hợp đồng manifest trải nhiều file, nên cần một lượt review độc lập trước khi commit.
