# Noise

Adds gaussian or uniform noise, static or changing every frame.

Port of FFmpeg's `noise`.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `noise.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `strength` | int | `20` | 0 to 100 | Noise strength in 8-bit levels (`alls`); FFmpeg's default is 0 (no noise) |
| `seed` | int | `0` | 0 to 2147483647 | Seed of the noise (`all_seed`) |
| `temporal` | bool | `0` | 0 or 1 | 1 = the noise changes every frame (flag `t`), 0 = the same noise on every frame |
| `uniform` | bool | `0` | 0 or 1 | 1 = uniform noise (flag `u`), 0 = gaussian |
| `pattern` | bool | `0` | 0 or 1 | 1 = mix in a (semi)regular pattern (flag `p`) |
| `mono` | bool | `0` | 0 or 1 | 1 = the same noise on R, G and B (gray grain), 0 = independent per channel |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='noise.zip=strength=30&temporal=1',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='noise.zip=strength=30&temporal=1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'noise.zip=strength=30&temporal=1' -i in.png -o out.png
```

## Notes

One pass; the noise is a hash of the pixel position, the seed and, with `temporal=1`, the frame number of the filter (`globals.frame`, which restarts on a seek, so a seek changes the noise of a temporal grain; for a seed that follows the time of the clip drive `seed` with an expression in `t`). Gaussian noise has the standard deviation `strength / sqrt(3)` levels and uniform noise spans `strength` levels, as in FFmpeg.

Differences from FFmpeg:

- The noise is computed per pixel from a hash instead of read from a precomputed table, so it differs from FFmpeg's for the same seed. `seed` starts at 0 (no random seed of -1).
- The averaged flag (`a`) is not ported. Noise is added to R, G and B (independent, or equal with `mono=1`) instead of per YUV plane; `c0`..`c3` options are replaced by one `strength`. The alpha channel is passed through unchanged.
- The default `strength` is 20 where FFmpeg's is 0.
