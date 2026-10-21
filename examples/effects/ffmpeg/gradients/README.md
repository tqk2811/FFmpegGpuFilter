# Gradients

Rotating multi-color gradients: linear, radial, circular, spiral, square (generator).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU. It only sets the size (see Notes).

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `gradients.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `nb_colors` | int | `2` | 2 to 8 | How many of the colors `c0`..`c7` are used |
| `kind` | int | `0` | 0 to 4 | Gradient type: 0 linear, 1 radial, 2 circular, 3 spiral, 4 square |
| `p0` | vec2 | `0.1, 0.2` | 0 to 1 | Start point of the gradient line, as a fraction of the picture size |
| `p1` | vec2 | `0.9, 0.8` | 0 to 1 | End point of the gradient line, as a fraction of the picture size |
| `speed` | float | `0.01` | 0 to 1 | Rotation of the line around the picture center, radians per frame at `rate` frames per second |
| `rate` | float | `25` | 1 to 240 | Frame rate that `speed` refers to |
| `c0` | color | `#ff3b30` | RGBA | 1st color |
| `c1` | color | `#007aff` | RGBA | 2nd color |
| `c2` | color | `#34c759` | RGBA | 3rd color |
| `c3` | color | `#ffcc00` | RGBA | 4th color |
| `c4` | color | `#af52de` | RGBA | 5th color |
| `c5` | color | `#00c7be` | RGBA | 6th color |
| `c6` | color | `#ff2d55` | RGBA | 7th color |
| `c7` | color | `#ffffff` | RGBA | 8th color |
| `opacity` | float | `1` | 0 to 1 | Blend over the input picture: 1 = only the generated picture, 0 = the input unchanged |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -f lavfi -i color=black:s=1280x720:r=25 \
  -vf "format=nv12,gpufx=graph='gradients.zip=kind=3&nb_colors=4&speed=0.02',hwdownload,format=nv12" -t 10 out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'gradients.zip=kind=3:nb_colors=4:speed=0.02' -i in.png -o out.png
```

## Notes

Port of FFmpeg's `gradients` source (vsrc_gradients.c). Differences: FFmpeg picks random colors and end points when they are not given; here the defaults are fixed. The end points are fractions of the picture (FFmpeg: pixels), the rotation is `speed * rate * t` (FFmpeg: `speed` per frame), and the color alpha is honoured by blending over the input with `opacity`.

The effect has no source of its own: gpufx effects always have an input, so the input `src` only sets the size (and is blended in by `opacity`). Use any video of the wanted size, for example `-f lavfi -i color=black:s=1280x720:r=25`.
