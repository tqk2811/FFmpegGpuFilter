# Limitations and untested parts

[Tiếng Việt](LIMITATIONS-vi.md) · [README](../README.md)

What gpufx does not do yet and what has never run for real. Each item is a **Limitation** (known, the way it is
now) or **Untested** (there is code, but it has not run on that hardware or environment). Planned work is in
[Backlog-vi.md](Backlog-vi.md).

## Hardware and platforms it has run on

- Windows: NVIDIA RTX 4060 Laptop and Intel UHD Graphics, with Vulkan, D3D12 and D3D11.
- Linux: lavapipe (software Vulkan) in CI only.
- **Untested:** AMD GPUs (every API); real GPUs on Linux (NVIDIA, RADV, ANV); Macs (the VideoToolbox/Metal path is
  only cross-compiled, the `ffmpeg-macos` CI job has never run). The other GPUs listed as supported in
  [REQUIREMENTS.md](REQUIREMENTS.md) come from public tier tables, not from tests. Minimum Windows/macOS versions
  are not verified.
- **Untested:** CI cannot run D3D (the Windows runner has only WARP), so the D3D tests are skipped.

## Vulkan

- **Limitation:** only frames with one VkImage per plane (`-init_hw_device vulkan=...,disable_multiplane=1`);
  multiplane frames and frames of the Vulkan decoders (`-hwaccel vulkan`) are refused, use `hwdownload,hwupload`
  or `gpufx_upload`.
- **Limitation:** FFmpeg 9.0 makes `yuva420p`/`yuva444p` frames contexts without usage flags, so Vulkan outputs
  cannot be those formats (inputs through `hwupload` work).
- **Limitation:** a queue family with both graphics and compute is required; a compute-only family is not used.
- **Limitation:** after a submit the driver rejects, the shared device stays broken for the rest of the process,
  with no recovery (D3D12 too).
