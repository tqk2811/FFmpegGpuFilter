# Directional Blur

Gaussian blur along a straight line at a given angle.

Port of FFmpeg's `dblur`.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `directional-blur.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `angle` | float | `45` | 0 to 360 | Direction of the blur in degrees (0 = along +x, 90 = down the picture) |
| `radius` | float | `5` | 0 to 32 | Blur radius in pixels (the sigma of the gaussian) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='directional-blur.zip=angle=30&radius=10',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='directional-blur.zip=angle=30&radius=10',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'directional-blur.zip=angle=30&radius=10' -i in.png -o out.png
```

## Notes

One pass: bilinear samples every pixel along the line through the pixel, weighted by a gaussian with sigma = `radius` (up to 3 sigma on each side, so at most 193 taps).

Differences from FFmpeg:

- FFmpeg runs a recursive gaussian filter along the direction; this port samples the line directly, so `radius` is capped at 32 (FFmpeg allows 8192). The `planes` option is not ported (RGBA are blurred together).
- The angle is measured from +x towards +y of the picture (y points down); check against FFmpeg's `dblur` when the direction matters.
- Samples outside the picture repeat the edge pixel (the sampler clamps).
