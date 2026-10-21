# Threshold

Port of FFmpeg's threshold filter: per channel, output the min clip where the input is at or below the threshold clip, otherwise the max clip.

## Differences from FFmpeg

`planes` selects R, G, B, A instead of the YUV planes. The comparison is done on the RGBA channels, not on the Y/U/V planes of the source video.

## Inputs

- `src`: Input clip
- `threshold`: Threshold clip (same size as the input)
- `min`: Clip used where the input is at or below the threshold (same size)
- `max`: Clip used where the input is above the threshold (same size)

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

- `planes` (int, default 15, 0..15): Bit mask of the channels to filter (1 = R, 2 = G, 4 = B, 8 = A); the others are copied from the first input

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in0.mp4 -i in1.mp4 -i in2.mp4 -i in3.mp4 -filter_complex \
  "[0][1][2][3]gpufx=graph='threshold.zip',hwdownload,format=yuv420p" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI:

```sh
gpufx run 'threshold.zip' -i in0.png -i in1.png -i in2.png -i in3.png -o out.png
```
