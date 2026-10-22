# Vertical Stack

Places the inputs one above the other, top to bottom, like FFmpeg's `vstack`.

## Inputs

- `src0`, `src1`... : Videos to stack, all of the same width

The effect takes every input connected to its graph node, in order, 2 to 16 (like FFmpeg's `vstack`): `[0][1][2]vstack.zip[out]` stacks three. Without input labels (`graph='vstack.zip'`) it takes two. Every input must have the width of the first; another width is an error when the filter is configured. Any pixel format that gpufx converts on the GPU.

## Output

Height = the sum of the input heights, width = the inputs' width. It must fit the GPU's largest texture side (8192 or more on desktop GPUs); a taller output is an error. Pixel format: the first input's when the GPU converter can write it, else `rgba`; `out_format` overrides. Frame rate and aspect ratio come from the first input.

## Options

None. The number of inputs is the number of labels the node reads; it is not an option.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -i c.mp4 -filter_complex \
  "[0][1][2]gpufx=graph='[0][1][2]vstack.zip',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='vstack.zip',hwdownload,format=nv12" out.mp4
```

Inside a graph, the stacked frame is what the next effect sees, e.g. `[0][1]vstack.zip[s]; [s]vignette.zip[out]`.

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

## Notes

Pixels are copied, not resampled. Scale the inputs to one width first (e.g. with `scale=1280:-2`) when they differ. Like every gpufx input after the first, an input that has not started yet shows black, and the output ends with the first input.

The output is larger than the first input, so the filter's `enable=` option cannot be used with it: a disabled frame passes the first input through, which no longer has the output size, and the filter stops with an error.
