# Smart Blur

Edge-preserving gaussian blur: a threshold decides which differences are smoothed.

Port of FFmpeg's `smartblur`.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `smart-blur.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `luma_radius` | float | `1` | 0.1 to 5 | Luma gaussian radius (sigma) (`lr`) |
| `luma_strength` | float | `1` | -1 to 1 | Luma blur strength (`ls`): 1 = full blur, negative sharpens |
| `luma_threshold` | int | `0` | -30 to 30 | Luma threshold (`lt`) in 8-bit levels: positive smooths only small differences, negative smooths only large ones, 0 = everywhere |
| `chroma_radius` | float | `-1` | -1 to 5 | Chroma radius (`cr`); below 0.1 (default -1) = same as luma |
| `chroma_strength` | float | `-2` | -2 to 1 | Chroma strength (`cs`); below -1 (default -2) = same as luma |
| `chroma_threshold` | int | `-31` | -31 to 30 | Chroma threshold (`ct`); below -30 (default -31) = same as luma |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='smart-blur.zip=luma_radius=2&luma_threshold=10',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='smart-blur.zip=luma_radius=2&luma_threshold=10',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'smart-blur.zip=luma_radius=2&luma_threshold=10' -i in.png -o out.png
```

## Notes

One pass (2D gaussian with sigma = radius, up to 3 sigma on each side, in float, no intermediate texture; cost grows with the square of the radius); it applies strength and threshold against the original, with the same rules as FFmpeg.

Differences from FFmpeg:

- Luma and chroma are computed from RGB (BT.709) instead of read from YUV planes; chroma is full resolution.
- `alpha_radius`, `alpha_strength` and `alpha_threshold` are not ported: the alpha channel is passed through unchanged.
- The kernel is an exact separable gaussian; FFmpeg builds it with libswscale's vector. Pixels outside the picture repeat the edge pixel.
