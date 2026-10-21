# Bilateral

Edge-preserving smoothing: neighbours are weighted by distance and by luma difference.

Approximation of FFmpeg's `bilateral` (different algorithm, similar look).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `bilateral.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `sigmaS` | float | `0.1` | 0 to 8 | Spatial sigma in pixels; the window reaches 2 * sigmaS pixels |
| `sigmaR` | float | `0.1` | 0 to 1 | Range sigma: the luma difference (0..1) that still counts as the same surface |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='bilateral.zip=sigmaS=3&sigmaR=0.1',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='bilateral.zip=sigmaS=3&sigmaR=0.1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'bilateral.zip=sigmaS=3&sigmaR=0.1' -i in.png -o out.png
```

## Notes

One pass over a window of up to 33x33 pixels (radius 2 * sigmaS, at most 16), so the cost grows with the square of `sigmaS`.

Differences from FFmpeg:

- FFmpeg approximates the filter with a recursive (separable) implementation that has no window limit and takes `sigmaS` up to 512; this port sums the window directly, hence `sigmaS` is limited to 8 (a 16 pixel radius). Results are close but not identical.
- The range weight uses the luma difference and the same weight applies to R, G, B and alpha; FFmpeg filters the planes selected by `planes` (default: luma only) independently, which is not ported.
- This port filters R, G, B and A all; FFmpeg with the default `planes=1` filters the first plane only.
- The brute-force window is cut at 2 sigma, where FFmpeg uses a recursive filter without a window limit; `sigmaS` is capped at 8 (FFmpeg 512). So the result is an approximation.
