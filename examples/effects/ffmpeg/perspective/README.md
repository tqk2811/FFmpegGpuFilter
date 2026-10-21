# Perspective

Corrects perspective by mapping four corner points (a quadrilateral to the full frame, or the frame to a quadrilateral).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `perspective.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `top_left` | vec2 | `0,0` | 0..1 | Point for the top left corner, 0..1 of the frame (FFmpeg x0, y0) |
| `top_right` | vec2 | `1,0` | 0..1 | Point for the top right corner, 0..1 of the frame (FFmpeg x1, y1) |
| `bottom_left` | vec2 | `0,1` | 0..1 | Point for the bottom left corner, 0..1 of the frame (FFmpeg x2, y2) |
| `bottom_right` | vec2 | `1,1` | 0..1 | Point for the bottom right corner, 0..1 of the frame (FFmpeg x3, y3) |
| `interpolation` | int | `0` | 0 to 1 | Interpolation: 0 = linear, 1 = cubic |
| `sense` | int | `0` | 0 to 1 | 0 = source (the points are locations in the source that go to the corners of the output), 1 = destination (the corners of the source go to the points in the output) |

A `vec2` is `x,y`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='perspective.zip=top_left=0.1,0.05&top_right=0.9,0&bottom_left=0,1&bottom_right=1,1',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='perspective.zip=top_left=0.1,0.05&top_right=0.9,0&bottom_left=0,1&bottom_right=1,1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on PNGs:

```sh
gpufx run 'perspective.zip=top_left=0.1,0.05:top_right=0.9,0:bottom_left=0,1:bottom_right=1,1' -i in.png -o out.png
```

## Notes

Port of FFmpeg's `perspective` filter. Differences: the corners are `vec2` parameters in 0..1 of the frame instead of pixel expressions `x0`..`y3` (multiply by `w`/`h` in an FFmpeg expression for pixels, for example `top_left=40/w,20/h`); there is no `eval` option, a parameter that is an expression is already evaluated per frame; interpolation is done in floating point on the GPU (FFmpeg uses 1/256 pixel steps (SUB_PIXEL_BITS 8) and integer weights). Pixels that map outside the source repeat the edge, as in FFmpeg.
