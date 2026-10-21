# LUT RGB

Per-channel look-up by expression: each of red, green, blue and alpha is replaced by an expression of its own value.

Port of FFmpeg's `lutrgb` (`libavfilter/vf_lut.c`).

## Inputs

- `src`: any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `lutrgb.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. Parameters of type `expr` are GPU expressions (api 2, see [Expression parameters](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md#expression-parameters)): numbers, the listed variables, `pi`, `tau`, `e`, `+ - * / ^`, and the functions `sin cos tan asin acos atan atan2 abs sign min max clamp mix step smoothstep pow sqrt exp log floor ceil round fract` only (no `if`, `gt`, `lt`, `mod`: use `step`, `mix`, `fract`); commas inside an FFmpeg command line are escaped as `\,`. The other values are literals or FFmpeg expressions in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `r` | expr | `clipval` | - | Red result for the input value `val`, 0..255 |
| `g` | expr | `clipval` | - | Green result for `val`, 0..255 |
| `b` | expr | `clipval` | - | Blue result for `val`, 0..255 |
| `a` | expr | `clipval` | - | Alpha result for `val`, 0..255 |

## Differences from FFmpeg

- Works on 8-bit values (`val` 0..255, `maxval` 255, `minval` 0, `negval` = `maxval+minval-val`, `clipval` = `val` clipped to `minval..maxval`), like FFmpeg's `lutrgb` on 8-bit input; the result is truncated (plus a tiny epsilon against float noise) and clipped to 0..255.
- Evaluated per pixel on the GPU instead of building a 256-entry table; the picture is first quantized to 8 bits per channel, so a higher bit depth input is rounded to 8 bits for the look-up.
- FFmpeg's options `c0`..`c3` and `y`/`u`/`v` are not provided (`lutyuv` is a separate package); `w` and `h` are the frame size. FFmpeg's `gammaval(g)` is not available: use `pow`, e.g. gamma 2 is `255*pow(val/255,1/2)`. Comparison functions (`if`, `gt`...) are not available either; use `step`, `mix`.
- The default `clipval` leaves a channel unchanged.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='lutrgb.zip=r=negval&g=clipval&b=255*pow(val/255\,0.8)',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).
