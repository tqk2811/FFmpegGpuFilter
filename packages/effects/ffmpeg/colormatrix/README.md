# Color Matrix

Converts the colors between the YUV color matrices BT.709, FCC, BT.601, SMPTE 240M and BT.2020.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `colormatrix.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `src` | int | `2` | 0 to 4 | Source matrix: 0 bt709, 1 fcc, 2 bt601 (bt470, bt470bg, smpte170m), 3 smpte240m, 4 bt2020 |
| `dst` | int | `0` | 0 to 4 | Destination matrix, same numbering as `src` |

Port of FFmpeg's `colormatrix`. The option names and the numbering of the matrices are FFmpeg's, as are the luma coefficient tables. FFmpeg multiplies the U and V of a YUV frame by `YUV(dst) * RGB(src)`. This effect gets RGB, so it assumes the pipeline encoded the picture as BT.709 YUV, applies the same matrix pair in YUV and goes back to RGB (`RGB709 * YUV(dst) * RGB(src) * YUV709`). Differences: `src` and `dst` default to bt601 and bt709 instead of FFmpeg's required `dst` and auto `src` (the effect does not see the frame's colorspace tag), and take numbers, not names; `src == dst` is the identity instead of an error; FFmpeg works on integers with a 16-bit fixed-point matrix, this on floats. Results match FFmpeg only when the video is BT.709 in the pipeline.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colormatrix.zip=src=2&dst=0',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colormatrix.zip=src=2&dst=0',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'colormatrix.zip=src=2:dst=0' -i in.png -o out.png
```
