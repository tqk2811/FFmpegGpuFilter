# Waveform

Waveform monitor of the luma or of R, G, B, per column or per row (scope).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU. It only sets the size (see Notes).

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `waveform.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `mode` | int | `0` | 0 to 1 | 0 column (levels up the picture, one waveform column per input column), 1 row (levels across, one trace row per input row) |
| `components` | int | `0` | 0 to 1 | 0 luma (BT.709) in white, 1 red, green and blue in their colors |
| `display` | int | `0` | 0 to 1 | With `components`=1: 0 overlay, 1 parade (the three components side by side or stacked) |
| `intensity` | float | `0.04` | 0.001 to 1 | Brightness added by one pixel on a 256-level scale (as FFmpeg), so ~25 equal pixels reach white |
| `max_samples` | int | `256` | 16 to 1024 | Samples per input line; lines longer than this are sampled at even steps, which bounds the work of each output pixel |
| `opacity` | float | `1` | 0 to 1 | Blend over the input picture: 1 = only the generated picture, 0 = the input unchanged |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -f lavfi -i color=black:s=1280x720:r=25 \
  -vf "format=nv12,gpufx=graph='waveform.zip=components=1&display=1',hwdownload,format=nv12" -t 10 out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'waveform.zip=components=1:display=1' -i in.png -o out.png
```

## Notes

Port of FFmpeg's `waveform` filter (vf_waveform.c), lowpass filter only. Every output pixel loops over the input column (or row) it shows, so the cost per pixel is at most `max_samples` loads. The scope has the size of the input (FFmpeg's own output size, scale and graticule options are not ported). Differences: only the lowpass filter (FFmpeg also has flat, aflat, chroma, color, acolor, xflat, yflat); no chroma components (U/V) or YUV-native analysis, since shaders see RGB; no graticule; the level axis has one row (or column) per output pixel, not 256 steps; hits are counted over at most `max_samples` evenly spread samples, scaled so the brightness stays the same. Cost is about output pixels x `max_samples` loads per frame. The brightness factor depends on the output size (along_size / 256, as FFmpeg scales by the line length), so the same `intensity` looks brighter or dimmer at other sizes.

It replaces the picture: with `opacity` 1 the input is not visible. Use the scope on a branch of a graph.
