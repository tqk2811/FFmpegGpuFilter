# Kế hoạch: effect có nhiều output (nhiều output pad của filter `gpufx`)

Ngày ghi: 2026-10-22. Xây trên nền [plan-multi-output-passes-vi.md](plan-multi-output-passes-vi.md) (pass ghi nhiều texture, `passes[i].output` là mảng). Branch đề xuất: tạo từ `feat/multi-output-passes` sau khi phần đó đã commit, ví dụ `feat/multi-output-effects`.

> Ghi chú (sau khi làm xong): trường `formats` đã bị bỏ khỏi `inputs`/`outputs` của manifest; shader luôn thấy RGBA, `sw_format` của output mặc định theo input nguồn và `out_format` ghi đè. Các đoạn dưới nói về `formats` là bản kế hoạch cũ.

Số dòng dưới đây đo trên working tree ngày 2026-10-22 (đang có sửa đổi của plan multi-output-passes), nên có thể lệch vài dòng; grep theo tên hàm trước khi sửa.

## Mục tiêu

- Một effect khai báo nhiều output trong manifest, ví dụ `color` và `matte`. Filter `gpufx` lộ ra một output pad cho mỗi output, mỗi pad là một stream riêng.
- Trong graph (`gpufx=graph=...`) mỗi node effect ghi được nhiều label, các label đó đi tiếp vào effect khác hoặc thành output của graph.
- Mỗi output có format, kích thước riêng theo luật trong manifest.
- Không giữ tương thích manifest cũ: chuyển toàn bộ package trong `packages/gpufx`. `GPUFX_API_VERSION` giữ nguyên 1.

## Hiện trạng (đã khảo sát)

- **Phía C đã hỗ trợ nhiều output pad**, nhưng chỉ cho GRAPH có nhiều label ra, mỗi pad ứng với một node:
  - `ffmpeg/vf_gpufx.c:527-543` tạo pad theo `gpufx_effect_output_count()` / `gpufx_effect_output_name()`. `ff_framesync_init` gọi khi mới có một pad (framesync assert một output).
  - `query_formats` (`vf_gpufx.c:2248-2310`) lặp mọi output, `config_output` (`vf_gpufx.c:2470-2512`) lấy kích thước bằng `gpufx_effect_output_size(fx, k, ...)`, `time_base = fs.time_base`, frame rate/SAR theo input nguồn `s->source[k]`.
  - `activate` (`vf_gpufx.c:2516-2545`) bù cho framesync: request input khi bất kỳ output nào cần frame, output 0 EOF thì đóng mọi output khác cùng pts. Hàm đẩy frame (`vf_gpufx.c:2177-2230`) gửi cùng pts cho mọi output, output đã đóng thì bỏ frame.
  - Các đường GPU (`vf_gpufx.c:1013-1060`, `1339-1420`) đã truyền mảng `outs` + `nb_outputs` xuống FFI.
- **FFI** (`crates/gpufx-ffi/src/lib.rs`): `outputs`/`output_formats` lấy từ `graph.output_names()`/`graph.output_formats(k)` (dòng 350-351), `gpufx_effect_output_count/name/size/pad_format*` (dòng 513-565), các hàm process nhận `outs, nb_outputs`. Hàm single-output từ chối graph nhiều output (dòng 799-804).
- **Core**: `Source::Node(usize)` (`graph.rs:18-22`) chỉ trỏ tới "output của effect j" – mỗi effect đúng một output là `passes.last().output()`. `Topology.outputs: Vec<Source>` (`graph.rs:45`). Một effect đơn là `Topology::single` (`graph.rs:49-57`), chain là `linear` (`graph.rs:1480-1491`, tên pad `default`). Parser graph bắt node effect ghi đúng một label (`graph.rs:1364-1366`).
- **Kết luận**: phần FFmpeg gần như đủ; việc chính là ở core: cho `Source` mang chỉ số output của node, rồi mọi chỗ đang giả định "một effect = một texture ra" (plan/pool, direct output, bypass copy, negotiate format, size) đổi sang theo từng output.

## Cú pháp manifest

`output` cấp effect đổi thành MẢNG giống `inputs`. Bỏ trống thì là `[{"name": "out"}]`.

```json
{
  "inputs": [{ "name": "src", "formats": ["rgba"] }],
  "outputs": [
    { "name": "color", "formats": ["rgba", "nv12"] },
    { "name": "matte", "formats": ["gray", "rgba"] }
  ],
  "groups": [{ "passes": [
    { "shader": "key.wgsl", "inputs": ["src"], "outputs": ["color", "matte"] }
  ]}]
}
```

Mỗi phần tử:

