# Color Correct

Shifts the chroma of the shadows and highlights toward blue/red and scales the saturation.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `colorcorrect.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `rl` | float | `0` | -1 to 1 | Shadow red shift |
| `bl` | float | `0` | -1 to 1 | Shadow blue shift |
| `rh` | float | `0` | -1 to 1 | Highlight red shift |
| `bh` | float | `0` | -1 to 1 | Highlight blue shift |
| `saturation` | float | `1` | -3 to 3 | Saturation (chroma scale) |

Port of FFmpeg's `colorcorrect` (manual mode). The option names, defaults and ranges are FFmpeg's. FFmpeg edits the U and V planes of a YUV frame as `sat * (c + y * (high - low) + low)`; here the RGB pixel is converted to full-range BT.709 Y/U/V, the same formula is applied to U and V and the result is converted back. Differences: the `analyze` option (average, minmax, median of the frame chroma) is not ported because it needs a whole-frame reduction, so only the manual mode exists; FFmpeg uses the Y of the file's own range and matrix, here it is always full-range BT.709 luma.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorcorrect.zip=rl=0.1&bh=-0.1&saturation=1.2',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorcorrect.zip=rl=0.1&bh=-0.1&saturation=1.2',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'colorcorrect.zip=rl=0.1:bh=-0.1:saturation=1.2' -i in.png -o out.png
```
