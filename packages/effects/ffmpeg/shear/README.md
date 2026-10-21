# Shear

Shears the picture horizontally and/or vertically.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `shear.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `shx` | float | `0` | -2 to 2 | Horizontal shear factor |
| `shy` | float | `0` | -2 to 2 | Vertical shear factor |
| `fillcolor` | color | `#000000` | RGBA | Color of the area outside the sheared picture |
| `interp` | int | `1` | 0 to 1 | Interpolation: 0 = nearest, 1 = bilinear |

A `color` is `#rrggbb` or `#rrggbbaa`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='shear.zip=shx=0.3&shy=0',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='shear.zip=shx=0.3&shy=0',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on PNGs:

```sh
gpufx run 'shear.zip=shx=0.3:shy=0' -i in.png -o out.png
```

## Notes

Port of FFmpeg's `shear` filter (`fillcolor` is also `c` there). Differences: `fillcolor` is an RGBA color (alpha is written to the output, FFmpeg fills with the color in the stream's format); the shear is computed on the full-resolution picture, FFmpeg shears each plane at its own resolution.  Like FFmpeg, the last column and the last row are always `fillcolor`, even with `shx=shy=0`.
