# Histogram

Luma, or R, G, B histogram bars (scope).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU. It only sets the size (see Notes).

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `histogram.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `display` | int | `1` | 0 to 2 | 0 luma, 1 red/green/blue overlay (additive colors), 2 red/green/blue parade (three panels side by side) |
| `gain` | float | `1` | 0.01 to 100 | Bar height factor. Linear: a bin 10x fuller than an even spread reaches the top at 1 |
| `log_scale` | bool | `false` |  | Logarithmic bar height |
| `samples` | int | `128` | 8 to 256 | The histogram is taken from a grid of samples x samples input pixels (bounded cost, whatever the picture size) |
| `opacity` | float | `1` | 0 to 1 | Blend over the input picture: 1 = only the generated picture, 0 = the input unchanged |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -f lavfi -i color=black:s=1280x720:r=25 \
  -vf "format=nv12,gpufx=graph='histogram.zip=display=2',hwdownload,format=nv12" -t 10 out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'histogram.zip=display=2' -i in.png -o out.png
```

## Notes

Approximation of FFmpeg's `histogram` filter (vf_histogram.c), `levels` mode. Two passes. A histogram cannot be read from mip levels, and a pixel of the output cannot afford to count the whole picture, so pass 1 has one thread per table entry (256 bins x 4 components) that counts a grid of `samples` x `samples` input pixels and writes the result (16 bits in two 8-bit channels) into a texel of the output-sized intermediate texture; pass 2 draws the bars from the table. The scope has the size of the input (FFmpeg's own output size, scale and graticule options are not ported). Under 1024 pixels in the picture the number of bins drops to a quarter of the pixel count. Differences: only the levels display of FFmpeg (no waveform/color/color2/color3/color4 modes, no parade of other formats), 256 bins always, bars are estimated from the sample grid (small noise on tiny bins), no graticule.

It replaces the picture: with `opacity` 1 the input is not visible.
