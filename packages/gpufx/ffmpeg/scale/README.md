# Scale

Resizes the picture with bilinear sampling. The width and height follow the rules of FFmpeg's `scale` filter.

## Inputs

- `src`: the video to resize. Any pixel format that gpufx converts on the GPU.

## Output

The size given by `w` and `h`:

- A positive value is that many pixels.
- `0` is the input's width (or height).
- `-n` is computed from the other side, keeping the input's aspect ratio, and rounded to a multiple of `n`: `-1` does not round, `-2` gives an even number.
- Both negative: the input's size.

The size is computed once, when the filter is configured. Changing `w` or `h` later in a way that changes the size is an error. The output must fit the GPU's largest texture side.

## Options

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `w` | int | -1 | Output width |
| `h` | int | -1 | Output height |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 -vf \
  "hwupload,gpufx=graph='scale.zip=1280&-2',hwdownload,format=yuv420p" out.mp4
```

`scale.zip=1280&-2` is the same as `scale.zip=w=1280&h=-2`: values without a name take the params in order.

## Notes

The output differs in size from the input, so the filter's `enable=` option cannot be used with it.
