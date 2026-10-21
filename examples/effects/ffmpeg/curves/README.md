# Curves

Tone curves: FFmpeg's presets, or a custom curve through one middle point per channel.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `curves.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `preset` | int | `0` | 0 to 10 | Preset: 0 = none, 1 = color_negative, 2 = cross_process, 3 = darker, 4 = increase_contrast, 5 = lighter, 6 = linear_contrast, 7 = medium_contrast, 8 = negative, 9 = strong_contrast, 10 = vintage |
| `master` | vec2 | `0.5, 0.5` | - | Middle point (x, y) of the master curve through (0, 0) and (1, 1); (0.5, 0.5) leaves the preset in place |
| `red` | vec2 | `0.5, 0.5` | - | Middle point (x, y) of the red curve; (0.5, 0.5) leaves the preset in place |
| `green` | vec2 | `0.5, 0.5` | - | Middle point (x, y) of the green curve; (0.5, 0.5) leaves the preset in place |
| `blue` | vec2 | `0.5, 0.5` | - | Middle point (x, y) of the blue curve; (0.5, 0.5) leaves the preset in place |

A `vec2` is two comma-separated numbers (`red=0.3,0.6`; write `0.3\,0.6` in an FFmpeg command line).


Port of FFmpeg's `curves` (natural cubic spline, `interp=natural`). The presets are FFmpeg's, point for point. Each channel is mapped by its own curve, then by the master curve.

Differences: the `r`, `g`, `b`, `m` and `all` point lists of FFmpeg (any number of points, as text) cannot be given as a parameter. Each custom curve is a spline through three points, `(0, 0)`, the middle point and `(1, 1)`. A custom curve replaces the preset's curve of that channel (as FFmpeg does for an explicit list). The `pchip` interpolation and `psfile` are not ported.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='curves.zip=preset=9',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='curves.zip=preset=9',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'curves.zip=preset=2' -i in.png -o out.png
```
