# Deband

Removes banding by averaging four pseudo-random neighbours when they are close to the pixel.

Port of FFmpeg's `deband`.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `deband.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `threshold` | float | `0.02` | 0.00003 to 0.5 | Difference (0..1 of full range) below which a pixel counts as banding (`1thr`..`3thr`) |
| `range` | int | `16` | -4096 to 4096 | Distance in pixels of the reference points (`r`); a positive value is the maximum (random per pixel), a negative one the exact distance |
| `direction` | float | `6.283185307` | -6.283185307 to 6.283185307 | Direction of the reference points in radians (`d`); a positive value is the maximum (random per pixel), a negative one the exact angle |
| `blur` | bool | `1` | 0 or 1 | 1 = compare the average of the four points with the pixel, 0 = compare each point (`b`) |
| `coupling` | bool | `0` | 0 or 1 | 1 = all of R, G, B must pass for the pixel to change (`c`) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='deband.zip=threshold=0.03&range=24',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='deband.zip=threshold=0.03&range=24',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'deband.zip=threshold=0.03&range=24' -i in.png -o out.png
```

## Notes

One pass. Each pixel gets its own offset from a hash of its position, as in FFmpeg (`frand`), so the result is the same for every frame of a still picture.

Differences from FFmpeg:

- One `threshold` for R, G and B instead of `1thr`..`4thr` per YUV plane; the comparison is done on RGB. The alpha channel is passed through unchanged.
- The hash uses a float `sin` as FFmpeg does, so the offsets can differ by a pixel on some GPUs. The random pattern uses `sin` of large arguments, so it can differ between GPUs/backends, not just from FFmpeg.
- The related `gradfun` filter is a separate effect (`gradfun`): it fits a smooth gradient instead of averaging four points.
