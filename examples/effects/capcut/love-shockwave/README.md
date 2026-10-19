# Love Shockwave

A tiny pixel-art heart with a white and pink neon outline appears in the centre of the first clip and grows, the second clip showing inside it and faint square sparks drifting around it, until the heart fills the frame (CapCut "Love Shockwave"). Drive `progress` from 0 to 1. On the last drawn frame the heart still leaves thin slivers at the bottom corners with the outline glowing in them, as in CapCut; the next frame is the plain second clip.

Recreated from the CapCut transition of the same name; CapCut's default length for it is about 0.8 s, so drive `progress` over roughly that long.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

Like CapCut, the animation is laid out on a square stretched over the frame, so on non-square video the heart is stretched with it. The heart, its glow and the sparks are drawn in the shader (no textures); the heart size follows CapCut's 44-frame animation, stepped frame by frame. The sparks are placed by the shader, not in the same spots as CapCut's.

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `love-shockwave.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='love-shockwave.zip=progress=clip((t-1)/0.8\,0\,1)',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='love-shockwave.zip=progress=clip((t-1)/0.8\,0\,1)',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'love-shockwave.zip=progress=0.5' -i a.png -i b.png -o out.png
```
