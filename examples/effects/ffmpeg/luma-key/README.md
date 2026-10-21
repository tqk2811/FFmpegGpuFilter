# Luma Key

Turns pixels of a chosen brightness range into transparency. Use a format with alpha after it, or overlay it.

## Inputs

- `src` (accepted pixel formats: `yuv420p`, `yuv422p`, `yuv444p`, `yuvj420p`, `nv12`, `rgb24`, `bgr24`, `rgba`, `bgra`)

## Output

Same size as the first input (`src`). Pixel format: one of `rgba`, `yuva420p`, `yuva444p`.

## Options

Written inline after the package name: `luma-key.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `threshold` | float | `0` | 0 to 1 | Center of the luma range that becomes transparent |
| `tolerance` | float | `0.01` | 0 to 1 | Half width of the range that becomes fully transparent |
| `softness` | float | `0` | 0 to 1 | Width of the soft edge on both sides of the range |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i greenscreen.mp4 -i bg.mp4 -filter_complex \
  "[0][1]gpufx=graph='[0]luma-key.zip=threshold=0.9&tolerance=0.1&softness=0.05[k]; [1][k]overlay.zip=x=0&y=0&scale=1[out]',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i greenscreen.mp4 -i bg.mp4 -filter_complex \
  "[0][1]gpufx=graph='[0]luma-key.zip=threshold=0.9&tolerance=0.1&softness=0.05[k]; [1][k]overlay.zip=x=0&y=0&scale=1[out]',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on PNGs:

```sh
gpufx run 'luma-key.zip=threshold=0.9:tolerance=0.1:softness=0.05' -i in.png -o out.png
```

## Notes

The output carries alpha. A filter after it must take an alpha format (`rgba`, `yuva420p`, `yuva444p`) to keep it; `overlay.zip` honours it. Converting to a format without alpha drops it.

Port of FFmpeg's `lumakey` filter. Differences: FFmpeg compares the raw Y plane of the video, so for limited-range video black is about 0.06 and white about 0.92; the shader computes BT.709 luma from RGB and maps it to that limited range (16 to 235) before comparing, so the same numbers work. For full-range (`yuvj`) video the values are slightly off. The output alpha is multiplied by the input alpha.