| Trường | Bắt buộc | Ý nghĩa |
|---|---|---|
| `name` | có | identifier; đồng thời là tên texture output của một pass (xem quyết định 2) và là tên output pad |
| `formats` | không | như `output.formats` hiện nay, mặc định `default_output_formats()` |
| ~~`size`~~ | | đã bỏ: kích thước output đến từ hàm shader `gpufx_output_size` của pass ghi output đó (xem mục 11b) |
| `bypass` | không | tên input mà output này truyền thẳng khi effect bị tắt; mặc định input đầu (xem quyết định 6) |

## Quyết định thiết kế (đề xuất)

1. **`output` chỉ nhận mảng**, 1..4 phần tử (khớp giới hạn storage texture của pass cuối cùng; xem câu hỏi Q3). Dạng object cũ bị từ chối với thông báo rõ ("`output` is an array: `[{\"name\":\"out\", ...}]`").
2. **Output effect = texture pass có cùng tên.** `output[k].name` phải là output của ĐÚNG MỘT pass trong MỖI group (mọi group phải sinh đủ các output). Không bắt buộc là pass cuối: một output có thể lấy từ pass giữa (vd matte tính sớm). Do đó **bỏ luật "pass cuối chỉ có một output"** của plan multi-output-passes, thay bằng: mọi output phụ của mọi pass phải được pass sau đọc HOẶC là output của effect (không thì lỗi "written but never used").
   - Mặc định `[{"name":"out"}]` + pass bỏ trống `output` = `["out"]` giữ nguyên hành vi effect một output hiện nay.
   - Trường hợp cũ `passes.last().output()` là output effect: sau đổi thì manifest cũ có pass cuối tên khác `out` (vd `"outputs": ["tmp"]` ở pass cuối) phải được chuyển, HOẶC giữ quy ước: nếu `output` effect bị bỏ trống thì tên mặc định là `output[0]` của pass cuối. Đề xuất cách sau (ít phải sửa package, xem Q1).
3. **Tên output pad**:
   - Effect đơn có 1 output: pad vẫn tên `default` (giữ lệnh FFmpeg cũ, `[out]` của filtergraph không đổi).
   - Effect đơn có nhiều output: pad tên đúng `output[k].name` (`color`, `matte`), thứ tự như manifest.
   - Chain (`gpufx=effect=a.zip,b.zip` – `linear`): chỉ effect CUỐI được nhiều output; effect giữa nối output 0 sang effect sau, effect giữa có >1 output thì báo lỗi "use graph=". Pad của chain: như effect đơn, theo effect cuối.
4. **Graph**: node effect ghi đúng số label bằng số output của effect, theo thứ tự manifest: `[0]key.zip[c][m]`. Ghi ít hơn là lỗi (bắt buộc đặt tên hết, output không cần thì nối sang `nullsink` phía FFmpeg — xem Q2). Label của output phụ dùng được như label thường (vào effect khác, `split`, hoặc thành output graph).
5. **Kích thước và format theo từng output**: kích thước của mỗi output đến từ hàm `gpufx_output_size(out_index)` tuỳ chọn trong shader của pass ghi output đó (không có thì bằng input đầu; không còn trường `size` trong manifest). Mọi texture của một pass có cùng kích thước, nên các output một pass ghi phải cùng kích thước (validate). Format negotiate riêng cho từng output (`formats` riêng), conversion GPU (rgba→nv12/gray...) theo slot output như hiện nay. Xem Q4.
6. **Bypass**: khi effect bị tắt (`<node>.bypass`/`enable`) hoặc cả graph bypass, output k sao chép input `output[k].bypass` (mặc định input 0). Mọi output của một effect tắt cùng lúc. Kích thước output khi bypass = kích thước input đó; nếu khác kích thước output thì lỗi như `check_bypass_pad` hiện nay.
7. **Timestamp/EOF**: mọi output của một lần process có cùng pts/duration (đã đúng ở `vf_gpufx.c:2177-2230`). EOF: giữ cơ chế hiện có (output 0 quyết định; output khác đóng thì frame của nó bị bỏ, filter vẫn chạy). Không thêm gì mới về phía C ngoài việc pad giờ có thể đến từ một effect đơn.
8. **API C**: không thêm hàm. `gpufx_effect_output_count/name/size/pad_format*` đã theo chỉ số output; chỉ đổi nguồn dữ liệu trong core. Hàm process single-output (`gpufx_effect_process` cũ) từ chối effect >1 output như đang từ chối graph.
9. **Output `repeat` (số output linh động, user đã chốt làm 2026-10-22)**: giống input `repeat`.
   - Phần tử có `"repeat": { "default": 2, "min": 1, "max": 4 }` phải đứng CUỐI mảng `output`, nở thành `<name>0`..`<name>{N-1}` (vd `part0`, `part1`). Tổng số output effect sau khi nở vẫn ≤ 4.
   - N = số label node ghi trong graph (`[0]split.zip[a][b][c]` → 3); không có label (effect đơn, chain) thì N = `default`, hoặc option `outputs=N` của node (xem Q7a). N chốt lúc dựng graph (số pad FFmpeg chốt lúc init), không phải param shader, không đổi khi đang chạy. Package biên dịch riêng cho từng N như input `repeat`; `gpufx pack --precompile` chỉ biên dịch `default`.
   - Trong `passes[i].output`, tên `"part"` đại diện cả N texture (nở tại chỗ, theo thứ tự); pass sau đọc từng cái bằng `part0`, `part1`... hoặc đọc `"part"` = mọi pad (như input `repeat`). Mọi output `repeat` phải do CÙNG một pass ghi.
   - Prelude của pass ghi output `repeat` sinh thêm `fn gpufx_output_count() -> u32` và `fn gpufx_write_at(i: u32, id: vec3u, c: vec4f)` (switch theo `out_tex`, `out_tex1`...; `i` ngoài khoảng thì bỏ qua). WGSL trước; GLSL như input `repeat` (hiện chỉ WGSL thì giữ chỉ WGSL).
   - Tên pad: `part0`..`part{N-1}`. Bypass: mọi pad nở chép cùng input `bypass`.
   - Chỗ sửa thêm: manifest.rs (`OutputDef.repeat: Option<RepeatRule>`, dùng lại `RepeatRule` dòng ~93, validate, hàm nở `with_output_count(n)` tương tự cách input `repeat` được nở), runtime.rs (prelude + nở tên trong `compile_pass`), graph.rs (parser: số label → N; kiểm `min..max`), tests (N = 1, 2, 4; N ngoài khoảng; label thiếu/thừa; shader dùng `gpufx_write_at`), EFFECT_FORMAT mục "Variable number of outputs".

