# Draw Box

Draws a colored box (outline or filled) on the picture.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `draw-box.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `x` | int | `0` | -100000 to 100000 | Left edge of the box, in pixels |
| `y` | int | `0` | -100000 to 100000 | Top edge of the box, in pixels |
| `width` | int | `0` | 0 to 100000 | Width of the box in pixels; 0 = the width of the picture |
| `height` | int | `0` | 0 to 100000 | Height of the box in pixels; 0 = the height of the picture |
| `color` | color | `#000000` | RGBA | Color of the box; alpha is its opacity |
| `thickness` | int | `3` | 0 to 100000 | Thickness of the outline in pixels |
| `fill` | bool | `false` | 0 or 1 | Fill the whole box (FFmpeg: thickness `fill`) |
| `replace` | bool | `false` | 0 or 1 | Replace the color and alpha of the pixels instead of blending |
| `invert` | bool | `false` | 0 or 1 | Invert the color of the pixels of the box instead of drawing `color` (FFmpeg: color `invert`) |

A `color` is `#rrggbb` or `#rrggbbaa`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='draw-box.zip=x=100&y=50&width=300&height=200&color=#ff0000&thickness=4',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='draw-box.zip=x=100&y=50&width=300&height=200&color=#ff0000&thickness=4',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on PNGs:

```sh
gpufx run 'draw-box.zip=x=100:y=50:width=300:height=200:color=#ff0000:thickness=4' -i in.png -o out.png
```

## Notes

Port of FFmpeg's `drawbox` filter (`w`, `h`, `t` and `c` there are `width`, `height`, `thickness` and `color` here). Differences: `x`, `y`, `width`, `height` and `thickness` are plain parameters, so the FFmpeg expression variables `iw`/`ih` are written `w`/`h` here (for example `width=w/2`); `fill` and `invert` are separate options instead of special values of `thickness` and `color`; invert flips R, G and B (FFmpeg flips the luma of YUV); `box_source` (detection side data) is not supported. Without `replace` the color is blended by its alpha and the alpha of the picture is kept.
