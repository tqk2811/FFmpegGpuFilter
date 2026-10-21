# Monochrome

Black and white through a color filter, like a colored filter on a film camera.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `monochrome.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `cb` | float | `0` | -1 to 1 | Chroma blue spot of the filter |
| `cr` | float | `0` | -1 to 1 | Chroma red spot of the filter |
| `size` | float | `1` | 0.1 to 10 | Size of the color filter |
| `high` | float | `0` | 0 to 1 | Strength of the filter in the highlights |


Port of FFmpeg's `monochrome`. The luma is scaled by a Gaussian-like window around the chosen spot in the chroma plane (`cb`, `cr`) and the color is dropped.

Differences: FFmpeg reads the Y, U and V planes of the input; here Y, U and V are computed from the RGB values with full-range BT.709, so the numbers differ slightly on limited-range video.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='monochrome.zip=cb=-0.3&cr=0.5&size=1.5',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='monochrome.zip=cb=-0.3&cr=0.5&size=1.5',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'monochrome.zip=cr=0.5' -i in.png -o out.png
```
