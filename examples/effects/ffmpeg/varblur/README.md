# Variable Blur

Box blur whose radius varies per pixel and channel with the brightness of a radius map (second input).

Port of FFmpeg's `varblur` (variable box blur driven by a radius map).

## Inputs

- `src`: Picture to blur.
- `radius`: Radius map; must have the size of `src`. Its R, G and B channels set the radius of the matching channel of `src` (a gray map blurs all alike).

Any pixel format that gpufx converts on the GPU. `radius` must have the size of `src` (the error names the input otherwise).

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `varblur.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `min_r` | int | `0` | 0 to 7 | Minimum blur radius, used where the map is black |
| `max_r` | int | `8` | 1 to 8 | Maximum blur radius, used where the map is white (raised to min_r + 1 when not above min_r) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 -i radius.mp4 \
  -filter_complex "[0:v]format=nv12[a];[1:v]format=nv12[b];[a][b]gpufx=graph='varblur.zip=max_r=6',hwdownload,format=nv12" out.mp4
```

With the `gpufx` CLI the inputs are given in order with repeated `-i`.

## Notes

One pass. The radius at a pixel is `2 * min_r + 1 + max(0, 2 * map + 1 - (2 * min_r + 1)) * ((2 * max_r + 1) - (2 * min_r + 1)) / 255` (`map` in 0..255), and the output is the box average of radius `floor(radius)` blended with the one of `floor(radius) + 1` by the fraction. This follows FFmpeg's formula exactly, which makes the box about twice as wide as `max_r` suggests (box `[x - l, x + r) x [y - t, y + b)`, `l = min(radius, x)`...). FFmpeg uses a summed-area table; the shader sums the box directly, so a large radius is slow on big frames.

Differences from FFmpeg:

- `max_r` is capped at 8 (FFmpeg 255) and `min_r` at 7 because of that cost; at the cap the box reaches about 68 pixels.
- Applied to R, G, B channels instead of the planes of the pixel format (`planes` is not ported); alpha is passed through. A missing radius frame (FFmpeg passes the picture through) is not possible here: both inputs are required.
