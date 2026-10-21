# Masked Min/Max

Port of FFmpeg's `maskedmin` and `maskedmax` filters: per channel, take the pixel of `filter1` or `filter2` that is closest to (`maskedmin`) or farthest from (`maskedmax`) the source pixel. `maskedmin` picks `filter2` where `|source - filter2| < |source - filter1|`, `maskedmax` where it is greater, otherwise `filter1`.

FFmpeg compares each YUV plane separately; gpufx works on RGB, so each RGB channel is compared on its own. The output alpha is the alpha of the source.

## Inputs

- `source`: Source clip the other two are compared with
- `filter1`: First filter clip (must have the same size as the source)
- `filter2`: Second filter clip (must have the same size as the source)

## Output

Same size as the first input (`source`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `masked-minmax.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `mode` | int | `0` | 0 to 1 | 0 = maskedmin (closest to the source), 1 = maskedmax (farthest from the source) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i src.mp4 -i f1.mp4 -i f2.mp4 -filter_complex \
  "[0][1][2]gpufx=graph='masked-minmax.zip=mode=1',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i src.mp4 -i f1.mp4 -i f2.mp4 -filter_complex \
  "[0][1][2]gpufx=graph='masked-minmax.zip=mode=1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on three PNGs:

```sh
gpufx run 'masked-minmax.zip=mode=1' -i src.png -i f1.png -i f2.png -o out.png
```
