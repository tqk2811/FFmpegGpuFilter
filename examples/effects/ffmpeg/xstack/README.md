# Grid Stack

Port of FFmpeg's `xstack` (the `grid` layout): places the inputs in a grid, row by row.

## Inputs

- `src0`, `src1`... : Videos to place in the grid, any sizes

The effect takes every input connected to its graph node, in order, 2 to 16 (like FFmpeg's `xstack`): `[0][1][2][3]xstack.zip[out]` makes a grid of four. Without input labels (`graph='xstack.zip'`) it takes four. Any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src0`): the frame is divided into the grid cells and each input is scaled (bilinear) into its cell. FFmpeg's `xstack` makes a frame as large as the placed inputs; gpufx effects only grow the output for `hstack`/`vstack` layouts, so this port shrinks the inputs instead. For a bigger frame, scale the first input up first. Pixel format: the first input's, when the effect may output it (the manifest has no `output.formats` rule).

## Options

Written inline after the package name: `xstack.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `columns` | int | `2` | 0 to 16 | Columns of the grid; the rows follow from the number of inputs (FFmpeg `grid=COLUMNSxROWS`). 0 = the square root of the number of inputs, rounded up |
| `fit` | bool | `false` | | Keep each input's aspect ratio inside its cell, with bars in the fill color, instead of stretching it to the cell |
| `fill` | color | `#000000` | RGBA | Fill for unused cells (when the inputs do not fill the last row) and for the bars of `fit` (FFmpeg `fill`) |

A `color` is `#rrggbb`.

## Example

Four videos in a 2x2 grid:

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -i c.mp4 -i d.mp4 -filter_complex \
  "[0][1][2][3]gpufx=graph='[0][1][2][3]xstack.zip=columns=2',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -i c.mp4 -i d.mp4 -filter_complex \
  "[0][1][2][3]gpufx=graph='[0][1][2][3]xstack.zip=columns=2',hwdownload,format=yuv420p" out.mp4
```

## Notes

Differences from FFmpeg:

- **Output size**: the first input's size, with the other inputs scaled into cells, see Output. FFmpeg's pixel-exact placement is not possible.
- **Not ported**: the custom `layout` string (arbitrary positions such as `0_0|w0_0`; it needs per-input offsets in pixels and a larger frame), `shortest` and `inputs` (the count comes from the graph labels).
- The cells of a grid have equal sizes (FFmpeg takes the size of each row's first input).
