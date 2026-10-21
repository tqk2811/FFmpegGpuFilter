# YAEP Blur

Yet another edge preserving blur: flat areas are averaged, high-variance areas keep their value.

Port of FFmpeg's `yaepblur` (yet another edge preserving blur, after J. S. Lee, 1980).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `yaepblur.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `radius` | int | `3` | 0 to 16 | Window radius in pixels; 0 = off (`r`) |
| `sigma` | int | `128` | 1 to 100000 | Blur strength: a window variance well below it is averaged, well above it is kept (`s`) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='yaepblur.zip=radius=5&sigma=200',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='yaepblur.zip=radius=5&sigma=200',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'yaepblur.zip=radius=5&sigma=200' -i in.png -o out.png
```

## Notes

One pass. Per channel, on 8-bit levels, over the (2 * radius + 1)^2 window clipped at the picture edges: `mean` and `var` of the window, then `(sigma * mean + var * value) / (sigma + var)`. Flat areas (`var` << `sigma`) become the window mean, textured areas and edges (`var` >> `sigma`) keep their value. FFmpeg builds summed-area tables; the shader sums the window directly, so the cost grows with `radius` squared (capped at 16).

Differences from FFmpeg:

- Applied to R, G, B channels instead of the planes of the pixel format (`planes`, default luma only, is not ported); alpha is passed through.
- `radius` is capped at 16 and `sigma` at 100000; FFmpeg's `radius` has no upper limit (except half of the smaller side, kept here).
- The variance uses 32-bit float for `sum * sum / count`, FFmpeg 64-bit integers; results can differ by one level in rare cases.
