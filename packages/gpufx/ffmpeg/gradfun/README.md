# Gradfun

Debanding that fits a smooth gradient to flat areas and dithers the result.

Port of FFmpeg's `gradfun`.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `gradfun.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `strength` | float | `1.2` | 0.51 to 64 | Maximum amount by which a pixel changes, in 8-bit levels |
| `radius` | int | `16` | 4 to 32 | Size of the neighbourhood the gradient is fitted to |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='gradfun.zip=strength=1.5&radius=24',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='gradfun.zip=strength=1.5&radius=24',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'gradfun.zip=strength=1.5&radius=24' -i in.png -o out.png
```

## Notes

One pass: an r x r box average in float (r = radius rounded down to even, as in FFmpeg), so the cost is O(r^2) per pixel. A pixel near the local average is pulled to it, with a weight that falls to 0 at `strength` levels; the same 8x8 ordered dither as FFmpeg is added.

Differences from FFmpeg:

- FFmpeg averages 2x2 blocks into a half resolution buffer; this port averages the full-resolution r x r box directly (r = radius rounded down to even, offsets -r/2 .. r/2-1).
- The filter runs on R, G and B instead of the YUV planes. The alpha channel is passed through unchanged.
- The dither is centred (about half a level is subtracted) because the shader output is rounded to a level and FFmpeg's is truncated.
- gradfun and `deband` are separate effects: they share the goal but not the method (gradient fit with dither versus random-point averaging).