## Câu hỏi mở cho user

- **Q1**: Khi manifest bỏ trống `output` cấp effect: tên mặc định là `"out"` cố định (phải đổi các package có pass cuối ghi tên khác), hay là `output[0]` của pass cuối (không phải sửa package)? Đề xuất: lấy theo pass cuối. **Chốt (2026-10-22): B, lấy `output[0]` của pass cuối.**
- **Q2**: Graph có cho phép node chỉ ghi một phần label (output thừa bị bỏ, không chạy pass chỉ phục vụ nó) không? Đề xuất v1: bắt buộc ghi đủ; output effect đơn thì FFmpeg bắt buộc nối mọi pad nên user tự `nullsink`. **Chốt (2026-10-22): B, cho ghi thiếu label giống filtergraph của FFmpeg (label gán cho output theo thứ tự; cách xử lý output không có label: xem mục 4 cần cập nhật khi làm).**
- **Q3**: Giới hạn số output effect: 4 (bằng giới hạn output một pass) hay cao hơn (output có thể đến từ nhiều pass khác nhau)? Đề xuất: 4. **Chốt (2026-10-22): 4.**
- **Q4**: Có cần output có kích thước khác nhau ngay v1 (vd matte nửa độ phân giải)? Việc này buộc texture pass có kích thước riêng (đụng runtime/pool sâu). Đề xuất: hoãn, v1 cùng size. **Chốt (2026-10-22): B, mỗi output có kích thước riêng ngay từ v1 (texture pass có kích thước riêng; phải sửa quyết định 5, runtime, pool, globals.size theo pass).**
- **Q5**: Pad của effect đơn 1 output giữ tên `default` hay đổi sang `name` (`out`)? Đề xuất giữ `default`. **Chốt (2026-10-22): A, giữ `default` (tên pad chỉ hiện trong log/thông báo lỗi và API đọc tên; filtergraph nối theo vị trí).**
- **Q6**: `out_format` của `vf_gpufx.c` đang áp cho MỌI pad (matte `gray` sẽ vướng). **User đã chốt (2026-10-22)**:
  - Manifest: mỗi phần tử `output` có `formats` riêng; phần tử `repeat` có một `formats` dùng chung cho mọi pad nở ra từ nó. Không ghi `out_format` thì `vf_gpufx.c` chọn `sw_format` mỗi pad như hiện nay (format input nguồn nếu có trong `formats`, không thì format đầu tiên), nên thứ tự `formats` là mặc định của pad. LƯU Ý: pad `gpufx` ra frame GPU, `sw_format` do gpufx chọn, KHÔNG negotiate với filter phía sau.
  - `out_format` của filter nhận nhiều mục phân cách bằng `|`, theo thứ tự output pad: `out_format=yuva420p|gray`. Một mục thì áp cho mọi pad (lệnh cũ giữ nguyên). Mục rỗng (`out_format=|gray`) = để mặc định. Với `repeat`, mỗi mục ứng một pad nở ra. Mỗi mục chỉ ghi đè trong `formats` của output đó (ngoài danh sách → lỗi như hiện nay).
  - Chỗ sửa: chỉ `ffmpeg/vf_gpufx.c` — option dòng ~2562 đổi `AV_OPT_TYPE_PIXEL_FMT` → `AV_OPT_TYPE_STRING`, parse sau khi biết `nb_outputs` (dòng ~527) thành mảng `out_formats[k]` (field dòng ~137); thay `s->out_format` bằng `s->out_formats[k]` ở các dòng ~554-570, 953, 967, 991, 1228, 1240, 1297, 1978. Lỗi mới: tên format sai (`unknown pixel format 'x'`), số mục khác 1 và khác `nb_outputs`. Tài liệu `docs/design/filters/gpufx.md` + `-vi`. Test thật trong `test-bundle.sh`: `out_format=rgba|gray` và hai ca lỗi.
