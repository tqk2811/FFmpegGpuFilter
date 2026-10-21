# Color Contrast

Raises or lowers the contrast between complementary colors (red-cyan, green-magenta, blue-yellow).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `colorcontrast.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `rc` | float | `0` | -1 to 1 | Red-cyan contrast |
| `gm` | float | `0` | -1 to 1 | Green-magenta contrast |
| `by` | float | `0` | -1 to 1 | Blue-yellow contrast |
| `rcw` | float | `0` | 0 to 1 | Weight of the red-cyan contrast |
| `gmw` | float | `0` | 0 to 1 | Weight of the green-magenta contrast |
| `byw` | float | `0` | 0 to 1 | Weight of the blue-yellow contrast |
| `pl` | float | `0` | 0 to 1 | Amount of lightness preserved |

Port of FFmpeg's `colorcontrast`. The option names, defaults and ranges are FFmpeg's, as is the math (`vf_colorcontrast.c`). It works on the 0..1 RGB values (FFmpeg on the planar RGB frame, values 0..max); the only difference is the tiny epsilon that guards the lightness division. With all three weights 0 (the default) the sum of weights is 0 and FFmpeg leaves the frame unchanged, so does this effect: set at least one of `rcw`, `gmw`, `byw`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorcontrast.zip=rc=0.5&rcw=1&pl=1',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorcontrast.zip=rc=0.5&rcw=1&pl=1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'colorcontrast.zip=rc=0.5:rcw=1:pl=1' -i in.png -o out.png
```
