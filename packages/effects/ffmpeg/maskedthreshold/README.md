# Masked Threshold

Port of FFmpeg's maskedthreshold filter: pick source or reference pixels by comparing their difference with a threshold.

## Differences from FFmpeg

`threshold` is on the 0..255 scale whatever the bit depth (FFmpeg uses the native range, up to 65535). `mode` is an integer (0 = abs, 1 = diff) instead of the named constants. `planes` selects R, G, B, A instead of the YUV planes.

## Inputs

- `source`: Source clip
- `reference`: Reference clip (same size as the source)

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

- `threshold` (float, default 1, 0..255): Threshold on the 0..255 (8-bit) scale
- `planes` (int, default 15, 0..15): Bit mask of the channels to filter (1 = R, 2 = G, 4 = B, 8 = A); the others are copied from the first input
- `mode` (int, default 0, 0..1): 0 = abs (|source - reference| <= threshold keeps the source, else the reference), 1 = diff (reference - source <= threshold gives max(reference - threshold, 0), else the source)

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in0.mp4 -i in1.mp4 -filter_complex \
  "[0][1]gpufx=graph='maskedthreshold.zip',hwdownload,format=yuv420p" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI:

```sh
gpufx run 'maskedthreshold.zip' -i in0.png -i in1.png -o out.png
```