- **Q7a**: Output `repeat` của effect đơn/chain (không có label): ngoài `default`, có thêm option `outputs=N` cho node không? Đề xuất: có. **Chốt (2026-10-22): B, có option `outputs=N`.**
- **Q7b**: Có cần output tuỳ chọn (bật/tắt một output tên cố định bằng cờ lúc dựng graph)? Đề xuất: chưa làm, `repeat` với `min: 1` che phần lớn trường hợp. **Chốt (2026-10-22): B, làm output bật/tắt bằng cờ.**

## Quyết định cuối (2026-10-22) — GHI ĐÈ các mục trên nếu mâu thuẫn

User đã chốt hết câu hỏi. Agent thực hiện theo mục này trước, rồi mới tới "Các chỗ phải sửa" (phần dưới viết trước khi chốt, phải chỉnh theo đây).

1. **Q1 = B**: bỏ trống `output` cấp effect ⇒ một output, tên = `output[0]` của pass cuối.
2. **Q3 = 4**: tối đa 4 output mỗi effect (sau khi nở `repeat`).
3. **Q4 = B — mỗi output có kích thước riêng ngay từ v1** (thay quyết định 5 "cùng size"):
   - Mỗi output có kích thước riêng, có thể khác nhau, lấy từ `gpufx_output_size` của pass ghi nó (không còn trường `size` trong manifest).
   - Texture của một pass có kích thước riêng = kích thước output effect mà pass đó ghi (pass ghi texture trung gian: kích thước effect mặc định = `output[0]`; cần quy ước rõ, đề xuất: pass không ghi output effect nào thì theo `output[0]`). Các texture cùng một pass phải cùng kích thước (một dispatch) ⇒ validate.
   - `globals.size`, `gpufx_uv`, `gpufx_in_bounds`, kích thước dispatch theo PASS. Pool cấp slot theo kích thước từng texture. Bypass kiểm kích thước theo từng output. Ghi rõ trong EFFECT_FORMAT rằng `globals.size` là kích thước pass đang chạy.
   - Đây là phần nặng nhất: nằm trong commit 2, review `opus`.
4. **Q5 = A**: effect (đơn/chain) một output ⇒ pad tên `default`; nhiều output ⇒ pad tên theo `name`.
5. **Q2 = B — gán label giống filtergraph FFmpeg**, bộ luật:
   1. Label sau một effect gán cho output theo thứ tự từ output 0.
   2. Trong chain (`|`), output đầu tiên CHƯA có label đi vào effect kế tiếp (như `split[a],scale` của FFmpeg).
   3. Output còn lại không label, không được nối ⇒ BỎ: không cấp texture, không chạy pass chỉ phục vụ nó (khác FFmpeg — FFmpeg báo lỗi hoặc tự map; ghi rõ "khác FFmpeg" trong tài liệu). Cơ chế bỏ output dùng chung với Q7b.
   4. **Gán theo tên `[name=label]`** (gpufx có, FFmpeg không): `[0]key.zip[matte=m]|blur.zip[out]`. **Một node chỉ dùng MỘT kiểu** (user chốt 2026-10-22): hoặc mọi label theo vị trí `[a][b]`, hoặc mọi label theo tên `[matte=m][color=c]`; trộn `[matte=m][abc]` là lỗi ("`key.zip`: use either positional labels or `[name=label]`, not both"). Lỗi khác: tên không có trong manifest (liệt kê các output), gán một output hai lần. Kiểu theo tên: output không được gán tên thì xử lý như output không label (luật 2: output đầu tiên chưa gán đi vào effect kế tiếp trong chain; luật 3: còn lại bị bỏ). Output `repeat`: `[part1=x]` gán đúng pad, `[part=x]` lỗi, không làm tăng N (`[part5=x]` với N=2 lỗi). Không làm cho phía input. `=` trong `[...]` hiện không hợp lệ (graph.rs `parse_labels` ~1117-1136) nên không phá cú pháp cũ.
   - Hệ quả: effect giữa chain có >1 output KHÔNG còn là lỗi (bỏ luật "chỉ effect cuối được nhiều output" ở quyết định 3).
