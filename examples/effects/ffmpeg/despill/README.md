# Despill

Removes green or blue spill from the edges of a keyed subject.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `despill.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `screen` | int | `0` | 0 to 1 | Screen type: 0 = green, 1 = blue (FFmpeg: type) |
| `mix` | float | `0.5` | 0 to 1 | Spillmap mix: how much of red is compared with the screen color |
| `expand` | float | `0` | 0 to 1 | Spillmap expand: how much of the other channel is ignored |
| `red` | float | `0` | -100 to 100 | Red scale applied to the spill |
| `green` | float | `-1` | -100 to 100 | Green scale applied to the spill |
| `blue` | float | `0` | -100 to 100 | Blue scale applied to the spill |
| `brightness` | float | `0` | -10 to 10 | Brightness added back where the spill was |
| `alpha` | bool | `false` | 0 or 1 | Write the spillmap into alpha (1 - spill) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='despill.zip=screen=0&mix=0.5&green=-1',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='despill.zip=screen=0&mix=0.5&green=-1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on PNGs:

```sh
gpufx run 'despill.zip=screen=0:mix=0.5:green=-1' -i in.png -o out.png
```

## Notes

Port of FFmpeg's `despill` filter, same math. Differences: the `type` option is called `screen` because `type` is a reserved word in WGSL; FFmpeg accepts only 8-bit RGBA-type input; gpufx converts any input to RGBA first and works with straight alpha. With `alpha=1` the alpha of the result is `1 - spill`: follow it with a format that has alpha (`rgba`, `yuva420p`, `yuva444p`) or the alpha is dropped. The manifest has no `output` rule so that the filter does not force an alpha format when `alpha` is off.
