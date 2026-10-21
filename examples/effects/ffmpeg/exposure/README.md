# Exposure

Exposure and black level correction.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `exposure.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `exposure` | float | `0` | -3 to 3 | Exposure in stops; positive values brighten |
| `black` | float | `0` | -1 to 1 | Black level correction |
| `linear` | bool | `false` | - | Apply on linear light: the picture is converted from sRGB to linear light and back |


Port of FFmpeg's `exposure`: `out = (in - black) / |2^-exposure - black|`.

Differences: FFmpeg's filter expects linear-light float frames and applies the formula to whatever values it gets. gpufx shaders see the gamma-encoded values of the video, so the formula is applied to them directly by default; `linear=1` (not in FFmpeg) converts to linear light around it, which is what a camera exposure change looks like.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='exposure.zip=exposure=0.5&linear=1',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='exposure.zip=exposure=0.5&linear=1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'exposure.zip=exposure=1&linear=1' -i in.png -o out.png
```