6. **Q6**: như mục Q6 ở trên (formats theo từng phần tử `output`, `repeat` chung; `out_format` nhiều mục `|`).
7. **Q7a = B**: option `outputs=N` cho node có output `repeat` (không phải param shader; tên dành riêng, không được trùng param của package).
8. **Q7b = B — output bật/tắt bằng cờ**: phần tử `output` có `"optional": true`; bật/tắt lúc dựng graph bằng option node (đề xuất `outputs.<name>=0|1` hoặc `<name>=off` — chốt tên khi làm, tránh trùng param); output tắt dùng cơ chế bỏ của Q2 luật 3. Mặc định bật. Output không optional không tắt được.
9. **Gán input theo tên** (đối xứng phía output, đang chờ user chốt kiểu A): `[src=0][mask=m]abc.zip`, vế trái là tên input trong manifest, vế phải là label (`[N]` = input pad N của filter `gpufx`, chỉ đứng vế phải). Mỗi node một kiểu ở phía input (vị trí hoặc tên), chọn độc lập với phía output. Lỗi: tên không có, gán hai lần, THIẾU input (input không bỏ được). Input `repeat`: `[src0=a][src1=b]`, N = số pad gán, phải liền từ 0. Trong chain, effect sau nhận output trước vào input đầu tiên chưa gán; label input chỉ đứng đầu câu nên kiểu theo tên phía input chỉ dùng cho effect đầu câu. Mỗi `[N]` vẫn chỉ đọc một lần (`split` nếu cần).
10. **Ví dụ phải có test** (graph): lỗi `[0]key.zip[matte=m][color=c]|def.zip[out]` (chain không còn output chưa gán) và `|[c]ghi.zip` (label giữa chain); đúng: `[0]key.zip[matte=m]|def.zip[out]; [m]ghi.zip[out2]`, `[0]key.zip[matte=m][color=c]; [c]def.zip[out]; [m]ghi.zip[out2]`, `[0]key.zip[c][m]; [c]def.zip[out]; [m]ghi.zip[out2]`; lỗi trộn kiểu `[0][bg=1]x.zip[c]`, `[src=0][bg=1]x.zip[matte=m][x]`.
11. **Đã chốt (2026-10-23, user bảo làm luôn, lấy theo đề xuất)**: (a) kiểu A `[tên=label]` ở cả hai phía; (b) trường `size` của output (`first`/`hstack`/`vstack`) đã bị BỎ; kích thước output đến từ hàm shader tuỳ chọn `gpufx_output_size(out_index)` (WGSL `-> vec2u`, GLSL `uvec2 ...(uint)`) trong shader của pass ghi output đó, chỉ được đọc `params`, `gpufx_input_count()` và `gpufx_input_size(i)`; không có hàm thì bằng input đầu. Kích thước tính một lần bằng một dispatch GPU lúc configure (từ giá trị param lúc đó: mặc định và giá trị inline hằng của graph; biểu thức theo frame không được tính, param giữ mặc định); 0 hoặc quá cạnh texture lớn nhất của thiết bị là lỗi; đổi param làm kích thước đổi giữa chừng thì xử lý báo lỗi lệch kích thước. Nhờ vậy matte thu nhỏ hay scale làm được bằng shader, không cần `half`/`scale` trong manifest; (c) tắt output optional bằng option `<tên output>=off` (mặc định `on`; tên output đã không trùng param). Giới hạn 4 output tính SAU khi nở `repeat` và sau khi tắt output optional.

## Các chỗ phải sửa

### crates/gpufx-core/src/manifest.rs
- Dòng 30-32: `pub output: OutputDef` → `pub outputs: Vec<OutputDef>` với `#[serde(rename = "output", default = "default_outputs")]`; deserialize từ chối object (serde mặc định đã báo "expected a sequence", bọc lại thông báo rõ nếu cần).
- Dòng 171-186 `OutputDef`: thêm `pub name: String` (bắt buộc, hoặc rỗng = suy ra theo Q1), `#[serde(default)] pub bypass: Option<String>`. Bỏ `impl Default` hoặc giữ cho `default_outputs()`.
- Validate (dòng 571-577 và khối kiểm pass ~636-660):
  - Mảng 1..=4; tên là identifier, không trùng nhau, không trùng input/texture/param/tên dành riêng.
  - Mỗi tên là output của đúng một pass trong mỗi group (dùng `group.passes`, chạy cho mọi group).
  - Các output một pass ghi phải cùng kích thước (quyết định 5).
  - `bypass` phải là tên input.
  - Bỏ luật "pass cuối chỉ một output" (do plan trước thêm), thay bằng luật output không ai dùng.
