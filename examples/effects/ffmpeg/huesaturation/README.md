# Hue Saturation

Shifts hue, saturation and intensity, for all colors or only some.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `huesaturation.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `hue` | float | `0` | -180 to 180 | Hue shift in degrees |
| `saturation` | float | `0` | -1 to 1 | Saturation shift |
| `intensity` | float | `0` | -1 to 1 | Intensity shift |
| `colors` | int | `63` | 0 to 63 | Colors to change, a bit mask: 1 = reds, 2 = yellows, 4 = greens, 8 = cyans, 16 = blues, 32 = magentas, 63 = all |
| `strength` | float | `1` | 0 to 100 | Strength of the filtering for the selected colors |
| `rw` | float | `0.333` | 0 to 1 | Red weight |
| `gw` | float | `0.334` | 0 to 1 | Green weight |
| `bw` | float | `0.333` | 0 to 1 | Blue weight |
| `lightness` | bool | `false` | - | Preserve lightness |


Port of FFmpeg's `huesaturation`: one 4x4 color matrix (scale, saturation, hue rotation) blended in by how much the pixel belongs to the selected colors. FFmpeg's `colors` is a flags option (`r`, `y`, `g`, `c`, `b`, `m`, `a`); here it is the sum of the bits.

Differences: the matrix is applied in float (FFmpeg uses 16.16 fixed point). FFmpeg's `lightness` mode builds the shear from a point whose x is overwritten by y (a quirk of its `transform_point`); the same quirk is kept.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='huesaturation.zip=hue=20&saturation=0.3&colors=4',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='huesaturation.zip=hue=20&saturation=0.3&colors=4',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'huesaturation.zip=hue=60&saturation=0.2' -i in.png -o out.png
```
