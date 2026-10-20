English: [gpufx.md](gpufx.md)

# Filter `gpufx`

`gpufx` chạy một hoặc nhiều gói hiệu ứng GPU (`.zip` hoặc thư mục, xem [EFFECT_FORMAT-vi.md](../../EFFECT_FORMAT-vi.md))
trong filter graph của FFmpeg. Filter nhận frame CPU hoặc GPU (Vulkan, D3D12, D3D11, VideoToolbox) và trả ra frame GPU;
cả graph hiệu ứng của một filter chạy trong một lần submit GPU. Mã nguồn: `ffmpeg/vf_gpufx.c`. Lý do thiết kế như vậy:
[DESIGN-vi.md](../DESIGN-vi.md#5-filter-ffmpeg-gpufx).

Filter liên quan: [gpufx_upload / gpufx_download](gpufx_transfer-vi.md), [gpufx_ai_framerate](gpufx_ai_framerate-vi.md),
[gpufx_ai_upscale](gpufx_ai_upscale-vi.md).

## Cú pháp

```
gpufx=graph='<zip|thư mục>[=k=v[:k=v...]][|<zip>[=k=v...]...]'[:backend=auto|vulkan|dx12][:shortest=0|1][:out_format=<pix_fmt>][:passthrough=auto|off]
gpufx=graph='[0]split[a][b]; [a]x.zip[c]; [c][b]y.zip=k=v[out]'[:backend=...][:shortest=0|1][:out_format=<pix_fmt>][:passthrough=auto|off]
```

| Dạng | Ví dụ | Ý nghĩa |
|------|-------|---------|
| Một hiệu ứng | `graph=vignette.zip` | Một package; manifest của nó quyết định các input |
| Chuỗi (chain) | `graph='a.zip\|b.zip\|c.zip'` | Các hiệu ứng nối nhau trong một lần submit GPU, không qua frame trung gian |
| Tham số inline | `graph='vignette.zip=strength=0.6&color=#200040'` | `key=value` đặt sau package; giá trị là literal hoặc biểu thức FFmpeg |
| Graph có nhãn | `graph='[0]split[a][b]; [a]x.zip[c]; [c][b]y.zip[out]'` | Nhiều input và output, rẽ nhánh; các câu lệnh ngăn bằng `;` |
| `split` / `null` | `[0]split[a][b]`, `[0]null[x]` | `split` nhân một nhãn thành nhiều nhánh miễn phí, `null` chuyển tiếp nhãn; không tốn việc GPU |

Trên dòng lệnh, bọc cả giá trị `graph=` trong `'...'` để bảo vệ `;` `[` `]` khỏi filtergraph bên ngoài.
Đường dẫn trong graph không được chứa `[`, `]`, `;` hay `|`.

## Option

**Filter `gpufx`** (input và output động, `AVFILTER_FLAG_HWDEVICE`, hỗ trợ timeline nội bộ)

| Option | Kiểu | Mặc định | Khoảng / giá trị | Ý nghĩa và ràng buộc |
|--------|------|----------|------------------|----------------------|
| `graph` | string | không có | đường dẫn một effect, chuỗi `\|` hoặc graph có nhãn | Bắt buộc: thiếu thì filter lỗi ở init. Số input pad là số input của effect đầu với chain không nhãn (với input `repeat` là `default`), còn lại là pad lớn nhất được đọc (có nhãn hoặc gắn ngầm) cộng một; số output pad là số output của graph |
| `backend` | string | `auto` | `auto`, `vulkan` (`vk`), `dx12` (`d3d12`, `directx`), `metal` (`mtl`); không phân biệt hoa thường | Chỉ để test: `auto` theo device của frame. `gl` bị từ chối; `metal` bị từ chối nếu bản build không có VideoToolbox (macOS). Tên khác báo lỗi khi mở graph |
| `shortest` | bool | `0` | `0`, `1` | `0`: chỉ input 0 quyết định điểm kết thúc (input khác giữ frame cuối, và hiện frame trống trước frame đầu của nó). `1`: output kết thúc khi một input bất kỳ kết thúc |
| `out_format` | pix_fmt | không có (chọn theo input) | tên pixel format bất kỳ của FFmpeg | Ép format của mọi output (`sw_format` của GPU frame). Phải nằm trong `output.formats` của effect, libgpufx ghi được và device lưu được, nếu không cấu hình lỗi. Một format cho mọi output |
| `passthrough` | int (enum) | `auto` | `auto`, `off` | Khi `enable=` tắt filter: `auto` gắn nhãn lại texture input thành frame output, không copy GPU, nếu pixel không đổi và filter kế tiếp là `gpufx`, `gpufx_download` hoặc `hwdownload`; `off` luôn copy |
| `bypass` | int (enum) | `0` | `0`, `auto` | Input được chuyển tiếp khi filter bị `enable=` tắt: `0` là input pad nguồn của từng output, `auto` là pad đó cho tới khi filter được bật một frame, sau đó là input pad cuối. Pad được chọn phải cùng size với output, nếu không `EINVAL` |
| `enable` | string (expression) | không có | expression timeline của FFmpeg | Option timeline chung của FFmpeg (`AVFILTER_FLAG_SUPPORT_TIMELINE_INTERNAL`): bằng 0 thì filter đi đường disabled mô tả ở `passthrough`/`bypass`. Khác với `enable=` inline của một effect |

Option `effect` cũ đã bị bỏ: `graph` là cách duy nhất để chỉ định effect. Các thông tin khác không phải option:

| Mục | Giá trị |
|-----|---------|
| Tên pad | Do libgpufx đặt (`gpufx_effect_input_name`, `gpufx_effect_output_name`) |
| Lệnh runtime (`process_command`, `sendcmd`, zmq) | Chỉ có `params`; lệnh khác trả `ENOSYS` (lệnh timeline chung `enable` do FFmpeg tự xử lý) |
| Tham số của `params` | Cặp `node.name=value` phân tách bằng `\|`; thêm `node.enable=<expr>` và `node.bypass=0\|auto`, hoặc `enable`/`bypass` trần (xem [Lệnh runtime `params`](#lệnh-runtime-params)) |
| Frame output | Chỉ GPU frame (Vulkan, D3D12, D3D11, VideoToolbox) |

## Hành vi

- **graph**: option duy nhất. Một hiệu ứng viết `graph=a.zip`; chuỗi viết `graph='a.zip|b.zip|c.zip'`; cả đồ thị
  nhiều input và output viết bằng nhãn (xem [Pad và quy tắc graph](#pad-và-quy-tắc-graph)). Số input của filter lấy từ
  manifest của hiệu ứng đầu (hoặc, với graph, pad lớn nhất được đọc cộng một; với input `repeat` là số nhãn mà node đọc). Câu lệnh không cần nhãn, như filtergraph
  của FFmpeg: input không nhãn gắn vào pad input thấp nhất mà không nhãn nào trong graph chỉ tới, và output không nhãn
  thành output của graph (luật đầy đủ ở [Pad và quy tắc graph](#pad-và-quy-tắc-graph)).
- **Chuỗi hiệu ứng** `graph='a.zip|b.zip|c.zip'`: chạy lần lượt như ba filter nối nhau, nhưng
  mọi pass nằm trong một lần submit GPU, không qua frame trung gian.
  Input của filter là input của hiệu ứng đầu; chỉ hiệu ứng đầu được có nhiều input. Output
  theo quy tắc của hiệu ứng cuối. Quy tắc của hiệu ứng sau được kiểm như khi nối filter:
  format là format đầu tiên trong `output.formats` của hiệu ứng trước mà hiệu ứng sau nhận,
  kích thước là kích thước hiệu ứng trước ghi ra (của input đầu, hoặc size đã xếp chồng với `output.size`). Frame vẫn là RGBA trên GPU, không chuyển sang format đó.
  Mỗi hiệu ứng có tham số inline riêng (`graph='gaussian-blur.zip=radius=8|vignette.zip=strength=0.6'`, xem
  "Tham số inline" bên dưới). Dấu cách quanh `|` được bỏ qua.
- **Chỉ trả ra frame GPU**, giống các filter `*_cuda`: mọi output là frame Vulkan, D3D12, D3D11 hoặc VideoToolbox, nên trước
  filter CPU và encoder phải có `hwdownload,format=<fmt>` hoặc `gpufx_download,format=<fmt>`. Input có thể là frame
  GPU của API đó hoặc frame CPU; frame CPU được filter tự upload (`av_hwframe_transfer_data` vào frames context
  riêng của từng input): giữ nguyên format khi device nhận format đó, không thì thành nv12/p010le (YUV 4:2:0)
  hoặc RGBA do swscale chuyển; frame có ma trận màu mà GPU không chuyển được thì lên dạng RGBA. Device là device
  của các input GPU, không thì là `-filter_hw_device`
  (`AVFILTER_FLAG_HWDEVICE`), loại device quyết định API; chỉ có input CPU mà không có device thì filter báo lỗi
  kèm các option cần thêm. `-filter_hw_device` khác API với input GPU thì bị từ chối (nó quyết
  định format output); cùng API nhưng khác device thì bị bỏ qua: device của input GPU được dùng, input CPU
  được upload lên đó, kèm cảnh báo. Option `backend` chỉ để thử nghiệm (`auto` tự theo frame); `backend=metal` bị từ chối trừ trên macOS (thư viện và CLI vẫn giữ).
  Thêm một API là thêm một dòng vào `hw_apis[]` và các nhánh trong các switch theo API của
  `vf_gpufx.c`.
- **out_format**: ép pixel format của mọi output (với frame Vulkan/D3D: sw_format của frames context đầu
  ra). Format phải nằm trong danh sách output của effect, libgpufx phải chuyển được trên GPU
  (`gpufx_format_supported`), và với frame GPU thì FFmpeg phải tạo được storage image của nó; không thì
  filter báo lỗi lúc configure. Mặc định: format của input nguồn (input CPU: format nó được upload) nếu effect
  được trả ra format đó, không thì format output đầu tiên GPU ghi được (xem "Frame Vulkan" trong [DESIGN-vi.md](../DESIGN-vi.md)). Dùng: `out_format=rgba` giữa các `gpufx` rời để filter ở giữa bỏ qua chuyển
  đổi YUV ↔ RGBA (filter cuối quay về bằng `out_format=nv12`).
  Giới hạn: một format cho mọi output của filter; với frame D3D chỉ nv12, p010le, rgba, rgba64le; với frame VideoToolbox chỉ nv12, p010le.
- **passthrough** (`auto`, `off`; mặc định `auto`): filter làm gì khi timeline `enable=` tắt nó.
  `auto` đưa cho mỗi output texture của input nguồn, gắn nhãn lại thành frame của output (buffer
  của input cùng frames context của output link, không copy trên GPU) khi copy trên GPU sẽ giữ
  nguyên pixel và filter kế tiếp là `gpufx`, `gpufx_download` hoặc `hwdownload` (các filter chỉ đọc
  frame qua frames context và texture của nó). Điều kiện: frame GPU không do gpufx upload; cùng kích
  thước, sw_format, device, colorspace, range và alpha mode với output link; `out_format` không đặt
  hoặc trùng; texture mà frames context của output mô tả đúng: Vulkan cùng tiling, format từng
  plane, cờ frame (trừ cờ multiplane), cờ tạo image và số layer, usage có đủ thứ bên đọc cần (sampled, transfer
  source, host transfer nếu context của output có); D3D12 cùng DXGI format, không texture array;
  D3D11 luôn được (hwdownload copy đúng texture và index của frame); VideoToolbox không bao giờ.
  Nhiều output thì tất cả hoặc không cái nào. Filter kế tiếp khác (encoder, `null`...) và `off` thì
  copy trên GPU như cũ. Frames context của output giữ frames context của mọi texture nó đã gắn
  nhãn, nên texture sống lâu hơn mọi frame và mọi gpufx phía sau còn giữ wrapper của chúng.
- **bypass** (`0`, `auto`; mặc định `0`): input nào được đưa ra khi timeline `enable=` tắt filter
  (relabel hoặc copy như trên). `0`: input pad nguồn của mỗi output (input 0 với một effect).
  `auto`: pad đó cho tới khi filter đã bật ít nhất một frame, sau đó là input pad cuối; dành cho
  transition (input 0 chuyển dần sang input cuối) cần tiếp tục hiện clip nó kết thúc ở đó:
  `[a][b]gpufx=graph=xfade.zip:enable='between(t,2,3)':bypass=auto`. Sau cửa sổ bật đầu tiên nó
  giữ input cuối, kể cả trước các cửa sổ sau. Pad được chọn phải cùng kích thước với output, nếu
  không frame đó báo lỗi (`EINVAL`), không bao giờ lặng lẽ lấy input khác.
- **Tham số inline**: viết ngay sau tên package, giống option của một filter FFmpeg gốc:
  `pkg.zip=key=value:key2=value2`, trong `graph=` (kể cả chain: `graph='a.zip=k=1|b.zip'`) và trong mọi node của
  `graph=` (`[b]grayscale.zip|vignette.zip=strength=0.6[gb]`). Key phải có tên (không có giá trị theo vị trí). Giá
  trị là literal (`0.5`, `1,0,0`, `#ff8800`) hoặc **biểu thức FFmpeg** theo `t`, `n`, `w`, `h`, `a` (`w/h`), `sar`,
  `dar` (`a*sar`), tính lại mỗi frame. Đây là cách làm keyframe/transition không cần tool ngoài.
  Key lạ là lỗi có nêu tên effect và key; key cho hai lần cũng vậy. Filter không có option `params`; muốn đổi
  giá trị trong lúc stream chạy thì dùng lệnh `sendcmd` bên dưới.
  - **Escape.** Bọc cả giá trị `graph=` trong `'...'`. Bộ parse option của FFmpeg tách option của filter
    tại `:` *sau khi* đã bỏ các dấu nháy đó, nên trên dòng lệnh ffmpeg các key inline phân tách bằng `&` (không
    cần escape; dấu `:` kiểu FFmpeg cũng được chấp nhận nhưng phải viết `\:`, vd `a=1\:b=2`; một key thì không cần
    dấu phân tách), còn dấu phẩy trong biểu thức giữ `\,` như thường lệ:
    `-vf "gpufx=graph='wipe.zip=progress=clip(t/2\,0\,1)&angle=45'"`,
    `graph='vignette.zip=strength=0.7'`. Bên trong chính chuỗi graph (sau khi FFmpeg đã bỏ escape),
    `\` escape một ký tự trong `\ ' : & ; | = [ ]` (`\&` là `&` nguyên văn trong giá trị; đứng trước ký tự khác thì `\` giữ nguyên, nên đường dẫn
    Windows vẫn dùng được) và `'...'` bọc một giá trị; ở tầng này dấu phẩy không cần escape.
- **`enable=<expr>` inline** trên một effect bật/tắt effect đó theo từng frame (bật khi biểu thức khác 0; hằng
  số cũng là biểu thức): `graph='a.zip|b.zip=enable=lt(t\,2)'`. Node graph gồm nhiều effect
  (`grayscale.zip|vignette.zip`) thì đặt `enable` trên từng effect cần bật/tắt. Nó không phải option timeline
  `enable=` của filter, vốn nằm ngoài chuỗi effect. Package không được khai báo param tên `enable`.
  Effect bị tắt copy input đầu của nó vào texture output của nó (output của nó có kích thước input đầu; với `output.size` `hstack`/`vstack` thì không, và việc tắt báo lỗi), nên plan, các texture trong pool và binding của phần còn lại giữ nguyên, bật/tắt không
  cấp phát gì. Tắt một effect chỉ tiết kiệm phần shader, không tiết kiệm hết: bước copy vẫn là một
  compute pass và effect vẫn giữ texture output. Khi mọi effect đều tắt, frame được xử lý như
  filter bị disable (relabel nếu `passthrough` cho phép, nếu không thì bypass trên GPU), và `n`
  vẫn đếm tiếp.
- **`bypass=0|auto` inline** trên một effect: input mà effect bị tắt copy ra. `0` (mặc định) là input đầu; `auto`
  là input đầu cho tới khi biểu thức `enable` của nó đã đúng một lần, sau đó là input cuối (effect một input thì
  giữ input đó); giá trị khác là lỗi. Input nào cũng có thể được copy, nên plan giữ mọi input của một effect sống
  tới pass cuối của effect đó. Input khác kích thước output của effect thì frame đó báo lỗi (nên effect có `output.size` `hstack`/`vstack` không bypass được). Khi mọi effect
  đều tắt, output là input pad mà các input được chọn dẫn tới. Package không được khai báo param
  tên `bypass`. Nó khác option `bypass=` của filter (input mà filter bị tắt bởi `enable=` cho qua).
  `auto` dựa trên lịch sử các
  frame đã xử lý: cửa sổ `enable` ngắn hơn một khoảng frame, hoặc luồng mà frame đầu đã nằm sau cửa
  sổ (trim, seek), thì không bao giờ được đặt và ở lại input 0; không reset khi seek; sau cửa sổ đầu
  tiên luôn là input cuối. FFI (thêm `gpufx_effect_node_effects`): `gpufx_effect_set_node_bypass`, `gpufx_effect_set_bypass`,
  `gpufx_effect_bypass_pad`.
- **timeline** (`enable='between(t,1,3)'`) được hỗ trợ.
- Nhiều input dùng `framesync`: input đầu quyết định độ dài và frame rate (input khác lệch
  fps thì frame của nó được lặp hoặc bỏ). Input khác chưa bắt đầu thì là frame GPU đen (đục với format có alpha); đã
  hết thì giữ frame cuối (hoặc `shortest=1`).
- Output nhận SAR, frame rate của input đầu (trong đồ thị: của input pad mà nguồn của nó đi ra) và kích thước từ `gpufx_effect_output_size` (của input đầu, hoặc size xếp chồng của effect `hstack`/`vstack`); colorspace/range/alpha là giá trị
  đã negotiate của link output. Side data phụ thuộc màu (HDR metadata, film grain...), motion
  vector và video enc params bị bỏ vì pixel đã khác.
- Kích thước hay pixel format của input đổi giữa chừng thì báo lỗi (`ffmpeg` tự dựng lại
  graph nên chỉ gặp khi dùng libavfilter trực tiếp).
- Cảnh báo (không chặn): SAR các input khác nhau, input trên 10 bit (hiệu ứng chạy bằng half
  float, khoảng 11 bit), input HDR PQ/HLG (shader coi như SDR), input interlaced (shader thấy hai
  field là một frame). Shader làm việc với alpha thường (straight): libgpufx chia input
  premultiplied (EXR, JPEG XL…) cho alpha trên GPU và nhân lại khi output cần.

## Key trong chuỗi `graph`

`parse_effect_item` (`crates/gpufx-core/src/graph.rs`) phân tích từng effect: `path[=key=value[:key=value...]]`.

| Mục | Quy tắc |
|-----|---------|
| Dấu ngăn giữa các key | `:` (kiểu FFmpeg) hoặc `&`; trên dòng lệnh ffmpeg `&` không cần escape, còn `:` phải viết `\:` |
| Tên key | Tên parameter của package, `enable` hoặc `bypass`. Key khác là lỗi, nêu tên effect và các key nó có; key lặp hai lần là lỗi; token không có `=` là lỗi |
| Escape và quote | `\` escape một trong `\ ' : & ; \| = [ ]` (trước ký tự khác thì `\` giữ nguyên, nên đường dẫn Windows dùng được); `'...'` bọc một giá trị; `'` không đóng là lỗi |
| `enable=<expr>` | Theo từng frame, bật khi expression khác 0 (hằng số cũng là expression). Tắt: effect copy một input vào texture output (một compute pass, không cấp phát lại gì). Package không được khai báo parameter `enable` |
| `bypass=0\|auto` | Input mà effect đang tắt sẽ copy: `0` input đầu, `auto` input đầu cho tới khi `enable` đúng một lần, sau đó là input cuối. Giá trị khác là lỗi (cũng lỗi khi input được copy và output khác size, như effect stack). Package không được khai báo parameter `bypass` |
| Hằng của parameter | Literal parse được theo kiểu của parameter (`0.5`, `1,0,0`, `#ff8800`, `true`) được đặt khi mở graph và kẹp vào `min`/`max`; parameter `expr` nhận chữ expression theo cùng cách |
| Expression của parameter | Giá trị khác là expression FFmpeg tính lại mỗi frame theo `t` (giây, `NaN` trước timestamp đầu, đưa vào shader là 0), `n` (số frame của filter này), `w`, `h` (size output), `a` (`w/h`), `sar`, `dar` (`a*sar`) |
| Câu lệnh graph | `;` ngăn các câu lệnh; nhãn `[0]`, `[1]`... chỉ input pad của filter, nhãn khác (chữ, số, `_`, `-`) nối các effect. Ở mỗi phía của câu lệnh, nhãn bỏ hết hoặc ghi đủ. Input không nhãn lấy các input pad thấp nhất mà không nhãn nào ở bất kỳ đâu trong graph chỉ tới, kể cả các câu phía sau (`ffmpeg -filter_complex` gắn stream chưa dùng đầu tiên theo thứ tự, không nhìn trước; gpufx nhìn trước vì mỗi pad chỉ được đọc một lần). Output không nhãn thành output của graph tên `out0`, `out1`..., bỏ qua nhãn graph đã dùng; `split` không nhãn ghi hai output. Chỉ một câu lệnh hoàn toàn không nhãn mà nút là chain package (không phải `split`/`null`) mới chạy như chain cũ: pad đặt theo input của manifest đầu, output `default`; thêm bất kỳ nhãn nào thì pad thành `in0`, `in1`... và output `out0`... `null` đứng một mình là graph hợp lệ, không làm gì |
| Runtime (lệnh `params`) | `node.name=value` thay parameter (node = nhãn package, chỉ số từ 0, nhãn output của graph hoặc tên trần); `node.enable=`/`node.bypass=` thay giá trị inline của mọi effect node đó chỉ tới |

## Lệnh runtime `params`

`params` là lệnh runtime duy nhất (`process_command`; không phải option của filter). `sendcmd` và `zmq` gửi nó trong
khi stream chạy. Tham số: các cặp `node.name=value` cách nhau bởi `|`.

- Node là label package, chỉ số từ 0, nhãn output của graph hoặc tên package trần, như trong chain hoặc graph.
  `gb.strength` tìm effect duy nhất của `grayscale.zip|vignette.zip` có `strength`.
- `value` thay giá trị inline; có thể là literal hoặc biểu thức FFmpeg. Với parameter `expr` nó là chữ biểu thức mới
  (pipeline được dựng lại, nên đổi thỉnh thoảng thôi, đừng đổi mỗi frame).
- `<node>.enable=<expr>` và `<node>.bypass=0|auto` thay `enable=` / `bypass=` inline của mọi effect mà node gọi tên.
  Hai key này chỉ có ở đây và trong chuỗi effect, không phải option của filter.
- Key không tồn tại hoặc giá trị không parse được là lỗi trả về cho bên gửi; giá trị tốt cuối cùng được giữ.
- Lệnh khác trả `ENOSYS` (lệnh timeline chung `enable` do FFmpeg tự xử lý).

```sh
# tại t=2 s đặt strength của effect nhãn "gb"; tại t=4 s tắt effect "ba"
ffmpeg $VK -i in.mp4 -vf "sendcmd=c='2.0 gpufx@fx params gb.strength=0.2; 4.0 gpufx@fx params ba.enable=0',\
gpufx@fx=graph='[0]split[a][b]; [a]gaussian-blur.zip=radius=8[ba]; [b]grayscale.zip|vignette.zip=strength=0.6[gb]; [ba][gb]crossfade.zip=progress=0.5[out]',hwdownload,format=yuv420p" out.mp4
```

## Pad và quy tắc graph

- **Input pad.** Chain không nhãn thì filter có các input của effect đầu (pad đặt theo manifest của nó). Trong graph có
  nhãn, pad là `in0`, `in1`... (viết `[0]`, `[1]`...) tới pad lớn nhất graph đọc; mọi pad bên dưới đều phải được đọc,
  mỗi pad tối đa một lần (`split` nó để đọc hai lần).
- **Câu lệnh không nhãn.** Như filtergraph của FFmpeg, có thể bỏ nhãn, nhưng ở mỗi phía của câu lệnh thì bỏ hết hoặc
  ghi đủ. Input không nhãn gắn vào input pad thấp nhất mà không nhãn nào trong graph chỉ tới, kể cả các câu phía sau
  (`[1]a.zip[x]; b.zip[y]` cho `b.zip` pad `[0]`; bản thân `ffmpeg -filter_complex` không nhìn trước). Output không nhãn
  thành output của graph `out0`, `out1`..., bỏ qua nhãn graph đã dùng.
- **Output pad.** Các nhãn không câu lệnh nào đọc là output của filter, theo thứ tự được ghi; không có danh sách output
  tường minh, nên nhãn viết sai hiện thành một output pad thừa mà FFmpeg báo là chưa nối. Output pad k nhận SAR và frame
  rate của input pad mà nguồn của nó đi ra.
- **Input `repeat`** (manifest `inputs[].repeat`, chỉ input cuối): một input đại diện cho số pad thay đổi, ví dụ
  `hstack.zip`. Số pad là số nhãn mà node đọc (`[0][1][2]hstack.zip[out]` có 3 input), hoặc `default` của manifest khi
  node không ghi nhãn input (`graph=hstack.zip`). Chi tiết manifest:
  [Số input thay đổi](../../EFFECT_FORMAT-vi.md#số-input-thay-đổi-được).
- **`output.size`** (manifest, `first` / `hstack` / `vstack`): mặc định output có kích thước input đầu. `hstack` /
  `vstack` xếp các input cạnh nhau / chồng lên nhau, nên output lớn hơn mọi input (tối đa cạnh texture lớn nhất của GPU).
  Các effect phía sau và link output của filter thấy size đã xếp; frame rate và tỉ lệ khung vẫn lấy từ input đầu. Effect
  xếp input không tắt được (`enable=`), vì bước copy cần size output. Chi tiết manifest:
  [Quy tắc input/output](../../EFFECT_FORMAT-vi.md#quy-tắc-inputoutput).
- **Format và kích thước** được kiểm cho từng effect tại chỗ nó đứng, lúc configure: quy tắc manifest của mọi node, với
  size và format mà nguồn của nó đưa cho. Không khớp là lỗi nêu tên input và quy tắc.
- **Kiểm khi tạo filter:** vòng lặp, nhãn đọc mà không ghi, ghi hai lần hoặc đọc hai lần, input pad không được đọc, số
  nhãn so với số input của node, nhãn output toàn số.
- **Frame** đến theo sự kiện của input 0 (`framesync`). Mỗi input pad upload một lần, mỗi output pad đọc về một lần;
  các output frame của một sự kiện được gửi cùng nhau.

Ví dụ:

```sh
VK="-init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk"   # hoặc d3d12va=dx ... dx

# 1 input, tham số động theo thời gian (gpufx tự upload frame, hwdownload đưa về)
ffmpeg $VK -i in.mp4 -vf "gpufx=graph='vignette.zip=strength=clip(t/2\,0\,1)&color=#200040',hwdownload,format=yuv420p" out.mp4

# transition 2 input
ffmpeg $VK -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='wipe-transition.zip=progress=clip((t-1)/1.5\,0\,1)&angle=45',hwdownload,format=yuv420p" out.mp4

# xâu chuỗi nhiều hiệu ứng: hai filter, frame nằm trên GPU giữa hai filter
ffmpeg $VK -i in.mp4 -vf "gpufx=graph=gaussian-blur.zip,gpufx=graph='gradient-map.zip=intensity=0.6',hwdownload,format=yuv420p" out.mp4

# cùng kết quả trong một filter: một lần submit GPU
ffmpeg $VK -i in.mp4 -vf "gpufx=graph='gaussian-blur.zip|gradient-map.zip=intensity=0.6',hwdownload,format=yuv420p" out.mp4
```
