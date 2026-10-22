# Luma Matte

Luma key with two outputs: `color`, the video with the keyed range transparent (as `luma-key`), and `matte`, the key as an opaque gray image (white where the video is kept).

## Inputs

- `src` (any pixel format the GPU converts; shaders see RGBA)

## Outputs

Two output pads, in this order, both the size of `src`:

- `color`: has alpha; the format defaults to that of `src`, so use `out_format=rgba|...` (or `yuva420p`) to keep the alpha.
- `matte`: opaque gray image; the format defaults to that of `src`, any GPU-converted format works (for example `out_format=rgba|yuv420p` gives `color` rgba and `matte` yuv420p).

## Options

Written inline after the package name: `luma-matte.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `threshold` | float | `0` | 0 to 1 | Center of the luma range that becomes transparent |
| `tolerance` | float | `0.01` | 0 to 1 | Half width of the range that becomes fully transparent |
| `softness` | float | `0` | 0 to 1 | Width of the soft edge on both sides of the range |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 -filter_complex \
  "[0]hwupload,gpufx=graph='luma-matte.zip=threshold=0.9&tolerance=0.1':out_format=yuva420p|yuv420p[c][m];[c]hwdownload,format=yuva420p[co];[m]hwdownload,format=yuv420p[mo]" \
  -map "[co]" -c:v libvpx-vp9 color.webm -map "[mo]" matte.mp4
```
