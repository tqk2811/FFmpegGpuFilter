# Masked Clamp

Port of FFmpeg's maskedclamp filter: clamp the base clip between the dark and bright clips.

## Differences from FFmpeg

`undershoot` and `overshoot` are on the 0..255 scale whatever the bit depth (FFmpeg uses the native range of the format, up to 65535). `planes` selects R, G, B, A instead of the YUV planes.

## Inputs

- `base`: Base clip
- `dark`: Lower bound clip (same size as the base)
- `bright`: Upper bound clip (same size as the base)

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

- `undershoot` (float, default 0, 0..255): How far below the dark clip the output may go, on the 0..255 (8-bit) scale
- `overshoot` (float, default 0, 0..255): How far above the bright clip the output may go, on the 0..255 scale
- `planes` (int, default 15, 0..15): Bit mask of the channels to filter (1 = R, 2 = G, 4 = B, 8 = A); the others are copied from the first input

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in0.mp4 -i in1.mp4 -i in2.mp4 -filter_complex \
  "[0][1][2]gpufx=graph='maskedclamp.zip',hwdownload,format=yuv420p" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI:

```sh
gpufx run 'maskedclamp.zip' -i in0.png -i in1.png -i in2.png -o out.png
```
