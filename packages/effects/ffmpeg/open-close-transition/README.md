# Open Close

The second clip opens from the center as a circle, a vertical slit or a horizontal slit, or closes in from the edges (`shape`, `direction`). Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `open-close-transition.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `shape` | int | `0` | 0 to 2 | 0 = circle, 1 = vertical (opens left and right), 2 = horizontal (opens up and down) |
| `direction` | int | `0` | 0 to 1 | 0 = open (the second clip appears in the center and spreads out), 1 = close (the second clip comes in from the edges toward the center) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='open-close-transition.zip=progress=clip((t-1)/1.5\,0\,1)&shape=1&direction=1',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='open-close-transition.zip=progress=clip((t-1)/1.5\,0\,1)&shape=1&direction=1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

## Notes

Port of FFmpeg's `xfade` transition `circleopen`, `circleclose`, `vertopen`, `vertclose`, `horzopen` and `horzclose` (`shape` 0 = circle, 1 = vert, 2 = horz; `direction` 0 = open, 1 = close). The edge is a wide soft gradient, unlike [circle-reveal](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/packages/effects/ffmpeg/circle-reveal/README.md) (a hard-ish circle with a movable center).
