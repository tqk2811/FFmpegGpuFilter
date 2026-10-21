# Box Blur

Box blur with a horizontal and a vertical radius, applied one to three times.

Port of FFmpeg's `boxblur` and `avgblur`.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `box-blur.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `radius` | int | `2` | 0 to 64 | Horizontal radius in pixels: the box is 2 * radius + 1 wide (`lr` of boxblur, `sizeX` of avgblur) |
| `radius_v` | int | `-1` | -1 to 64 | Vertical radius; -1 = same as `radius` (`sizeY` of avgblur) |
| `power` | int | `2` | 1 to 3 | How many times the box blur is applied (`lp` of boxblur; 1 gives avgblur) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='box-blur.zip=radius=4',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='box-blur.zip=radius=4',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'box-blur.zip=radius=4' -i in.png -o out.png
```

## Notes

Six passes (horizontal, vertical, repeated three times) through intermediate textures; rounds above `power` copy their input. One effect covers both `boxblur` (`radius`, `power`; default power 2 as in FFmpeg) and `avgblur` (`radius` as `sizeX`, `radius_v` as `sizeY`, `power=1`).

Differences from FFmpeg:

- The same radius and power apply to the colour channels and the alpha channel (FFmpeg has separate `chroma_*` and `alpha_*` options and works per YUV plane); the blur runs on RGBA.
- The radius is an integer in pixels, capped at 64 (FFmpeg's `boxblur` takes an expression and `avgblur` goes to 1024). Use a value that changes with time through the usual FFmpeg expression in the option.
- Pixels outside the picture clamp to the edge pixel, where FFmpeg mirrors.
