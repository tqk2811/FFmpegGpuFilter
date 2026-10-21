# Limiter

Clamps the pixel values of the selected channels to a minimum and a maximum.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `limiter.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `min` | int | `0` | 0 to 65535 | Lower limit, in code values of `depth` bits (clamped to the depth maximum) |
| `max` | int | `65535` | 0 to 65535 | Upper limit, in code values of `depth` bits (clamped to the depth maximum, so the default is no limit) |
| `planes` | int | `15` | 0 to 15 | Bit mask of the channels to limit: 1 green, 2 blue, 4 red, 8 alpha (FFmpeg's GBRAP plane order) |
| `depth` | int | `8` | 1 to 16 | Bit depth the `min` and `max` values refer to; 8 for ordinary 8-bit video |

Port of FFmpeg's `limiter`. The option names, defaults and ranges are FFmpeg's, plus one added option, `depth`. FFmpeg reads the bit depth from the video's pixel format, and `min`/`max` are raw code values of that depth; the effect sees only 0..1 values, so `depth` says which depth to assume (default 8: `max=235` is the 8-bit limited-range white). FFmpeg limits the planes of the file's format (Y/U/V for a YUV file); here the planes are the RGB channels in GBRAP order, so limiting `planes=1` on a YUV file is not the same as limiting its Y plane. If `min` is greater than `max` FFmpeg refuses to start; this effect gives `max` priority.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='limiter.zip=min=16&max=235',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='limiter.zip=min=16&max=235',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'limiter.zip=min=16:max=235' -i in.png -o out.png
```