- Dòng 732 (`match self.output.size`) và 796-810 (`output_size`, `check_output_format`): nhận chỉ số output `k`; thêm helper `fn output_size(&self, k, sizes)` và `fn output_names()`.
- `mod tests` (~880-950): sửa các bài dùng `"outputs":{...}` (dòng 884, 932) sang mảng; thêm bài: hai output, tên không phải output pass nào, trùng tên, size khác nhau, `bypass` sai tên, dạng object bị từ chối, output lấy từ pass giữa.

### crates/gpufx-core/src/runtime.rs
- `Program`/`Effect`: thêm `fn output_textures(&self) -> &[String]` (tên texture của từng output effect) và đổi `output()` (dòng ~782) thành `output(k)`; `rebind(inputs, output: Option<&Texture>)` (dòng 765) thành nhận `&[Option<&Texture>]` cho từng output (direct-output theo từng output).
- `process`/`process_frames` (dòng 671-690, API Rust một output): giữ, báo lỗi nếu effect >1 output; thêm biến thể nhận `Vec<ImageMut>` hoặc chuyển người dùng sang `EffectGraph` (đề xuất: chỉ qua graph, như FFI đang làm).
- Chỗ cấp `HashMap<String, wgpu::Texture>` cho pass output: texture là output effect phải được giữ tới khi graph đọc ra (không bị coi là tạm).

### crates/gpufx-core/src/graph.rs
- `Source` (dòng 18-22): `Node(usize)` → `Node(usize, usize)` (effect, output). Compiler chỉ ra mọi chỗ match; các chỗ cần nghĩ kỹ:
  - `Topology::single` (49-57): `outputs = (0..n_out).map(|o| Source::Node(0, o))`.
  - `pad_of`/`bypass_pad` (61-80): theo `output[o].bypass` của node.
  - `direct_outputs` (~270-295): tính cho từng `(k, o)`; điều kiện "không ai khác đọc" đổi sang `Source::Node(k, o)`; pass ghi texture đó phải là pass ghi nó lần duy nhất và không ai đọc lại trong effect (logic hiện có, áp cho `output_textures[o]` thay vì `last.outputs[0]`). Pass ghi output trực tiếp KHÔNG nhất thiết là pass cuối.
  - `plan` (~300-380): `finals: Vec<&str>` → `Vec<Vec<&str>>` (mỗi effect, mỗi output). `bump(&mut last, (j, finals[j]), ...)` đổi sang `(j, finals[j][o])` lấy `o` từ `Source::Node(j, o)`. Vòng `for src in &topo.outputs` (~344) giữ sống đúng texture `(j, finals[j][o])`. Bypass copy (comment dòng 320): copy viết MỌI output của effect tắt ⇒ giữ input sống tới hết effect cho mọi output.
  - `node_size`/`node_sizes`/`source_size` (409-440): v1 cùng size nên giữ một size mỗi node; `source_size(Node(j, _))` trả `sizes[j]`.
  - Kiểm frame/size (~490-520) và `stacked` (dòng 494): đọc `outputs[*].size`.
  - Bind/encode (~640-660, 740-845): `source_texture(effects, inputs, Source::Node(j, o))` lấy `effects[j].output(o)`; bypass copy (dòng ~832 `encode_copy`) lặp mọi output của effect, mỗi output copy từ input bypass của nó.
  - `run_gpu` (847+) tương tự `run`.
- Parser graph:
  - Dòng 1364-1366: `outs != 1` → `outs != fx.output_count()`, thông báo "`key` writes 2 labels (color, matte), got 1".
  - `resolve` (1404-1416) và `producers`: label → `(node, output index)`; `producers: HashMap<&str, (usize, usize)>`, `NodeKind::Effects(ks)` trả `Source::Node(last, o)`.
  - `nodes.push((spec.outputs[0]...))` (1426): tên node dùng label đầu (giữ cho `find_param` `node.name`); cho phép cả label phụ làm tên node (nên có).
  - Kahn (1440-1455): `matches!(*s, Source::Node(j, _) if done[j])`.
  - Chain trong một node (`ks.windows(2)`, 1422-1424) và `linear` (1480-1491): nối `Source::Node(prev, 0)`; effect giữa >1 output → lỗi; output pad = mọi output của effect cuối, tên theo quyết định 3.
- `from_parts` negotiate format (~1510-1565): `prev.output.formats` → `prev.outputs[o].formats`; `output_formats` (1557-1563) theo `Source::Node(j, o)`.
- `output_pad`/`output_size`/`bypass_pad` public (1640-1700, 1821): đổi qua `Source::Node(j, o)`, không đổi chữ ký.

