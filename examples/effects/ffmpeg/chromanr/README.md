# Chroma Noise Reduction

Port of FFmpeg's chromanr filter: reduce chrominance noise by averaging the chroma of similar neighbouring pixels.

## Differences from FFmpeg

FFmpeg works on the YUV planes at chroma resolution (the patch is in chroma pixels). Here Y, U and V are computed from RGB (BT.709, full range) at full resolution, so the patch is in image pixels; U and V are averaged and Y is kept. `sizew`/`sizeh` are capped at 16 and `stepw`/`steph` at 16 to bound the cost of one pass. Single pass, no frame history.

## Inputs

- `src`: Input clip

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

- `thres` (float, default 30, 1..200): Threshold on the Y+U+V distance, 0..255 scale
- `sizew` (int, default 5, 1..16): Horizontal patch radius in pixels (FFmpeg allows up to 100)
- `sizeh` (int, default 5, 1..16): Vertical patch radius in pixels (FFmpeg allows up to 100)
- `stepw` (int, default 1, 1..16): Horizontal step between compared pixels (FFmpeg allows up to 50)
- `steph` (int, default 1, 1..16): Vertical step between compared pixels (FFmpeg allows up to 50)
- `threy` (float, default 200, 1..200): Threshold on the Y difference, 0..255 scale
- `threu` (float, default 200, 1..200): Threshold on the U difference, 0..255 scale
- `threv` (float, default 200, 1..200): Threshold on the V difference, 0..255 scale
- `distance` (int, default 0, 0..1): Distance type: 0 = manhattan, 1 = euclidean

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in0.mp4 -filter_complex \
  "[0]gpufx=graph='chromanr.zip',hwdownload,format=yuv420p" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI:

```sh
gpufx run 'chromanr.zip' -i in0.png -o out.png
```
