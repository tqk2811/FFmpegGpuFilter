# Colorize

Overlays a solid HSL color: the chroma of the color over the luma of the picture.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `colorize.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `hue` | float | `0` | 0 to 360 | Hue in degrees |
| `saturation` | float | `0.5` | 0 to 1 | Saturation |
| `lightness` | float | `0.5` | 0 to 1 | Lightness |
| `mix` | float | `1` | 0 to 1 | Mix of the source lightness (1 = keep the picture luma, 0 = the color's own luma) |


Port of FFmpeg's `colorize`: the chroma planes are set to those of the HSL color and the luma is `lerp(color luma, source luma, mix)`.

Differences: FFmpeg works in the YUV planes of the input; here the math is done in full-range BT.709 on the RGB values, with FFmpeg's 219/255 and 224/255 factors on the color's Y, U and V. Compared with FFmpeg on full-range BT.709 YUV input the result differs by a few levels at most.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorize.zip=hue=210&saturation=0.6&lightness=0.5&mix=0.8',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorize.zip=hue=210&saturation=0.6&lightness=0.5&mix=0.8',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'colorize.zip=hue=30&saturation=0.7' -i in.png -o out.png
```
