# Shuffle Planes

Port of FFmpeg's shuffleplanes filter: reorder or duplicate the color channels (R, G, B, A).

## Differences from FFmpeg

FFmpeg's `map0`..`map3` pick the source plane of each output plane of the frame (Y, U, V, A for YUV; G, B, R, A for planar RGB). Shaders always see RGBA, so here `map0`..`map3` pick the source channel (0 = R, 1 = G, 2 = B, 3 = A) of the output R, G, B and A. Shuffling Y/U/V planes of a YUV clip is therefore not possible; use the `swapuv` effect for the U/V swap.

Note: the indexes are RGBA channels of the picture the effect sees, not FFmpeg plane indexes. For example `map0=1` selects the G channel, which in FFmpeg would mean plane 1 (U for a YUV frame).

## Inputs

- `src`: Input clip

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

- `map0` (int, default 0, 0..3): Source channel (0 = R, 1 = G, 2 = B, 3 = A) of the output R channel
- `map1` (int, default 1, 0..3): Source channel of the output G channel
- `map2` (int, default 2, 0..3): Source channel of the output B channel
- `map3` (int, default 3, 0..3): Source channel of the output A channel

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in0.mp4 -filter_complex \
  "[0]gpufx=graph='shuffleplanes.zip',hwdownload,format=yuv420p" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI:

```sh
gpufx run 'shuffleplanes.zip' -i in0.png -o out.png
```
