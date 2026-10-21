# Median

Median (or any percentile) filter over a rectangular window, per channel.

Approximation of FFmpeg's `median` (different algorithm, similar look).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `median.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `radius` | int | `1` | 1 to 5 | Horizontal radius in pixels: the window is 2 * radius + 1 wide |
| `radius_v` | int | `-1` | -1 to 5 | Vertical radius; -1 = same as `radius` (`radiusV`) |
| `percentile` | float | `0.5` | 0 to 1 | Rank of the chosen value: 0 = minimum, 0.5 = median, 1 = maximum |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='median.zip=radius=2',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='median.zip=radius=2',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'median.zip=radius=2' -i in.png -o out.png
```

## Notes

One pass; the 11x11 window at most is read once, then each channel (R, G, B, A) is ranked by a 12-step binary search on the value (1/4096 precision; values above 1 are not handled) and snapping to the largest sample below it, which approximates the exact sample value.

Differences from FFmpeg:

- `radius` and `radius_v` are capped at 5 (FFmpeg allows 127) to keep the cost per pixel sane. `radius_v` uses -1 for "same as radius" where FFmpeg's `radiusV` uses 0.
- Channels are RGBA instead of YUV planes; `planes` is not ported.
- Pixels outside the picture repeat the edge pixel.
