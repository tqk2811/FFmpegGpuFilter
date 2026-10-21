# Blend

Port of FFmpeg's `blend` filter: combine the top and bottom clips with one of 40 blend modes and an opacity.

FFmpeg blends each YUV plane separately; gpufx works on RGB, so the same formulas are applied to each RGB channel (values 0..1). The result of a pixel depends on the colour space, so it is not byte-identical to `blend` on YUV. `and`, `or` and `xor` work on the 8-bit value of each channel. The output alpha is the alpha of the top input.

## Inputs

- `top`: Top layer (FFmpeg's first input)
- `bottom`: Bottom layer (FFmpeg's second input, must have the same size as the top)

## Output

Same size as the first input (`top`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `blend.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `mode` | int | `0` | 0 to 39 | Blend mode, FFmpeg's numbering (table below) |
| `opacity` | float | `1` | 0 to 1 | Modes other than normal: 0 = top, 1 = fully blended. Normal: 0 = bottom, 1 = top |

| `mode` | Name | `mode` | Name | `mode` | Name | `mode` | Name |
|--------|------|--------|------|--------|------|--------|------|
| 0 | normal | 10 | exclusion | 20 | screen | 30 | heat |
| 1 | addition | 11 | hardlight | 21 | softlight | 31 | freeze |
| 2 | and | 12 | lighten | 22 | subtract | 32 | extremity |
| 3 | average | 13 | multiply | 23 | vividlight | 33 | softdifference |
| 4 | burn | 14 | negation | 24 | xor | 34 | geometric |
| 5 | darken | 15 | or | 25 | hardmix | 35 | harmonic |
| 6 | difference | 16 | overlay | 26 | linearlight | 36 | bleach |
| 7 | grainextract | 17 | phoenix | 27 | glow | 37 | stain |
| 8 | divide | 18 | pinlight | 28 | grainmerge | 38 | interpolate |
| 9 | dodge | 19 | reflect | 29 | multiply128 | 39 | hardoverlay |

FFmpeg's aliases `addition128` (= grainmerge) and `difference128` (= grainextract) are the modes 28 and 7.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i top.mp4 -i bottom.mp4 -filter_complex \
  "[0][1]gpufx=graph='blend.zip=mode=13&opacity=0.8',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i top.mp4 -i bottom.mp4 -filter_complex \
  "[0][1]gpufx=graph='blend.zip=mode=13&opacity=0.8',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'blend.zip=mode=13' -i top.png -i bottom.png -o out.png
```
