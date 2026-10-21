# Vibrance

Boosts the saturation of dull colors more than that of vivid ones.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `vibrance.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `intensity` | float | `0` | -2 to 2 | Strength; negative values desaturate |
| `rbal` | float | `1` | -10 to 10 | Red balance (scales the intensity for red) |
| `gbal` | float | `1` | -10 to 10 | Green balance |
| `bbal` | float | `1` | -10 to 10 | Blue balance |
| `rlum` | float | `0.212656` | 0 to 1 | Red luma coefficient |
| `glum` | float | `0.715158` | 0 to 1 | Green luma coefficient |
| `blum` | float | `0.072186` | 0 to 1 | Blue luma coefficient |
| `alternate` | bool | `false` | - | Start the processing from the vivid colors instead |


Port of FFmpeg's `vibrance`. Option names, defaults and ranges are FFmpeg's.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='vibrance.zip=intensity=0.8',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='vibrance.zip=intensity=0.8',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'vibrance.zip=intensity=1' -i in.png -o out.png
```
