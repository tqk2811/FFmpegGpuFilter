# HSV Key

Turns pixels close to a hue/saturation/value into transparency. Use a format with alpha after it, or overlay it.

## Inputs

- `src` (any pixel format the GPU converts; shaders see RGBA)

## Output

Same size as the first input (`src`). Pixel format: that of `src` by default (the output has alpha, which a format without alpha such as `yuv420p` drops), so use `out_format=rgba` (or `yuva420p`) to keep the alpha.

## Options

Written inline after the package name: `hsv-key.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `hue` | float | `0` | -360 to 360 | Key hue in degrees; zero or a negative value ignores the hue |
| `sat` | float | `0` | -1 to 1 | Key saturation; a negative value ignores the saturation |
| `val` | float | `0` | -1 to 1 | Key value (brightness); a negative value ignores the value |
| `similarity` | float | `0.01` | 0.00001 to 1 | Distance from the key that becomes transparent |
| `blend` | float | `0` | 0 to 1 | Width of the soft edge above the similarity; 0 = hard cut |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i greenscreen.mp4 -i bg.mp4 -filter_complex \
  "[0][1]gpufx=graph='[0]hsv-key.zip=hue=120&sat=0.8&val=0.7&similarity=0.2&blend=0.1[k]; [1][k]overlay.zip=x=0&y=0&scale=1[out]',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i greenscreen.mp4 -i bg.mp4 -filter_complex \
  "[0][1]gpufx=graph='[0]hsv-key.zip=hue=120&sat=0.8&val=0.7&similarity=0.2&blend=0.1[k]; [1][k]overlay.zip=x=0&y=0&scale=1[out]',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on PNGs:

```sh
gpufx run 'hsv-key.zip=hue=120:sat=0.8:val=0.7:similarity=0.2:blend=0.1' -i in.png -o out.png
```

## Notes

The output carries alpha. The output format defaults to the input's, so set `out_format=rgba` (or `yuva420p`) on `gpufx` to keep it, and any filter after it must take an alpha format; `overlay.zip` honours it. Converting to a format without alpha drops it.

Port of FFmpeg's `hsvkey` filter (the hue option goes through the same conversion as in FFmpeg, so the same numbers pick the same hue). Differences: FFmpeg reads the Y, U and V planes of the video, the shader derives BT.709 full-range luma and Cb/Cr from RGB, so the values can differ slightly (mostly for limited-range video); the output alpha is multiplied by the input alpha; the `hsvhold` filter of the same file is not ported.
