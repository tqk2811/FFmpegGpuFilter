# Kirsch

Kirsch compass edge detector: the strongest response of the eight rotated 3x3 kernels.

Port of FFmpeg's `kirsch` (from `vf_convolution.c`).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `kirsch.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `scale` | float | `1` | 0 to 65535 | Gain applied to the response |
| `delta` | float | `0` | -65535 to 65535 | Value added to the result, in 8-bit levels |
| `luma` | bool | `0` | 0 or 1 | 1 = edges of the luma only, written to all three channels |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='kirsch.zip=scale=0.5',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='kirsch.zip=scale=0.5',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'kirsch.zip=scale=0.5' -i in.png -o out.png
```

## Notes

One pass; the largest response of the eight 3x3 kernels, `abs(max) * scale + delta`. FFmpeg's kernels are ported as they are: each has 5 on three consecutive cells and -3 on the other five, the cells being taken in row-major order without the centre (c0 c1 c2 c3 c5 c6 c7 c8, cyclic). That is not the textbook clockwise Kirsch ring (for example a kernel with 5 on the top, top-right and left cells), so the output matches FFmpeg and not other Kirsch implementations.

The `edge-filter` effect (sobel, prewitt, roberts, scharr) is a separate package.

Differences from FFmpeg:

- Edges are computed per R, G, B channel instead of per YUV plane (`planes` is not ported); `luma=1` gives a gray edge map. The alpha channel is passed through unchanged.
- Pixels outside the picture repeat the edge pixel.
