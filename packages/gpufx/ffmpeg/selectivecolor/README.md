# Selective Color

Photoshop-style selective color: CMYK corrections limited to a color range.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `selectivecolor.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `correction_method` | int | `0` | 0 to 1 | Correction method: 0 = absolute, 1 = relative |
| `reds` | vec4 | `0, 0, 0, 0` | -1 to 1 each | Adjustment of the red regions: cyan, magenta, yellow, black |
| `yellows` | vec4 | `0, 0, 0, 0` | -1 to 1 each | Adjustment of the yellow regions: cyan, magenta, yellow, black |
| `greens` | vec4 | `0, 0, 0, 0` | -1 to 1 each | Adjustment of the green regions: cyan, magenta, yellow, black |
| `cyans` | vec4 | `0, 0, 0, 0` | -1 to 1 each | Adjustment of the cyan regions: cyan, magenta, yellow, black |
| `blues` | vec4 | `0, 0, 0, 0` | -1 to 1 each | Adjustment of the blue regions: cyan, magenta, yellow, black |
| `magentas` | vec4 | `0, 0, 0, 0` | -1 to 1 each | Adjustment of the magenta regions: cyan, magenta, yellow, black |
| `whites` | vec4 | `0, 0, 0, 0` | -1 to 1 each | Adjustment of the white regions: cyan, magenta, yellow, black |
| `neutrals` | vec4 | `0, 0, 0, 0` | -1 to 1 each | Adjustment of the neutral regions: cyan, magenta, yellow, black |
| `blacks` | vec4 | `0, 0, 0, 0` | -1 to 1 each | Adjustment of the black regions: cyan, magenta, yellow, black |

A `vec4` is four comma-separated numbers (`reds=0.2,0,-0.2,0`; write `0.2\,0\,-0.2\,0` in an FFmpeg command line).


Port of FFmpeg's `selectivecolor`. Each range takes four numbers: the cyan, magenta, yellow and black adjustment. FFmpeg gives them as a text (`reds="0.2 0 -0.2 0"`); here they are a `vec4`, four comma-separated numbers (write `0.2\,0\,-0.2\,0` in an FFmpeg command line). A range with all four at 0 changes nothing.

Differences: the color range tests and weights are computed in float on the 0..1 values instead of integers (the half-value thresholds are 0.5). The `psfile` option is not ported.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='selectivecolor.zip=reds=0.2\,0\,-0.2\,0&blues=0\,0\,0.3\,-0.1',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='selectivecolor.zip=reds=0.2\,0\,-0.2\,0&blues=0\,0\,0.3\,-0.1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'selectivecolor.zip=reds=0.3,0,0,0' -i in.png -o out.png
```