- **Limitation:** the effect is compiled twice at startup (default device at init, FFmpeg's device at configure).
- **Limitation:** Intel on Windows (FFmpeg 9): `hwupload`/`hwdownload` break through the driver's host image copy,
  so gpufx refuses those frames. Use `gpufx_upload`/`gpufx_download`. See [INTEL_VULKAN.md](INTEL_VULKAN.md).
- **Untested:** Vulkan encoders, `hwmap` from CUDA/VAAPI, `gpufx_download` with `-hwaccel vulkan` frames.

## D3D12 / D3D11

- **Limitation:** `gpufx` reads and writes D3D frames of `nv12`, `p010le`, `rgba` and `rgba64le` only. D3D11 `bgra`
  frames and textures with more than one mip level are refused.
- **Limitation:** FFmpeg without this repository's patches (e.g. gpufx built into an FFmpeg from elsewhere) has no
  D3D frames with alpha; the repository's bundles have the patches. Details in
  [D3D11/D3D12 frame formats](#d3d11d3d12-frame-formats).
- **Limitation:** D3D12 needs feature level 11_0 and resource binding tier 2 (no Intel Haswell/Broadwell).
- **Limitation:** D3D11 frames run on a D3D12 device of the same adapter through shared NT handles: Windows 10
  1703+ and D3D11.4 shared fences are needed, `d3d12.dll` stays loaded for the whole process, and the Agility SDK
  or another D3D12 runtime is refused.
- **Limitation:** D3D12 waits on the CPU for the previous submit at each frame (one frame of overlap lost), because
  FFmpeg's D3D12 upload does not wait for its fence.
- **Limitation:** texture arrays, frames larger than the link size, outputs without UAV and D3D11 inputs that
  cannot be shared (`hwupload`, decoders) cost an extra GPU copy.
- **Untested:** D3D decoders (`-hwaccel d3d12va` / `d3d11va`) feeding gpufx.

## VideoToolbox (macOS)

- **Untested:** the whole VideoToolbox/Metal path (see above); there is no macOS bundle to download.
- **Limitation:** Apple silicon (unified memory) and `nv12`/`p010le` only; Intel Macs are refused. Software inputs
  that are not 4:2:0 and BGRA/RGBA VideoToolbox frames are not taken. `p010le` output needs R16/RG16 storage
  (fails on non-Apple GPUs). No fence: each frame waits on the CPU.
- **Limitation:** Metal has no on-disk shader cache.

## Frame interpolation (`gpufx_ai_framerate`)

- **Untested:** the VideoToolbox (macOS) path of `gpufx_ai_framerate` (`gpufx_ai_interp_*_videotoolbox`); it has
  never run on a Mac.
- **Untested:** the linux64 bundle's `gpufx_ai_framerate` and `packages/gpufx_ai_framerate/rife-v4.6.zip`; only Windows has run the filter.
- **Limitation:** D3D12 and D3D11 are about 1.7x slower than Vulkan on the same GPU (RTX 4060 Laptop, 1080p: Vulkan
  about 45 ms per frame, 4K about 174 ms); prefer Vulkan.

## Super resolution (`gpufx_ai_upscale`)

- **Untested:** the VideoToolbox path has never run. Vulkan, D3D12 and D3D11 match the CPU reference in the win64
  bundle (97.5 dB f32, 57.9 dB f16); linux64 was tested on lavapipe only.
- **Limitation:** not real time: a 1080p frame x2 takes about 480-510 ms on D3D11/D3D12 (f16) and about 690 ms on
  Vulkan on an RTX 4060 Laptop.
- **Limitation:** on the Vulkan device FFmpeg creates, `precision=auto` runs f32: that device does not enable the
  16-bit features wgpu needs for f16.
- **Limitation:** frames go through 8-bit RGBA (the model's input and output): 10-bit input loses its extra bits and
  alpha is not kept.

## Formats, color, alpha, HDR

- **Limitation:** the GPU converts `nv12`, `p010le`, `yuv420p`/`422p`/`444p` (and their `10le` forms),
  `yuva420p`/`444p`, `rgba` and `rgba64le`. Other formats (12/16 bit, `p016`, `nv21`, `nv16`, `gray`...) and the
  FCC, SMPTE240M, YCgCo and BT.2020 constant-luminance matrices go through swscale, which takes `gray` as full
  range, so limited-range gray comes out wrong.
- **Limitation:** HDR (PQ/HLG) is processed as SDR, with no tonemap and only a warning; the output loses HDR10
  metadata (mastering display, content light level), ICC, film grain and motion vectors.
- **Limitation:** inputs above 10 bits are computed in half float (about 11 bits); interlaced inputs are taken as
  one frame; premultiplied float EXR goes through swscale to `rgba64le` and loses values outside 0..1.
- **Limitation:** chroma filtering differs from swscale (about 1.4 8-bit codes on average on sharp edges); YUV
  frames without color tags are guessed differently from FFmpeg (set `setparams=range=tv:colorspace=bt709` to
  match).
- **Limitation:** with `passthrough=off` (or when frames cannot be relabelled) a disabled gpufx still copies
  through YUV→RGBA→YUV; five in a row bring chroma down to about 37 dB.
- **Limitation:** 16-bit samples are read little-endian; big-endian machines get wrong colors (none to test on).

## Upload / download

- **Limitation:** `gpufx` outputs GPU frames only; it uploads CPU inputs itself, again at every event even when a
  secondary input only repeats its last frame. For a still picture made into video, put `loop` after `hwupload` so
  it is uploaded once.
- **Limitation:** `gpufx_upload`/`gpufx_download` exist for Vulkan only; a frame size change midstream returns
  EINVAL; with sparse (live) input each frame is delayed by `latency` frames.

## Effects, parameters, expressions, graph

- **Limitation:** package textures are always `rgba8unorm` (16-bit PNGs are reduced to 8 bits), at most 4096 px a
  side and 64 M texels a package. Particles: about 256 sprites a pass at most, no stateful particles.
- **Limitation:** downscaling effects (`fit`, `push-box`, `photo-collection`) do not use input mipmaps, so large
  pictures can alias or flicker.
- **Limitation:** parameter expressions have no vectors, comparisons or `if`; an FFmpeg-valid expression gpufx does
  not know (e.g. `random`) only errors at the first frame; changing an expression recompiles that effect's
  pipeline.
- **Limitation:** in an `a.zip|b.zip` chain only the first effect may have several inputs; an input size or format
  change midstream is an error.
- **Limitation (graph):** framesync follows output 0, so when output 0 closes first every output stops; pts and
  frame properties of every output come from input 0; a mistyped label becomes an extra output; package paths in
  `graph=` cannot contain `[ ] ; |`; each `gpufx` filter has its own texture pool (several filters use more VRAM
  than one `graph=`).
- **Limitation:** the package cache holds a global lock while loading and does not notice changed package files.

## Shader cache, packages, security

- **Limitation:** D3D12 shaders precompiled into a package (`gpufx pack --precompile`) are used only with
  `GPUFX_TRUST_PRECOMPILED=1`, which trusts every package; packages are not signed yet. Precompiled blobs match the
  default `expr` values only. The DXIL cache needs `dxcompiler.dll` on the DLL path.
- **Limitation:** a shader that loops forever can hang the GPU; there is no dispatch time limit yet.

## Build and bundles

- **Limitation:** no macOS bundle yet. The prebuilt bundle uses FFmpegBuild's prebuilt FFmpeg; libavutil is rebuilt
  (with the patches) in BtbN's docker image (`ghcr.io/btbn/ffmpeg-builds/<target>-lgpl-9.0`, pinned by digest), so
  the build needs docker. That image only has a `latest` tag: when BtbN removes the old one the digest must change.
  `avfilter-12.dll`/`gpufx.dll` use msvcrt while the other DLLs use UCRT.
- **Limitation:** `build-prebuilt.sh` downloads the prebuilt FFmpeg without a sha256 check.
- **Limitation:** the default `FFMPEG_FILTERS=all` build includes GPL filters; `FFMPEG_FILTERS=keep` gives a small
  build.

## D3D11/D3D12 frame formats

Stock FFmpeg makes D3D12 frames of `nv12`/`p010le` only, and D3D11 has no `rgba` (only `bgra`). Pictures or video
with alpha therefore cannot go up to D3D, neither through `hwupload` nor through the upload built into `gpufx`.
The patches in [`ffmpeg/patches/`](../ffmpeg/patches) make both backends take every format that both DXGI and
FFmpeg's software formats have. [`ffmpeg/integrate.sh`](../ffmpeg/integrate.sh) applies them with `patch -p1` to
the copy of the source a build makes; `external/FFmpeg` itself is not changed.

### Added formats

| DXGI | FFmpeg | D3D11 | D3D12 |
|---|---|---|---|
| R8G8B8A8_UNORM | `rgba` | added | added |
| B8G8R8A8_UNORM | `bgra` | already there | added |
| B8G8R8X8_UNORM | `bgr0` | added | added |
| R10G10B10A2_UNORM | `x2bgr10le` | already there | added |
| R16G16B16A16_UNORM | `rgba64le` | added | added |
| R16G16B16A16_FLOAT | `rgbaf16le` | already there | added |
| R32G32B32A32_FLOAT | `rgbaf32le` | added | added |
| R32G32B32_FLOAT | `rgbf32le` | added | added |
| B5G6R5_UNORM | `rgb565le` | added | added |
| R8 / R16 / R16_FLOAT / R32_FLOAT | `gray` / `gray16le` / `grayf16le` / `grayf32le` | added | added |
| NV12, P010 | `nv12`, `p010le` | already there | already there |
| P016 | `p016le`, `p012le` | already there | added |
| P208 | `nv16` | added | added |
| YUY2 | `yuyv422` | already there | added |
| Y210 / Y216 | `y210le` / `y216le`, `y212le` | already there | added |
| AYUV | `vuyx`, `vuya` | `vuya` added | added |
| Y410 / Y416 | `xv30le` / `xv48le`, `xv36le` | already there | added |

D3D12 also gets a new copy path (`d3d12va_transfer_data`): the layout comes from `GetCopyableFootprints` and each
plane is copied on its own, instead of the hardcoded NV12/P010 layout. A frame in a texture array is copied from
its own slice; the old code always copied slice 0.

### Tested

Random data through `hwupload` → `hwdownload`, `framemd5` compared with the input; it must match bit for bit.
Run with a small static `ffmpeg.exe` built from the patched submodule (FFmpeg n9.0), at 320x240 and 318x238.

| | NVIDIA RTX 4060 Laptop | Intel UHD Graphics |
|---|---|---|
| D3D11 | every format in the table, except those the GPU does not support (below) | every format tried, `p016le`/`p012le` included |
| D3D12 | same as D3D11 | same as D3D11 |

On Intel only `nv12`, `p010le`, `p016le`, `p012le`, `nv16`, `rgba`, `bgra`, `rgbaf16le`, `gray`, `yuyv422` and
`vuya` were tried.

win64 bundle (libavutil rebuilt with the patches): `test-bundle.sh` checks the round trip of `rgba`, `bgra`, `gray`,
`gray16le`, `rgba64le`, `yuyv422` and a PNG with alpha through
`rgba,hwupload,loop,gpufx=...:out_format=rgba,hwdownload` on D3D11 and D3D12 (alpha kept, same as the Vulkan
run); `-init_hw_device list` still has all 9 device types.

### Limitations

- **FFmpeg without the patches: no alpha with D3D frames.** `hwdownload` gives `nv12`/`p010le`
  only (D3D12) or no `rgba` (D3D11), so an output with alpha loses it there, and `out_format=rgba`, `yuva420p` or
  `yuva444p` fails (`Unsupported pixel format: rgba`). Vulkan keeps alpha with `out_format=rgba`. On D3D, split
  the result and send one copy through [alpha-extract](../packages/gpufx/ffmpeg/alpha-extract/README.md) to get
  the alpha as a gray picture, then join both on the CPU with `alphamerge`.
- **The prebuilt bundle's libavutil is a rebuild.** `scripts/build-avutil.sh` rebuilds libavutil in BtbN's image
  with the configure line stored in the prebuilt library, then checks that the exports, the libraries loaded at
  start and the hardware device types do not change. The libraries in the image may be newer than the ones
  FFmpegBuild used (they are linked statically into libavutil). The full Docker build (`build.sh`) has the patches
  but no D3D12 (Ubuntu's mingw lacks `d3d12video.h`).
- **A format the GPU does not support is left out.** The format list is filtered through
  `CheckFormatSupport`/`CheckFeatureSupport`. A format left out gives no error: FFmpeg converts to another one
  (e.g. no `p016le`/`p012le` on an RTX 4060, so `hwupload` gets `y216le` after a swscale conversion).
- **D3D filters built on the video processor can be offered formats they do not handle.** `scale_d3d12`,
  `deinterlace_d3d12`... pick from the frames context's format list, which is now longer. That fails when the
  filter runs, not during format negotiation. Convert to `nv12` before those filters.
- **`gpufx` does not read every new format.** `bgra`, gray, float... go up to D3D but `gpufx` refuses them.
- **The D3D12 patch is large.** The copy path is rewritten, so it is likely to stop applying on an FFmpeg update.
  `integrate.sh` then stops the build and names the patch.

### Not tested

- **`nv16` (DXGI P208):** neither GPU tried supports P208 textures, so this row has never run.
- **Frames in a texture array (D3D12):** only met when decoding with D3D12 (`-hwaccel d3d12va`) and then
  `hwdownload`; not tried. The subresource index is `slice + plane × initial_pool_size`, right for the texture
  array the frames context makes itself (one mip level).
- **Formats beyond the list tried on the Intel UHD:** tried on the RTX 4060 only.
- **Filters built on the video processor** (`scale_d3d12`, `deinterlace_d3d12`, `scale_d3d11`) with the new
  formats.
- **The rebuilt libavutil on Linux:** only the exports, loaded libraries and device types are checked at build
  time; vaapi/cuda/qsv/opencl have not run with it. On Windows only Vulkan/D3D11/D3D12 have run.
