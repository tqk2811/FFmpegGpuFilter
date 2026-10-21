# Shape Adaptive Blur

Edge preserving blur: neighbours weigh by distance and by their difference after a gaussian pre-filter.

Port of FFmpeg's `sab` (shape adaptive blur).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `sab.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `luma_radius` | float | `1` | 0.1 to 4 | Blur radius (`lr`) |
| `luma_pre_filter_radius` | float | `1` | 0.1 to 2 | Radius of the pre-filter that decides which neighbours look alike (`lpfr`) |
| `luma_strength` | float | `1` | 0.1 to 100 | Tolerance to value differences, in 8-bit levels: low keeps edges, high blurs across them (`ls`) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='sab.zip=luma_radius=2&luma_strength=10',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='sab.zip=luma_radius=2&luma_strength=10',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'sab.zip=luma_radius=2&luma_strength=10' -i in.png -o out.png
```

## Notes

Two passes: (1) a gaussian pre-filter of each channel (`luma_pre_filter_radius`, FFmpeg's swscale gaussian vector of length `(int)(radius * 3 + 0.5) | 1`), stored as 8-bit like FFmpeg; (2) a blur of the source where each neighbour in the window is weighted by a gaussian of its distance (`luma_radius`) times a gaussian of the difference between the pre-filtered values of the neighbour and of the centre (`luma_strength`, 8-bit levels; differences beyond `(int)(strength * 5 + 0.5) | 1) / 2` weigh 0 as in FFmpeg). Window mirror at the edges.

Differences from FFmpeg:

- Applied to R, G, B channels, each with its own pre-filtered value, instead of luma and chroma planes; the `chroma_*` options are not ported (they default to the luma ones in FFmpeg). Alpha is passed through.
- Weights are floating point instead of the 12-bit and 10-bit integer coefficients of FFmpeg, so results can differ by one level.
- The pre-filter is one 2D pass with clamped edges (swscale's edge handling may differ slightly).
