# Vectorscope

Chroma vectorscope: Cb/Cr density plot (scope).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU. It only sets the size (see Notes).

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `vectorscope.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `intensity` | float | `0.004` | 0.0001 to 1 | Brightness added by one pixel (of 1), as FFmpeg's `intensity`; 250 pixels in a cell reach white |
| `samples` | int | `128` | 8 to 256 | The plot is taken from a grid of samples x samples input pixels (bounded cost; 128 gives 16384 samples per cell) |
| `color_mode` | bool | `false` |  | Tint the plot with the chroma color of its position (false: white) |
| `graticule` | bool | `true` |  | Draw a crosshair and a circle |
| `opacity` | float | `1` | 0 to 1 | Blend over the input picture: 1 = only the generated picture, 0 = the input unchanged |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -f lavfi -i color=black:s=1280x720:r=25 \
  -vf "format=nv12,gpufx=graph='vectorscope.zip=color_mode=1',hwdownload,format=nv12" -t 10 out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'vectorscope.zip=color_mode=1' -i in.png -o out.png
```

## Notes

Approximation of FFmpeg's `vectorscope` filter (vf_vectorscope.c), `color`/`gray` modes with a Cb/Cr plot. A vectorscope scatters every input pixel to its (Cb, Cr) place; a shader cannot add into a texture, so this gathers instead. Pass 1 has 256 x 256 threads, one per Cb/Cr cell, each walking a grid of `samples` x `samples` input pixels and counting the ones that fall in its cell (cost 65536 x samples^2 loads, independent of the picture size, about 1G loads at the default); the count is scaled to the full picture so `intensity` means what it does in FFmpeg. Pass 2 draws the 256 x 256 table as a square in the middle of the output (nearest neighbour). The scope has the size of the input (FFmpeg's own output size, scale and graticule options are not ported). The 256 x 256 table is stored in the intermediate texture in reading order, so a picture under 65536 pixels gets a coarser grid (the side of the square root of its pixel count). Differences: BT.709 Cb/Cr of the RGB picture (FFmpeg reads the YUV planes of the source); only a single density plot (no color/color2..5 modes, no envelope, tint0/tint1, x/y axis choice or colorspace options), a simple graticule (no skin-tone line or color targets); sparse images look speckled when `samples` is low.

It replaces the picture: with `opacity` 1 the input is not visible.
