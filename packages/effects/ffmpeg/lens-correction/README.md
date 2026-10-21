# Lens Correction

Corrects or adds radial lens distortion (barrel/pincushion) around a center point.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `lens-correction.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `cx` | float | `0.5` | 0 to 1 | Relative x of the distortion center, 0..1 of the width |
| `cy` | float | `0.5` | 0 to 1 | Relative y of the distortion center, 0..1 of the height |
| `k1` | float | `0` | -1 to 1 | Quadratic distortion factor |
| `k2` | float | `0` | -1 to 1 | Double quadratic distortion factor |
| `i` | int | `0` | 0 to 1 | Interpolation: 0 = nearest, 1 = bilinear |
| `fc` | color | `#00000000` | RGBA | Color of the pixels that map outside the source |

A `color` is `#rrggbb` or `#rrggbbaa`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='lens-correction.zip=k1=-0.2&k2=0.05',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='lens-correction.zip=k1=-0.2&k2=0.05',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on PNGs:

```sh
gpufx run 'lens-correction.zip=k1=-0.2:k2=0.05' -i in.png -o out.png
```

## Notes

Port of FFmpeg's `lenscorrection` filter. Differences: the correction is computed in floating point per pixel (FFmpeg uses a fixed-point table, so results can differ by a pixel); there is one set of coordinates for all channels (FFmpeg corrects chroma planes separately, at their own resolution); `fc` is an RGBA color and the unmapped pixels keep its alpha (the default is transparent black like FFmpeg's `black@0`). Positive `k1` pulls the outer area toward the center in the source, negative pushes it out.
