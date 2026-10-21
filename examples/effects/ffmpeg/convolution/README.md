# Convolution

Convolution with a 3x3 matrix, a divisor and a bias.

Port of FFmpeg's `convolution`.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `convolution.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `m0` | float | `0` | -1000 to 1000 | Matrix, row 1 column 1 (top left) |
| `m1` | float | `0` | -1000 to 1000 | Matrix, row 1 column 2 |
| `m2` | float | `0` | -1000 to 1000 | Matrix, row 1 column 3 |
| `m3` | float | `0` | -1000 to 1000 | Matrix, row 2 column 1 |
| `m4` | float | `1` | -1000 to 1000 | Matrix, row 2 column 2 (centre) |
| `m5` | float | `0` | -1000 to 1000 | Matrix, row 2 column 3 |
| `m6` | float | `0` | -1000 to 1000 | Matrix, row 3 column 1 |
| `m7` | float | `0` | -1000 to 1000 | Matrix, row 3 column 2 |
| `m8` | float | `0` | -1000 to 1000 | Matrix, row 3 column 3 (bottom right) |
| `rdiv` | float | `0` | 0 to 65535 | Multiplier of the sum; 0 = 1 / (sum of the matrix), or 1 when that sum is 0 (`0rdiv`) |
| `bias` | float | `0` | 0 to 1020 | Value added to the result, in 8-bit levels (`0bias`) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='convolution.zip=m0=0&m1=-1&m2=0&m3=-1&m4=5&m5=-1&m6=0&m7=-1&m8=0',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='convolution.zip=m0=0&m1=-1&m2=0&m3=-1&m4=5&m5=-1&m6=0&m7=-1&m8=0',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'convolution.zip=m0=0&m1=-1&m2=0&m3=-1&m4=5&m5=-1&m6=0&m7=-1&m8=0' -i in.png -o out.png
```

## Notes

One pass; the matrix is row by row, `m0 m1 m2 / m3 m4 m5 / m6 m7 m8`. Identity is the default (`m4=1`). A sharpen is `m1=-1&m3=-1&m4=5&m5=-1&m7=-1`, a blur is all nine set to 1 (`rdiv` stays 0, so the sum divides it).

Differences from FFmpeg:

- Only the 3x3 `square` mode is ported (FFmpeg's `row` and `column` modes take up to 49 values); the matrix is nine float options instead of a space-separated string, and one matrix applies to R, G and B instead of one per plane (`planes`, `1m`..`3m`, `1rdiv`.. are not ported).
- The alpha channel is passed through unchanged. The sum is not rounded to integers before `rdiv` as in FFmpeg. Pixels outside the picture repeat the edge pixel.
