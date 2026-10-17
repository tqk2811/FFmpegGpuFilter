# Comic Cut

A thin white crack runs down the first clip and widens, then the clip tears into two halves with white torn-paper edges and drop shadows that fly apart, tilting, over a black-and-white halftone print of the second clip; the print turns into the plain second clip near the end, and a light film grain sits over everything (CapCut "Comic Cut"). Drive `progress` from 0 to 1.

Recreated from the CapCut transition of the same name; CapCut's json lists 1.47 s for the transition, while the animation itself spans 0.8 s mapped onto progress 0..1; the default is to drive `progress` over the full 1.47 s, which plays that animation slower.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). The crack and paper edges are drawn procedurally (no texture files). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `comic-cut.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='comic-cut.zip=progress=clip((t-1)/1.47\,0\,1)',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='comic-cut.zip=progress=clip((t-1)/1.47\,0\,1)',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'comic-cut.zip=progress=0.5' -i a.png -i b.png -o out.png
```
