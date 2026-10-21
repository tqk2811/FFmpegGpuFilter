# LUT YUV

Look-up by expression on the luma and chroma channels (BT.709 full range), plus alpha.

Approximation of FFmpeg's `lutyuv` (`libavfilter/vf_lut.c`).

## Inputs

- `src`: any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `lutyuv.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. Parameters of type `expr` are GPU expressions (api 2, see [Expression parameters](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md#expression-parameters)): numbers, the listed variables, `pi`, `tau`, `e`, `+ - * / ^`, and the functions `sin cos tan asin acos atan atan2 abs sign min max clamp mix step smoothstep pow sqrt exp log floor ceil round fract` only (no `if`, `gt`, `lt`, `mod`: use `step`, `mix`, `fract`); commas inside an FFmpeg command line are escaped as `\,`. The other values are literals or FFmpeg expressions in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `y` | expr | `clipval` | - | Luma result for the input value `val`, 0..255 |
| `u` | expr | `clipval` | - | Blue-difference chroma result for `val`, 0..255 (128 = neutral) |
| `v` | expr | `clipval` | - | Red-difference chroma result for `val`, 0..255 (128 = neutral) |
| `a` | expr | `clipval` | - | Alpha result for `val`, 0..255 |

## Differences from FFmpeg

- FFmpeg's `lutyuv` edits the planes of a YUV frame as they are stored. gpufx shaders see RGB, so the pixel is converted to YUV with BT.709 full range coefficients, the expressions run, and the result is converted back. A video in limited range or BT.601 therefore gets slightly different values than FFmpeg: `minval` is 0 and `maxval` 255 (FFmpeg uses 16/235 for luma and 16/240 for chroma on limited range input), and chroma is evaluated per pixel instead of at subsampled resolution.
- Variables: `val`, `maxval` (255), `minval` (0), `negval` (`maxval+minval-val`), `clipval` (`val` clipped to `minval..maxval`), `w`, `h`. Results are truncated and clipped to 0..255.
- Chroma 128 is neutral. A `u`/`v` result is not clipped to the RGB gamut: out-of-gamut colors are clamped per channel after the conversion back.
- No `gammaval`, `c0`..`c3`, `r`/`g`/`b` options (use `lutrgb`).

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='lutyuv.zip=y=clamp(val*1.1\,0\,255)&u=val&v=128+(val-128)*1.3',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).
