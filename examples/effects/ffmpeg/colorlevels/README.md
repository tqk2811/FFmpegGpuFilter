# Color Levels

Adjusts the black and white points of every channel (levels).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `colorlevels.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `rimin` | float | `0` | 0 to 1 | Input red black point |
| `gimin` | float | `0` | 0 to 1 | Input green black point |
| `bimin` | float | `0` | 0 to 1 | Input blue black point |
| `aimin` | float | `0` | 0 to 1 | Input alpha black point |
| `rimax` | float | `1` | 0 to 1 | Input red white point |
| `gimax` | float | `1` | 0 to 1 | Input green white point |
| `bimax` | float | `1` | 0 to 1 | Input blue white point |
| `aimax` | float | `1` | 0 to 1 | Input alpha white point |
| `romin` | float | `0` | 0 to 1 | Output red black point |
| `gomin` | float | `0` | 0 to 1 | Output green black point |
| `bomin` | float | `0` | 0 to 1 | Output blue black point |
| `aomin` | float | `0` | 0 to 1 | Output alpha black point |
| `romax` | float | `1` | 0 to 1 | Output red white point |
| `gomax` | float | `1` | 0 to 1 | Output green white point |
| `bomax` | float | `1` | 0 to 1 | Output blue white point |
| `aomax` | float | `1` | 0 to 1 | Output alpha white point |
| `preserve` | int | `0` | 0 to 6 | Preserve color mode: 0 = none, 1 = lum, 2 = max, 3 = avg, 4 = sum, 5 = nrm, 6 = pwr |


Port of FFmpeg's `colorlevels`: `out = (in - imin) * (omax - omin) / (imax - imin) + omin`, per channel.

Differences: FFmpeg lets a negative `imin`/`imax` mean "use the smallest/largest value of the frame"; that needs a pass over the whole frame and is not ported, so the input points are limited to 0 to 1.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorlevels.zip=rimin=0.1&gimin=0.1&bimin=0.1&rimax=0.9&gimax=0.9&bimax=0.9',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorlevels.zip=rimin=0.1&gimin=0.1&bimin=0.1&rimax=0.9&gimax=0.9&bimax=0.9',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'colorlevels.zip=rimin=0.1&gimin=0.1&bimin=0.1' -i in.png -o out.png
```
