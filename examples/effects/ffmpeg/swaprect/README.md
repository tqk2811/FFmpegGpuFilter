# Swap Rectangles

Port of FFmpeg's `swaprect`: swaps two rectangles of the frame.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `swaprect.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `w` | float | `0.5` | 0 to 1 | Rectangle width, as a fraction of the frame width (FFmpeg `w`, default `w/2`) |
| `h` | float | `0.5` | 0 to 1 | Rectangle height, as a fraction of the frame height (FFmpeg `h`, default `h/2`) |
| `x1` | float | `0.5` | 0 to 1 | First rectangle, left edge as a fraction of the frame width (FFmpeg `x1`, default `w/2`) |
| `y1` | float | `0.5` | 0 to 1 | First rectangle, top edge as a fraction of the frame height (FFmpeg `y1`, default `h/2`) |
| `x2` | float | `0` | 0 to 1 | Second rectangle, left edge (FFmpeg `x2`, default 0) |
| `y2` | float | `0` | 0 to 1 | Second rectangle, top edge (FFmpeg `y2`, default 0) |

The defaults swap the top left and the bottom right quarters.

## Example

Swap the left and right quarters of the frame:

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='swaprect.zip=w=0.25&h=1&x1=0&y1=0&x2=0.75&y2=0',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='swaprect.zip=w=0.25&h=1&x1=0&y1=0&x2=0.75&y2=0',hwdownload,format=nv12" out.mp4
```

## Notes

Differences from FFmpeg:

- **Fractions instead of pixels**: the six values are fractions of the frame (a pixel expression such as `w/4` is `0.25` here, or `w=1/4`), turned into whole pixels by truncation like FFmpeg does. The result is the same as FFmpeg's for the same pixel values.
- Like FFmpeg, nothing is swapped when the rectangle (after the position is clamped into the frame) does not fit at both places.
- Overlapping rectangles: FFmpeg swaps them row by row in memory, which gives a smeared result. Here the first rectangle wins in the overlap.
