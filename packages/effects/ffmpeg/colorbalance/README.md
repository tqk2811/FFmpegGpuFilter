# Color Balance

Shifts the red, green and blue channels separately in the shadows, midtones and highlights.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `colorbalance.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `rs` | float | `0` | -1 to 1 | Shift of the red channel in the shadows (cyan to red) |
| `rm` | float | `0` | -1 to 1 | Shift of the red channel in the midtones (cyan to red) |
| `rh` | float | `0` | -1 to 1 | Shift of the red channel in the highlights (cyan to red) |
| `gs` | float | `0` | -1 to 1 | Shift of the green channel in the shadows (magenta to green) |
| `gm` | float | `0` | -1 to 1 | Shift of the green channel in the midtones (magenta to green) |
| `gh` | float | `0` | -1 to 1 | Shift of the green channel in the highlights (magenta to green) |
| `bs` | float | `0` | -1 to 1 | Shift of the blue channel in the shadows (yellow to blue) |
| `bm` | float | `0` | -1 to 1 | Shift of the blue channel in the midtones (yellow to blue) |
| `bh` | float | `0` | -1 to 1 | Shift of the blue channel in the highlights (yellow to blue) |
| `pl` | bool | `false` | - | Preserve lightness |


Port of FFmpeg's `colorbalance`. The option names, defaults and ranges are FFmpeg's. The formula works on the 0..1 values of the RGBA frame (FFmpeg works on the planar RGB frame; a pixel format change does not change the result).

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorbalance.zip=rs=0.3&bs=-0.3&rh=-0.2&bh=0.2',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorbalance.zip=rs=0.3&bs=-0.3&rh=-0.2&bh=0.2',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'colorbalance.zip=rm=0.3&bm=-0.3' -i in.png -o out.png
```
