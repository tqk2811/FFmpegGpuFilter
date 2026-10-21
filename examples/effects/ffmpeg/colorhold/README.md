# Color Hold

Removes all color except pixels close to a key color, which stay in color; the rest turns gray.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `colorhold.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `color` | color | `#000000` | - | Color to keep; alpha is ignored |
| `similarity` | float | `0.01` | 1e-05 to 1 | Distance from the key color that keeps its color; 0.01 matches only very close colors, 1 everything |
| `blend` | float | `0` | 0 to 1 | Width of the soft edge above the similarity; 0 = hard cut |

Port of FFmpeg's `colorhold`. The option names, defaults and ranges are FFmpeg's. Distance and blend are as in FFmpeg's colorkey (RGB distance, `blend` below 0.0001 means a hard cut); pixels past the similarity are mixed toward their channel average `(r+g+b)/3`, as FFmpeg does. The default key color is black, as in FFmpeg.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorhold.zip=color=#ff0000&similarity=0.3&blend=0.1',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorhold.zip=color=#ff0000&similarity=0.3&blend=0.1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'colorhold.zip=color=#ff0000:similarity=0.3:blend=0.1' -i in.png -o out.png
```
