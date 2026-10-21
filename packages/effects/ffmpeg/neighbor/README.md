# Neighbor

Erosion, dilation, deflate and inflate over the 3x3 neighbourhood, limited by a threshold.

Port of FFmpeg's `erosion`, `dilation`, `deflate` and `inflate` (`vf_neighbor.c`).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `neighbor.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `mode` | int | `0` | 0 to 3 | 0 = erosion, 1 = dilation, 2 = deflate, 3 = inflate |
| `coordinates` | int | `255` | 0 to 255 | Erosion and dilation only: bit mask of the neighbours used; bit 0 = top-left, 1 = top, 2 = top-right, 3 = left, 4 = right, 5 = bottom-left, 6 = bottom, 7 = bottom-right |
| `threshold` | int | `255` | 0 to 255 | Largest change of a value, in 8-bit levels; 0 = unchanged (`threshold0`) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='neighbor.zip=mode=1&coordinates=90',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='neighbor.zip=mode=1&coordinates=90',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'neighbor.zip=mode=1&coordinates=90' -i in.png -o out.png
```

## Notes

One pass. Erosion takes the minimum and dilation the maximum of the pixel and the neighbours selected by `coordinates`, never moving the value by more than `threshold`. Deflate takes the lower of the pixel and the mean of its 8 neighbours, inflate the higher, also limited by `threshold` (they ignore `coordinates`, as in FFmpeg).

Differences from FFmpeg:

- One effect with a `mode` option replaces the four filters.
- One `threshold` for all channels (FFmpeg: `threshold0` to `threshold3` per plane), in 8-bit levels (FFmpeg's default 65535 acts as "no limit"; 255 is the same here). It applies to R, G, B channels; alpha is passed through.
- Columns beyond the picture mirror and rows repeat the edge, as FFmpeg does.
