Tiếng Việt: [gpufx-vi.md](gpufx-vi.md)

# Filter `gpufx`

`gpufx` runs one or more GPU effect packages (`.zip` or directory, see [EFFECT_FORMAT.md](../../EFFECT_FORMAT.md))
inside FFmpeg's filter graph. It takes software or GPU frames (Vulkan, D3D12, D3D11, VideoToolbox) and returns GPU
frames; the whole effect graph of one filter runs in a single GPU submit. Source: `ffmpeg/vf_gpufx.c`. Why it is
built this way: [DESIGN.md](../DESIGN.md#5-the-gpufx-ffmpeg-filter).

Related filters: [gpufx_upload / gpufx_download](gpufx_transfer.md), [gpufx_ai_framerate](gpufx_ai_framerate.md),
[gpufx_ai_upscale](gpufx_ai_upscale.md).

## Syntax

```
gpufx=graph='<zip|directory>[=k=v[:k=v...]][|<zip>[=k=v...]...]'[:backend=auto|vulkan|dx12][:shortest=0|1][:out_format=<pix_fmt>[|<pix_fmt>...]][:passthrough=auto|off]
gpufx=graph='[0]split[a][b]; [a]x.zip[c]; [c][b]y.zip=k=v[out]'[:backend=...][:shortest=0|1][:out_format=<pix_fmt>[|<pix_fmt>...]][:passthrough=auto|off]
```

| Form | Example | Meaning |
|------|---------|---------|
| One effect | `graph=vignette.zip` | One package; its manifest decides the inputs |
| Chain | `graph='a.zip\|b.zip\|c.zip'` | Effects one after another in a single GPU submit, no intermediate frames |
| Inline parameters | `graph='vignette.zip=strength=0.6&color=#200040'` | `key=value` after the package; a value is a literal or an FFmpeg expression |
| Labelled graph | `graph='[0]split[a][b]; [a]x.zip[c]; [c][b]y.zip[out]'` | Several inputs and outputs, branches; statements separated by `;` |
| `split` / `null` | `[0]split[a][b]`, `[0]null[x]` | `split` copies a label for free, `null` passes it on; they cost no GPU work |

Quote the whole `graph=` value in `'...'` on the command line: it protects `;` `[` `]` from the outer filtergraph.
Paths in a graph must not contain `[`, `]`, `;` or `|`.

## Options

**Filter `gpufx`** (dynamic inputs and outputs, `AVFILTER_FLAG_HWDEVICE`, timeline supported internally)

| Option | Type | Default | Range / values | Meaning and constraints |
|--------|------|---------|----------------|-------------------------|
| `graph` | string | none | an effect path, a `\|` chain or a labelled graph | Required: the filter fails at init without it. The number of input pads is the number of inputs of the first effect for an unlabelled chain (for a `repeat` input, `default`), else the highest pad read (labelled or bound implicitly) plus one; the number of output pads is the number of graph outputs |
| `backend` | string | `auto` | `auto`, `vulkan` (`vk`), `dx12` (`d3d12`, `directx`), `metal` (`mtl`); not case sensitive | Testing only: `auto` follows the device of the frames. `gl` is refused; `metal` is refused unless the build has VideoToolbox support (macOS). Any other name fails when the graph is opened |
| `shortest` | bool | `0` | `0`, `1` | `0`: only input 0 decides the end (other inputs hold their last frame, and show a blank frame before their first frame). `1`: the output ends when any input ends |
| `out_format` | string | none (chosen from the input) | an FFmpeg pixel format name, or one per output pad separated by `\|` | Forces the format of the outputs (the `sw_format` of GPU frames). One name applies to every output (`out_format=rgba`); several give one per output pad in order (`out_format=yuva420p\|nv12`), an empty entry keeps that pad's default (`out_format=\|nv12`). Each must be a format written by libgpufx and storable by the device, else configuration fails. Errors: `unknown pixel format 'x'`, `has 3 entries` (neither 1 nor the number of output pads) |
| `passthrough` | int (enum) | `auto` | `auto`, `off` | While `enable=` turns the filter off: `auto` relabels the input textures as output frames without a GPU copy when that leaves the pixels unchanged and the next filter is `gpufx`, `gpufx_download` or `hwdownload`; `off` always copies |
| `bypass` | int (enum) | `0` | `0`, `auto` | Input passed on while the filter is disabled by `enable=`: `0` the source input pad of each output, `auto` that pad until the filter has been enabled for one frame, then the last input pad. The chosen pad must have the output's size, else `EINVAL` |
| `enable` | string (expression) | none | FFmpeg timeline expression | The generic FFmpeg timeline option (`AVFILTER_FLAG_SUPPORT_TIMELINE_INTERNAL`): when it is 0 the filter takes the disabled path described under `passthrough`/`bypass`. Not the same as the inline `enable=` of an effect |

The old `effect` option is removed: `graph` is the only way to name an effect. Other facts that are not options:

| Item | Value |
|------|-------|
| Pad names | Named by libgpufx (`gpufx_effect_input_name`, `gpufx_effect_output_name`): one effect or chain has the manifest input names and `default` for one output, the manifest output names for several; a labelled graph has `in0`... and its output labels |
| Runtime commands (`process_command`, `sendcmd`, zmq) | Only `params`; any other command returns `ENOSYS` (the generic timeline command `enable` is handled by FFmpeg itself) |
| `params` argument | `node.name=value` pairs separated by `\|`; also `node.enable=<expr>` and `node.bypass=0\|auto`, or a bare `enable`/`bypass` (see [Runtime command `params`](#runtime-command-params)) |
| Output frames | GPU frames only (Vulkan, D3D12, D3D11, VideoToolbox) |

## Behaviour

- **graph**: the only option. A single effect is `graph=a.zip`; a chain is `graph='a.zip|b.zip|c.zip'`; a whole
  graph with several inputs and outputs is written with labels (see [Pads and graph rules](#pads-and-graph-rules)).
  The filter's number of inputs comes from the manifest of the first effect (or, in a graph, the highest pad read plus one; for a `repeat` input, the number of labels the node reads).
  Statements need no labels, as in an FFmpeg filtergraph: an unlabelled input binds to the lowest input pad no
  label of the graph names, and an unlabelled output becomes a graph output (exact rules in [Pads and graph rules](#pads-and-graph-rules)).
- **Effect chain** `graph='a.zip|b.zip|c.zip'`: runs one after another like three chained filters, but
  all passes fit in a single GPU submit, without intermediate frames.
  The filter's inputs are the inputs of the first effect; only the first effect may have multiple inputs. The output
  follows the rules of the last effect. The rules of the later effects are checked as when chaining filters:
  the size is the one the previous effect writes (the first input's, or the size from `gpufx_output_size`). Between effects the textures are RGBA on the GPU, whatever the stream format is.
  Each effect takes its own inline parameters (`graph='gaussian-blur.zip=radius=8|vignette.zip=strength=0.6'`, see
  "Inline parameters" below). Spaces around `|` are ignored.
- **GPU frames out only**, like the `*_cuda` filters: every output is a Vulkan, D3D12, D3D11 or VideoToolbox frame, so
  `hwdownload,format=<fmt>` or `gpufx_download,format=<fmt>` must come before CPU filters and encoders. Inputs
  may be GPU frames of that API or software frames, which the filter uploads itself (`av_hwframe_transfer_data`
  into its own frames context per input): as they are when the device takes the format, else as nv12/p010le
  (4:2:0 YUV) or RGBA converted by swscale; frames whose matrix the GPU does not convert go up as RGBA. The
  device is the one of the GPU inputs, else
  `-filter_hw_device` (`AVFILTER_FLAG_HWDEVICE`), and its type picks the API; with software inputs only and
  no device the filter fails and names the options to add. A `-filter_hw_device` of another API than the
  GPU inputs is refused (it sets the output format); one of the same API but another device is ignored
  (their device wins, software inputs are uploaded there, with a warning). The `backend` option is for testing only (`auto` follows the frames); `backend=metal` is refused except on macOS (the library and the
  CLI keep it). Adding an API is one entry in `hw_apis[]` plus
  its cases in the per-API switches of `vf_gpufx.c`.
- **out_format**: forces the pixel format of every output (on Vulkan/D3D frames: the sw_format of the
  output frames context). It may be any format converted on the GPU by libgpufx
  (`gpufx_format_supported`; the manifest has no `formats` list), and for GPU frames FFmpeg must make storage images of it; otherwise the
  filter fails at configuration. Default: the format of the output's source input (the first input, or the output's `bypass` input; for a software input, the format it
  is uploaded in) when libgpufx can write it, else `rgba` (see "Vulkan frames" in [DESIGN.md](../DESIGN.md)). The default drops alpha when the input has none: keep it with `out_format=rgba` (or `yuva420p`). Use: `out_format=rgba` between separate `gpufx` filters, so the middle
  ones skip the YUV ↔ RGBA conversions (the last one goes back with `out_format=nv12`).
  Limits: on D3D frames only nv12, p010le, rgba and rgba64le; on VideoToolbox frames nv12 and p010le.
- **passthrough** (`auto`, `off`; default `auto`): what the filter does while timeline `enable=`
  turns it off. `auto` hands each output its source input's texture relabelled as an output frame
  (the input's buffers with the output link's frames context, no GPU copy) when the GPU copy would
  leave the pixels unchanged and the next filter is `gpufx`, `gpufx_download` or `hwdownload`
  (filters that read a frame only through its frames context and texture). It needs a GPU frame not
  uploaded by gpufx; the same size, sw_format, device, colorspace, range and alpha mode as the
  output link; `out_format` unset or the same; and textures the output's frames context can
  describe: Vulkan same tiling, plane formats, frame flags (but the multiplane one), create flags and layers and at
  least the usage readers need (sampled, transfer source, host transfer when the output context
  has it); D3D12 same DXGI format, no texture array; D3D11 any (hwdownload copies the frame's
  texture and index); VideoToolbox never. With several outputs, all of them or none. Other next
  filters (encoders, `null`, ...) and `off` get the GPU copy as before. The output frames context
  holds the frames context of every texture it relabelled, so the textures outlive every frame and
  every gpufx downstream that keeps wrappers of them.
- **bypass** (`0`, `auto`; default `0`): which input a filter disabled by timeline `enable=` passes
  (relabelled or copied as above). `0`: each output's source input pad (input 0 for one effect).
  `auto`: that pad until the filter has been enabled for one frame, then the last input pad; made
  for transitions (input 0 fading into the last input) that should go on showing the clip they
  ended on: `[a][b]gpufx=graph=xfade.zip:enable='between(t,2,3)':bypass=auto`. After the first
  window it keeps the last input, also before later windows. The chosen pad must have the size of
  the output, else the event fails with an error (`EINVAL`), never another input.
- **Inline parameters**: written right after the package name, like the options of a native FFmpeg filter:
  `pkg.zip=key=value:key2=value2`, in `graph=` (also in a chain: `graph='a.zip=k=1|b.zip'`) and in every node of
  `graph=` (`[b]grayscale.zip|vignette.zip=strength=0.6[gb]`). Keys are named (no positional values). A value is
  a literal (`0.5`, `1,0,0`, `#ff8800`) or an **FFmpeg expression** in `t`, `n`, `w`, `h`, `a` (`w/h`), `sar`,
  `dar` (`a*sar`), re-evaluated for every frame; a vector parameter takes one expression per component, split at
  the commas outside parentheses (`anchor=0.5+0.1*t,0.5`). This is how you do keyframes/transitions without external tools.
  An unknown key is an error naming the effect and the key; so is a key given twice. The filter has no
  `params` option; to change values while the stream runs use the `sendcmd` command below.
  - **Escaping.** Put the whole `graph=` value in `'...'`. FFmpeg's own option parser splits the filter
    options at `:` *after* it removes those quotes, so in an ffmpeg command line inline keys are separated by `&`
    (needs no escaping; the FFmpeg-style `:` is also accepted but must be written `\:`, e.g. `a=1\:b=2`; a single
    key needs no separator), and commas in expressions keep the usual `\,`:
    `-vf "gpufx=graph='wipe.zip=progress=clip(t/2\,0\,1)&angle=45'"`,
    `graph='vignette.zip=strength=0.7'`. Inside the graph string itself (after FFmpeg's unescaping),
    `\` escapes one of `\ ' : & ; | = [ ]` (`\&` is a literal `&` in a value; before any other character the `\` stays literal, so Windows paths
    work) and `'...'` quotes a value; commas need no escaping at this level.
- **Inline `enable=<expr>`** on an effect switches that effect per frame (on while the expression is not 0; a
  constant is an expression too): `graph='a.zip|b.zip=enable=lt(t\,2)'`. In a graph node of several effects
  (`grayscale.zip|vignette.zip`) put `enable` on each effect that should switch. It is not the filter's own
  timeline option `enable=`, which stays outside the effect string. No package may declare a parameter named
  `enable`. An effect switched off copies its first input into its output texture
  (its output has the first input's size; with a `gpufx_output_size` that gives another size it does not, and switching off fails), so the plan, the pooled textures and the bindings of the
  rest of the graph stay as they are and toggling allocates nothing. Switching an effect off saves
  its shader work but not all of it: the copy is still one compute pass, and the effect keeps its
  output texture. With every effect off, the event is handled as a disabled filter (relabel when
  `passthrough` allows, else the GPU bypass), and `n` still counts.
- **Inline `bypass=0|auto`** on an effect: the input an effect switched off copies. `0` (default) its first
  input; `auto` its first input until its `enable` expression has been true once, then its last input (an effect
  of one input keeps it); any other value is an error. Any input may be copied, so the plan keeps every input of
  an effect alive until the effect's last pass. An input of another size than the effect's output makes the
  frame fail (so an effect with a `gpufx_output_size` that changes the size cannot be bypassed). With every effect off, the outputs are the input pads the chosen inputs lead to. No package may
  declare a parameter named `bypass`. This is not the filter option `bypass=` (which sets the input a filter
  disabled by `enable=` passes).
  `auto` rests on the history of the frames processed: an `enable` window shorter than one frame
  interval, or a stream whose first frame is already past the window (trim, seek), never sets it and
  stays on input 0; it is not reset on a seek; after the first window it is always the last input.
  FFI (also `gpufx_effect_node_effects`): `gpufx_effect_set_node_bypass`,
  `gpufx_effect_set_bypass`, `gpufx_effect_bypass_pad`.
- **timeline** (`enable='between(t,1,3)'`) is supported.
- Multiple inputs use `framesync`: the first input decides the length and frame rate (an input with a
  different fps has its frames repeated or dropped). Another input that has not started yet is a black GPU frame (opaque for formats with alpha); one that has
  ended holds its last frame (or use `shortest=1`).
- The output takes the SAR and frame rate of the first input (in a graph, of the input pad its source comes from) and its size from `gpufx_effect_output_size` (the first input's, or the size an effect's `gpufx_output_size` gives); colorspace/range/alpha are the values
  negotiated on the output link. Color-dependent side data (HDR metadata, film grain...), motion
  vectors and video enc params are dropped because the pixels have changed.
- If an input's size or pixel format changes midstream, that is an error (`ffmpeg` rebuilds the
  graph itself, so you only hit this when using libavfilter directly).
- Warnings (non-blocking): different SARs across inputs, inputs above 10 bits (effects work in half
  float, about 11 bits), HDR PQ/HLG inputs (the shader treats them as SDR), interlaced inputs (the shader
  sees two fields as one frame). Shaders work with straight alpha: libgpufx divides premultiplied inputs
  (EXR, JPEG XL...) by alpha on the GPU and multiplies again when the output needs it.

## Keys inside the `graph` string

Parsed by `parse_effect_item` (`crates/gpufx-core/src/graph.rs`) for each effect: `path[=key=value[:key=value...]]`.

| Item | Rule |
|------|------|
| Separators between keys | `:` (FFmpeg style) or `&`; on the ffmpeg command line `&` needs no escaping, `:` must be written `\:` |
| Key names | A parameter name of the package, `enable` or `bypass`. Any other key is an error naming the effect and the keys it knows; a key given twice is an error; a token without `=` is an error |
| Escape and quote | `\` escapes one of `\ ' : & ; \| = [ ]` (before any other character it stays literal, so Windows paths work); `'...'` quotes a value; an unclosed `'` is an error |
| `enable=<expr>` | Per frame, on while the expression is not 0 (a constant is an expression). Off: the effect copies one input into its output texture (one compute pass, nothing is reallocated). No package may declare a parameter `enable` |
| `bypass=0\|auto` | Which input an effect switched off copies: `0` its first input, `auto` its first input until `enable` has been true once, then its last input. Any other value is an error (also when the copied input and the output differ in size, as for a stack effect). No package may declare a parameter `bypass` |
| Parameter constants | A literal that parses as the parameter's type (`0.5`, `1,0,0`, `#ff8800`, `true`) is set when the graph opens and clamped to `min`/`max`; an `expr` parameter takes its expression text the same way |
| Parameter expressions | Any other value is an FFmpeg expression evaluated for each frame in `t` (seconds, `NaN` before the first timestamp, passed to the shader as 0), `n` (frame count of this filter), `w`, `h` (output size), `a` (`w/h`), `sar`, `dar` (`a*sar`) |
| Graph statements | `;` separates statements; labels `[0]`, `[1]`... name the filter's input pads, other labels (letters, digits, `_`, `-`) connect effects. On each side of a statement labels are left out entirely or all given. Unlabelled inputs take the lowest input pads that no label names anywhere in the graph, later statements included (`ffmpeg -filter_complex` binds the first unused stream in order without looking ahead; gpufx looks ahead because a pad may be read only once). Unlabelled outputs become graph outputs `out0`, `out1`..., skipping labels the graph uses; an unlabelled `split` writes two. Only one fully unlabelled statement whose node is a package chain (not `split`/`null`) is the old chain: pads named after the first manifest's inputs, output `default`; any label switches to pads `in0`, `in1`... and outputs `out0`... A lone `null` is a valid no-op |
| Runtime (`params` command) | `node.name=value` replaces a parameter (node = package label, 0-based index, graph output label or bare name); `node.enable=`/`node.bypass=` replace the inline values of every effect the node names |

## Runtime command `params`

`params` is the only runtime command (`process_command`; it is not a filter option). `sendcmd` and `zmq` deliver it
while the stream runs. Argument: `node.name=value` pairs separated by `|`.

- A node is the package label, its 0-based index, a graph output label, or the bare package name, as in a chain or graph.
  `gb.strength` finds the one effect of `grayscale.zip|vignette.zip` that has `strength`.
- `value` replaces the inline value; it may be a literal or an FFmpeg expression. For an `expr` parameter it is the
  new expression text (the pipelines are rebuilt, so change it now and then, not every frame).
- `<node>.enable=<expr>` and `<node>.bypass=0|auto` replace the inline `enable=` / `bypass=` of every effect the node
  names. These two keys exist only here and in the effect string, not as filter options.
- A key that does not exist, or a value that does not parse, is an error returned to the sender; the last good value stays.
- Any other command returns `ENOSYS` (the generic timeline command `enable` is handled by FFmpeg itself).

```sh
# at t=2 s set the strength of the effect labelled "gb"; at t=4 s switch the "ba" effect off
ffmpeg $VK -i in.mp4 -vf "sendcmd=c='2.0 gpufx@fx params gb.strength=0.2; 4.0 gpufx@fx params ba.enable=0',\
gpufx@fx=graph='[0]split[a][b]; [a]gaussian-blur.zip=radius=8[ba]; [b]grayscale.zip|vignette.zip=strength=0.6[gb]; [ba][gb]crossfade.zip=progress=0.5[out]',hwdownload,format=yuv420p" out.mp4
```

## Pads and graph rules

- **Input pads.** For an unlabelled chain the filter has the inputs of the first effect (pads named after its manifest).
  In a labelled graph the pads are `in0`, `in1`... (written `[0]`, `[1]`...) up to the highest one the graph reads; every
  pad below it must be read, each pad at most once (`split` it to read it twice).
- **Unlabelled statements.** As in an FFmpeg filtergraph, labels may be left out, but on each side of a statement all
  or none. An unlabelled input binds to the lowest input pad no label of the graph names, later statements included
  (`[1]a.zip[x]; b.zip[y]` gives `b.zip` pad `[0]`; `ffmpeg -filter_complex` itself does not look ahead). An unlabelled
  output becomes graph output `out0`, `out1`..., skipping labels the graph uses.
- **Output pads.** The labels no statement reads are the filter's outputs, in the order written; there is no explicit
  output list, so a misspelled label shows up as an extra output pad that FFmpeg reports as unconnected. Output pad k takes
  the SAR and frame rate of the input pad its source comes from.
- **Effects with several outputs** (manifest `outputs` with more than one element, e.g. `color` and `matte`). One
  effect alone (`graph=key.zip`) has one output pad per manifest output, named after it; an effect with one output
  keeps the pad name `default`. In a graph the labels after an effect name its outputs from the first:
  `[0]key.zip[c][m]`. Inside a chain (`a.zip|b.zip`) the first output without a label goes on to the next effect, as
  `split[a],scale` does in FFmpeg: `[0]key.zip[matte=m]|blur.zip[out]` blurs the color and writes the matte to `[m]`.
  A statement whose last effect has no labels writes every output of it as graph outputs. Any other output without a
  label is **dropped** (unlike FFmpeg, which refuses an unconnected pad): it gets no texture, and passes that only
  serve it do not run. Fewer labels than outputs is therefore fine; more is an error. Errors: `every output has a
  label, so none goes on to `b``, `` `key` writes 2 outputs (color, matte), got 3 labels``.
- **Labels by name** (gpufx only): `[name=label]` gives the label to the output, or takes it for the input, of that
  manifest name: `[0]key.zip[matte=m][color=c]`, `[bg=1][src=0]mix.zip[out]`. A side of a node uses one style:
  `[0][bg=1]x.zip` or `x.zip[matte=m][c]` is an error (`use either positional labels or `[name=label]``). Unknown
  names, a name given twice and, for inputs, an input without a label are errors. A repeated input takes the pads its
  names give, `[src0=a][src1=b]` (from 0, no gap). Input labels only open a statement: `a.zip|[c]b.zip` is an error,
  write `[c]b.zip` as its own statement.
- **Input `repeat`** (manifest `inputs[].repeat`, last input only): one input stands for a variable number of pads, for
  example `hstack.zip`. The count is the number of labels the node reads (`[0][1][2]hstack.zip[out]` has 3 inputs), or the
  manifest `default` when the node names no labels (`graph=hstack.zip`). Manifest details:
  [Variable number of inputs](../../EFFECT_FORMAT.md#variable-number-of-inputs).
- **Output size** (`gpufx_output_size`, an optional function in the shader of the pass that writes the output): by default an output has
  the size of the first input. The function (it reads only `params`, `gpufx_input_count()` and `gpufx_input_size(i)`) gives another size,
  e.g. `hstack`/`vstack` stack the inputs, `scale` resizes. The sizes are computed once, by a one-off GPU dispatch at configure, from
  the param values then (defaults and constant inline values); 0 or above the GPU's largest texture side is an error, and a size that
  changes later fails processing. Downstream effects and the filter's output link see that size; the frame rate and aspect ratio still
  come from the first input. An effect whose size differs from its input cannot be switched off (`enable=`), because the copy would need
  the output size. Manifest details: [Output size](../../EFFECT_FORMAT.md#output-size).
- **Formats and sizes** are checked per effect where it sits, at configuration: the manifest rules of every node, with the
  size and format its producer gives it. A mismatch is an error naming the input and the rule.
- **Checked when the filter is created:** cycles, labels read but never written, written twice or read twice,
  unread input pads, label counts against a node's inputs, numeric output labels.
- **Frames** come at input 0's events (`framesync`). Each input pad is uploaded once, each output pad is read back once;
  the output frames of one event are sent together.

Examples:

```sh
VK="-init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk"   # or d3d12va=dx ... dx

# 1 input, parameter animated over time (gpufx uploads the frame, hwdownload brings it back)
ffmpeg $VK -i in.mp4 -vf "gpufx=graph='vignette.zip=strength=clip(t/2\,0\,1)&color=#200040',hwdownload,format=yuv420p" out.mp4

# 2-input transition
ffmpeg $VK -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='wipe-transition.zip=progress=clip((t-1)/1.5\,0\,1)&angle=45',hwdownload,format=yuv420p" out.mp4

# chaining several effects: two filters, the frame stays on the GPU between them
ffmpeg $VK -i in.mp4 -vf "gpufx=graph=gaussian-blur.zip,gpufx=graph='gradient-map.zip=intensity=0.6',hwdownload,format=yuv420p" out.mp4

# same result in one filter: one GPU submission
ffmpeg $VK -i in.mp4 -vf "gpufx=graph='gaussian-blur.zip|gradient-map.zip=intensity=0.6',hwdownload,format=yuv420p" out.mp4
```
