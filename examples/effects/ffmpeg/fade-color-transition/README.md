# Fade Through Color

The first clip fades to a color late, the second fades in from it early, with a cross-fade between (black by default, white for xfade fadewhite). Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `fade-color-transition.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `color` | color | `#000000` | RGB | Color in the middle of the transition; alpha is ignored |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='fade-color-transition.zip=progress=clip((t-1)/1.5\,0\,1)&color=#ffffff',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='fade-color-transition.zip=progress=clip((t-1)/1.5\,0\,1)&color=#ffffff',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

## Notes

Port of FFmpeg's `xfade` transition `fadeblack` (default color) and `fadewhite` (`color=#ffffff`). It differs from [dip-to-color](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/examples/effects/ffmpeg/dip-to-color/README.md): the clips are dipped only around the ends of the fade and mixed with each other in the middle, so the color is never fully reached.
