# Color Key

Turns pixels close to a key color into transparency (RGB distance). Use a format with alpha after it, or overlay it.

## Inputs

- `src` (any pixel format the GPU converts; shaders see RGBA)

## Output

Same size as the first input (`src`). Pixel format: that of `src` by default (the output has alpha, which a format without alpha such as `yuv420p` drops), so use `out_format=rgba` (or `yuva420p`) to keep the alpha.

## Options

Written inline after the package name: `color-key.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `color` | color | `#000000` | RGB | Key color to make transparent; alpha is ignored |
| `similarity` | float | `0.01` | 0.00001 to 1 | Distance from the key color that becomes transparent; 0.01 matches only very close colors, 1 everything |
| `blend` | float | `0` | 0 to 1 | Width of the soft edge above the similarity; 0 = hard cut |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i greenscreen.mp4 -i bg.mp4 -filter_complex \
  "[0][1]gpufx=graph='[0]color-key.zip=color=#00ff00&similarity=0.3&blend=0.1[k]; [1][k]overlay.zip=x=0&y=0&scale=1[out]',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i greenscreen.mp4 -i bg.mp4 -filter_complex \
  "[0][1]gpufx=graph='[0]color-key.zip=color=#00ff00&similarity=0.3&blend=0.1[k]; [1][k]overlay.zip=x=0&y=0&scale=1[out]',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on PNGs:

```sh
gpufx run 'color-key.zip=color=#00ff00:similarity=0.3:blend=0.1' -i in.png -o out.png
```

## Notes

The output carries alpha. The output format defaults to the input's, so set `out_format=rgba` (or `yuva420p`) on `gpufx` to keep it, and any filter after it must take an alpha format; `overlay.zip` honours it. Converting to a format without alpha drops it.

Port of FFmpeg's `colorkey` filter. Differences: the key color is a `color` parameter (FFmpeg takes any color string); the output alpha is multiplied by the input alpha (FFmpeg overwrites it, which is the same for opaque video); the `colorhold` filter of the same file is not ported.
