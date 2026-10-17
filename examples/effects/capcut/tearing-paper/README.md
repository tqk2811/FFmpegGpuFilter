# Tearing Paper

A ragged tear runs across the middle of the first clip from left to right, hairline cracks spread from it, then the paper shreds apart from the tear outward to reveal the second clip. Drive `progress` from 0 to 1.

Recreates the CapCut "Tearing Paper" transition (the tear is drawn procedurally on a 16:9 sheet that covers the frame). Recommended duration: 1.47 s (the CapCut default), e.g. `progress=clip((t-1)/1.47\,0\,1)`.

## Overlap mode

CapCut does not blend the two clips for this transition: it feeds the effect the first clip in both roles while `progress` is below 0.5, and the second clip in both roles from 0.5 on, so in CapCut the tear is invisible and the result is a plain cut at the midpoint. `overlap=false` (the default) reproduces that frame for frame. `overlap=true` keeps the first clip as the paper and the second clip behind it all the way through, so the tear actually reveals the second clip.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `tearing-paper.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `overlap` | bool | `false` | | false = like CapCut: one clip in both roles per half (a cut at the midpoint); true = the tear reveals the second clip |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='tearing-paper.zip=progress=clip((t-1)/1.47\,0\,1)',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='tearing-paper.zip=progress=clip((t-1)/1.47\,0\,1)',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'tearing-paper.zip=progress=0.5' -i a.png -i b.png -o out.png
```
