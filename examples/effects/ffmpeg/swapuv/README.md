# Swap UV

Port of FFmpeg's swapuv filter: swap the U and V planes (the color difference channels).

## Differences from FFmpeg

FFmpeg swaps the U and V planes of a YUV frame. Shaders see RGBA, so the effect converts RGB to YUV (BT.709, full range), swaps U and V, and converts back; this gives the same colors as the plane swap on full-range BT.709 video. Alpha is kept.

Caveat: the RGB to YUV to RGB round trip clips saturated colors (U and V results outside the RGB gamut are clamped), whereas FFmpeg's plane swap is lossless. It also assumes full-range BT.709; other matrices or limited range give different colors than FFmpeg.

## Inputs

- `src`: Input clip

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

None.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in0.mp4 -filter_complex \
  "[0]gpufx=graph='swapuv.zip',hwdownload,format=yuv420p" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI:

```sh
gpufx run 'swapuv.zip' -i in0.png -o out.png
```
