# Fill Borders

Fills the borders of the picture by smearing, mirroring, reflecting, wrapping, fading or with a fixed color.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `fill-borders.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `left` | int | `0` | 0 to 16384 | Width of the left border in pixels |
| `right` | int | `0` | 0 to 16384 | Width of the right border in pixels |
| `top` | int | `0` | 0 to 16384 | Height of the top border in pixels |
| `bottom` | int | `0` | 0 to 16384 | Height of the bottom border in pixels |
| `mode` | int | `0` | 0 to 5 | 0 = smear, 1 = mirror, 2 = fixed, 3 = reflect, 4 = wrap, 5 = fade |
| `color` | color | `#000000` | RGBA | Color for the fixed and fade modes |

A `color` is `#rrggbb` or `#rrggbbaa`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='fill-borders.zip=left=40&right=40&mode=1',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='fill-borders.zip=left=40&right=40&mode=1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on PNGs:

```sh
gpufx run 'fill-borders.zip=left=40:right=40:mode=1' -i in.png -o out.png
```

## Notes

Port of FFmpeg's `fillborders` filter. Differences: the `margins` mode is not ported (it needs the previous row of the result, which a per-pixel shader does not have); border sizes are pixels of the full picture (FFmpeg halves them for subsampled chroma planes); `color` is RGBA and its alpha is blended or filled too; a border larger than the picture is clamped.
