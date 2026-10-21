# HSV Hold

Removes the color from every pixel except those close to a hue/saturation/value, which keep their color.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `hsvhold.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `hue` | float | `0` | -360 to 360 | Key hue in degrees; a negative value ignores the hue |
| `sat` | float | `0` | -1 to 1 | Key saturation; a negative value ignores the saturation |
| `val` | float | `0` | -1 to 1 | Key value (brightness); a negative value ignores the value |
| `similarity` | float | `0.01` | 1e-05 to 1 | Distance from the key that keeps its color |
| `blend` | float | `0` | 0 to 1 | Width of the soft edge above the similarity; 0 = hard cut |

Port of FFmpeg's `hsvhold`. The option names, defaults and ranges are FFmpeg's, and the key distance is the same as in the `hsv-key` effect. FFmpeg keeps Y and scales the U and V planes by `1 - t`, where `t` is the keying value; here the pixel is converted to full-range BT.709 Y/U/V, U and V are scaled, and the result is converted back.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='hsvhold.zip=hue=120&sat=0.5&val=0.5&similarity=0.3&blend=0.1',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='hsvhold.zip=hue=120&sat=0.5&val=0.5&similarity=0.3&blend=0.1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'hsvhold.zip=hue=120:sat=0.5:val=0.5:similarity=0.3:blend=0.1' -i in.png -o out.png
```
