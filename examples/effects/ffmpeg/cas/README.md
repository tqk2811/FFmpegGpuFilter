# Contrast Adaptive Sharpen

AMD FidelityFX contrast adaptive sharpening: sharpens more where the local contrast is low.

Port of FFmpeg's `cas` (AMD FidelityFX contrast adaptive sharpening).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `cas.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `strength` | float | `0` | 0 to 1 | Sharpening strength |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='cas.zip=strength=0.6',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='cas.zip=strength=0.6',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'cas.zip=strength=0.6' -i in.png -o out.png
```

## Notes

One pass. Each channel is sharpened by `((b + d + f + h) * w + e) / (1 + 4 * w)` over the 3x3 neighbourhood (cross `b d f h`, centre `e`), with a negative weight `w = amp / -lerp(16, 4.01, strength)`, where `amp` is large in low-contrast areas and small near strong edges. The math runs on 8-bit levels, as in FFmpeg.

Differences from FFmpeg:

- Applied to the R, G and B channels instead of the planes of the pixel format (`planes` is not ported); alpha is passed through.
- Pixels outside the picture repeat the edge pixel.
- A flat black neighbourhood (maximum 0) is left unchanged (FFmpeg divides 0 by 0 there).
