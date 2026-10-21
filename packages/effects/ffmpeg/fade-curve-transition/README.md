# Fade Curve Transition

A cross-fade whose speed depends on how different the clips are at each pixel and channel: `curve` 0 fades the differing parts early (fast), 1 late (slow). Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `fade-curve-transition.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `curve` | int | `0` | 0 to 1 | 0 = fadefast (pixels that differ a lot switch to the second clip sooner), 1 = fadeslow (later) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='fade-curve-transition.zip=progress=clip((t-1)/1.5\,0\,1)&curve=1',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='fade-curve-transition.zip=progress=clip((t-1)/1.5\,0\,1)&curve=1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

Still pictures with the CLI:

```sh
./target/release/gpufx run 'packages/effects/ffmpeg/fade-curve-transition=progress=0.5:curve=1' -i a.png -i b.png -o out.png
```

## Notes

Port of FFmpeg's `xfade` transition `fadefast` (`curve=0`) and `fadeslow` (`curve=1`). Per color channel (alpha included) the weight of the first clip is `pow(p, 1 + ln(1 + |a - b|))` for fast and `pow(p, 1 + ln(2 - |a - b|))` for slow, with `p` = FFmpeg's progress = `1 - progress`. FFmpeg runs it on the planes of the input format (for example YUV), here it runs on RGBA, so the result differs slightly on colored content.
