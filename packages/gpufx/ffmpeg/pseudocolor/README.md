# Pseudocolor

Maps the luma of the picture to a color palette (magma, viridis, turbo...) or marks luma ranges.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `pseudocolor.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `preset` | int | `3` | -1 to 20 | Preset: -1 = none (unchanged), 0 = magma, 1 = inferno, 2 = plasma, 3 = viridis, 4 = turbo, 5 = cividis, 6 = range1, 7 = range2, 8 = shadows, 9 = highlights, 10 = solar, 11 = nominal, 12 = preferred, 13 = total, 14 = spectral, 15 = cool, 16 = heat, 17 = fiery, 18 = blues, 19 = green, 20 = helix |
| `opacity` | float | `1` | 0 to 1 | Opacity of the false color over the picture |


Port of FFmpeg's `pseudocolor` presets (all 21). The palettes are FFmpeg's polynomials; the `range1`, `range2`, `shadows`, `highlights`, `nominal`, `preferred` and `total` presets paint the luma ranges that FFmpeg marks (purple for the darkest, red for the brightest...).

Differences: FFmpeg's `c0` to `c3` expressions and the `index` option are not ported. The palette is picked by the BT.709 luma of the RGB value rounded to 8 bits (FFmpeg uses the plane given by `index`, the Y plane by default for YUV input and the G plane for RGB input).

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='pseudocolor.zip=preset=4&opacity=0.8',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='pseudocolor.zip=preset=4&opacity=0.8',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'pseudocolor.zip=preset=1' -i in.png -o out.png
```
