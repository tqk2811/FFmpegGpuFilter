# Extract Planes

Port of FFmpeg's extractplanes filter: output one plane or channel (y, u, v, r, g, b, a) as a gray picture.

## Differences from FFmpeg

FFmpeg's `planes` option (a `+`-separated list) produces one gray output per plane; an effect has a single output, so `plane` chooses one plane (use several effects for several planes). Y, U and V are computed from RGB (BT.709, full range) at full resolution (FFmpeg's U and V planes are subsampled on 4:2:0 input). The output is opaque gray.

## Inputs

- `src`: Input clip

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

- `plane` (int, default 0, 0..6): Plane to extract: 0 = y, 1 = u, 2 = v, 3 = r, 4 = g, 5 = b, 6 = a

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in0.mp4 -filter_complex \
  "[0]gpufx=graph='extractplanes.zip',hwdownload,format=yuv420p" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI:

```sh
gpufx run 'extractplanes.zip' -i in0.png -o out.png
```
