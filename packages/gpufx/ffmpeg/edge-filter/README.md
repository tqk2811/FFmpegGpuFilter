# Edge Filter

Gradient edge detectors in one effect: Sobel, Prewitt, Roberts cross and Scharr.

Port of FFmpeg's `sobel`, `prewitt`, `roberts` and `scharr`.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `edge-filter.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `kind` | int | `0` | 0 to 3 | Edge operator: 0 = sobel, 1 = prewitt, 2 = roberts, 3 = scharr |
| `scale` | float | `1` | 0 to 65535 | Gain applied to the gradient magnitude |
| `delta` | float | `0` | -65535 to 65535 | Value added to the result, in 8-bit levels |
| `luma` | bool | `0` | 0 or 1 | 1 = edges of the luma only, written to all three channels |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='edge-filter.zip=kind=3&scale=2',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='edge-filter.zip=kind=3&scale=2',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'edge-filter.zip=kind=3&scale=2' -i in.png -o out.png
```

## Notes

One pass; the gradient magnitude `sqrt(a*a + b*b) * scale + delta` of the two kernels of the chosen operator, with the same kernels as FFmpeg (Scharr divided by 256). The `edge-detect` effect (Sobel on luma, tinted, blended over the picture) stays as it is.

Differences from FFmpeg:

- One effect with a `kind` option replaces the four filters; FFmpeg's `kirsch` and `canny` are not ported.
- Edges are computed per R, G, B channel instead of per YUV plane (`planes` is not ported); `luma=1` gives a gray edge map. The alpha channel is passed through unchanged.
- Pixels outside the picture repeat the edge pixel.