### crates/gpufx-ffi/src/lib.rs
- Dòng 350-351 không đổi (đã đọc từ graph). Kiểm `effect_open` đơn (không graph) đi qua `Topology::single` để `output_names` là `default` hoặc tên manifest theo quyết định 3.
- Dòng 799-804: thông báo lỗi cho effect đơn nhiều output ("the effect has 2 outputs; use gpufx_effect_process_graph()").
- Test `a_graph_has_several_outputs` (1660-1710): thêm bài effect đơn hai output: count = 2, tên, size, format từng pad.
- `crates/gpufx-ffi/include/gpufx.h`: chỉ sửa comment ("graph output" → "effect or graph output"). Không bump `GPUFX_API_VERSION`.
- `crates/gpufx-ffi/src/ai.rs`: dùng `nb_outputs` riêng của AI filter; chỉ kiểm có dùng `manifest.output` không (grep).

### ffmpeg/vf_gpufx.c (copy vào FFmpeg qua `ffmpeg/integrate.sh`; không sửa `external/FFmpeg`, không cần patch mới)
- Tạo pad (527-543): không đổi. Sửa comment/`.description` của filter và tài liệu option nói rõ effect có thể có nhiều output.
- `config_output` (2470-2512): đã theo từng pad. Kiểm `s->source[k]` (input cho SAR/frame rate) lấy `gpufx_effect_output_pad(k)` – với effect đơn là input 0 hoặc input `bypass`; đảm bảo FFI trả đúng.
- `activate` (2516-2545) + đẩy frame (2177-2230): không đổi logic; cùng pts cho mọi output, EOF output 0 đóng các output khác. Ghi rõ trong comment rằng output phụ đóng sớm vẫn tính toán (lãng phí GPU nhưng đúng). Cân nhắc (backlog): khi mọi output khác 0 đều đóng thì bỏ qua... không cần v1.
- `out_format` (dòng ~553): đang áp cho MỌI output; với matte `gray` sẽ xung đột. Đề xuất: giữ áp cho mọi output nhưng báo lỗi rõ khi một output không nhận format đó; thêm Q6 nếu user muốn `out_format` theo pad (vd `out_format=nv12|gray`).
- Các đường process Vulkan/D3D12/D3D11/VT (1013-1060, 1339-1420): đã truyền mảng; kiểm cấp `hw_frames_ctx` riêng mỗi output (dòng ~2006-2030) theo format/size riêng của pad (đã có, chỉ cần test).
- `ffmpeg/vf_gpufx_ai_*.c`: không đụng.

### Package và tài liệu
- `packages/gpufx/**/manifest.json` (~95 file có `"output"` cấp effect, trong đó `ffmpeg/hstack`, `ffmpeg/vstack` (nay dùng `gpufx_output_size` thay `size`), `ffmpeg/monochrome` có `formats`): chuyển `"outputs": {...}` → `"outputs": [{"name": "<tên output pass cuối>", ...}]` bằng script (Python `json` sẽ đổi format/line ending → dùng regex có kiểm CRLF, hoặc script đọc/ghi giữ nguyên byte ngoài khối `output`). Chú ý không nhầm với `passes[i].output` (đã là mảng chuỗi sau plan trước).
- Một package mẫu mới (vd `packages/gpufx/ffmpeg/alphaextract` hoặc `chromakey-matte`) xuất `color` + `matte` để test thật bằng ffmpeg.
- `docs/EFFECT_FORMAT.md` + `docs/EFFECT_FORMAT-vi.md`: mục `output` cấp effect (bảng trường, mặc định, ví dụ), luật "output = texture pass", bypass theo output, tên pad; phần graph: node ghi nhiều label. Sửa cả hai bản cho khớp.
- `docs/design/DESIGN.md` + `-vi.md`: đoạn mô tả Topology/Source và pad của filter.
- Tài liệu filter (README/usage của `gpufx`): ví dụ lệnh:
  `ffmpeg -i in.mp4 -filter_complex "[0]hwupload,gpufx=effect=key.zip[c][m];[c]hwdownload,format=nv12[co];[m]hwdownload,format=gray[mo]" -map [co] c.mp4 -map [mo] m.mp4`
- Thuật ngữ mới (output pad, matte) bổ sung `docs/Glossary-vi.md` nếu chưa có.

## Test

- `manifest.rs` tests: như mục manifest ở trên.
- `crates/gpufx-core/tests/graph.rs`:
  - Effect đơn hai output (`gpufx_write` → `color`, `gpufx_write1` → `matte`), kiểm pixel cả hai output, WGSL và GLSL như bài hiện có.
  - Output lấy từ pass giữa (pass 1 ghi `matte` + `tmp`, pass 2 đọc `tmp` ghi `color`).
  - Graph: `[0]key[c][m];[c]blur[o1]` → hai output graph `o1`, `m`; và `[m]` đi vào effect thứ hai.
  - Pool: output phụ là output graph không bị cấp trùng slot với texture tạm của effect sau (bài kiểm `plan` hiện có làm mẫu).
  - Direct output: output 1 là RGBA thẳng được ghi trực tiếp, output 0 qua conversion nv12 – cả hai đúng.
  - Bypass: tắt effect hai output → cả hai output = input bypass của nó; `bypass` trỏ input thứ hai.
  - Lỗi: chain có effect giữa hai output; node graph ghi thiếu label.
- `crates/gpufx-core/tests/groups.rs`: group thiếu một output effect bị từ chối.
- FFI test (lib.rs): effect đơn hai output.
- Thực trên FFmpeg (VM build / `scripts/test-bundle`): lệnh ví dụ ở trên với Vulkan và D3D12; kiểm hai file ra cùng số frame, cùng pts (`ffprobe -show_entries frame=pts`), EOF đúng khi một output `-frames:v` ngắn hơn.
- Test hồi quy: toàn bộ bộ test cũ xanh sau khi chuyển package.

## Rủi ro

- `Source::Node(j)` dùng ở rất nhiều chỗ trong `graph.rs` (~2000 dòng): dễ sót chỗ ngầm giả định "output 0". Dựa vào compiler + grep `Source::Node`, `finals`, `.output()`.
- Pool/lifetime: output effect không phải pass cuối thì texture của nó phải sống tới khi graph đọc ra; sai sẽ ra pixel rác chứ không lỗi. Test pool là bắt buộc.
- Direct output ghi thẳng vào frame khi output đến từ pass giữa mà pass sau vẫn ghi texture khác: kiểm kỹ điều kiện `elsewhere`.
- Bypass copy nhiều output: thứ tự encode và giữ sống input.
- Chuyển ~95 manifest bằng script: nguy cơ đổi line ending/định dạng, hoặc đụng nhầm `passes[].output`. So `git diff --stat` hai kiểu và soát mẫu vài file.
- FFmpeg: output phụ không được nối (`-map` thiếu) → ffmpeg báo pad chưa nối; ghi rõ trong tài liệu. `out_format` chung cho mọi pad có thể làm hỏng lệnh có matte `gray`.
- Xung đột với branch `feat/multi-output-passes` nếu làm song song: phải chờ phần đó commit xong.

## Thứ tự làm (commit theo từng bước)

1. manifest.rs: cú pháp mảng + validate + tests; chuyển toàn bộ package; tài liệu EFFECT_FORMAT (commit 1).
2. graph.rs/runtime.rs: `Source::Node(j, o)`, plan, direct output, bypass, parser graph, chain; tests core (commit 2, cần review).
3. FFI + comment header + test FFI; vf_gpufx.c comment/`out_format`; package mẫu; test thật trên FFmpeg (commit 3).
4. DESIGN + tài liệu filter (có thể gộp vào 3).
5. `out_format` nhiều mục `|` (Q6): chỉ `vf_gpufx.c` + tài liệu filter + test bundle (commit 5, nhỏ; làm sau commit 3 vì cần effect nhiều output để test thật).
6. Output `repeat` (quyết định 9): manifest + prelude + parser + tests + tài liệu (commit 6, cần review), làm SAU khi 1-3 chạy ổn.

## Luật cho agent thực hiện

- Không sửa `external/FFmpeg`; phía C chỉ sửa `ffmpeg/*.c`, thay đổi lõi FFmpeg (nếu có) đi qua `ffmpeg/patches`. Đọc `~/.claude/ffmpeg.md` trước khi đụng phía C.
- Line ending: giữ đúng kiểu từng file (đa số CRLF; file `.sh` là LF). Trước mỗi commit so `git diff --cached --stat` với `git diff --cached --stat --ignore-cr-at-eol` và `git ls-files --eol` các file đã sửa; lệnh kiểm chạy riêng, đọc rồi mới commit.
- Trước commit: `cargo fmt --all` và `cargo clippy --workspace --all-targets -- -D warnings` (CI fail ở fmt).
- Test/build ghi log ĐẦY ĐỦ ra file trong scratchpad (vd `cargo test --workspace 2>&1 | tee <scratchpad>/test.log`), rồi mới lọc; không chạy chế độ quiet.
- Bước 2 và 3 đổi hợp đồng manifest/graph nhiều file: một lượt review độc lập (agent `opus`) trước commit mỗi bước; tối đa 2 vòng.
- Ghi việc hoãn (size khác nhau từng output, `out_format` theo pad, bỏ tính output đã đóng) vào `docs/Backlog-vi.md` (hoặc `docs/Backlog/`) theo quy ước repo.
