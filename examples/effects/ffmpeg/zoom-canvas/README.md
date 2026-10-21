# Zoom Canvas

Draws the second input zoomed around an anchor point onto the first input (a fixed-size, e.g. transparent, canvas), keeping its aspect ratio.

## Inputs

- `canvas`: Background that sets the output size (e.g. a transparent color source at the largest size)
- `src`: Picture to zoom (alpha is honoured)

No size constraint between the inputs.

## Output

Same size as the first input (`canvas`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `zoom-canvas.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `zoom` | float | `1` | 0 to 16 | Size of the picture relative to its fitted size (1 = fitted as set by `fit`) |
| `fit` | int | `0` | 0 to 2 | Size at zoom 1: 0 contain (whole picture inside the canvas), 1 cover (fills the canvas), 2 native pixels |
| `anchor` | vec2 | `0.5,0.5` | | Canvas point (0..1 of its size) where the picture's pivot is placed |
| `pivot` | vec2 | `0.5,0.5` | | Point of the picture (0..1 of its size) that stays on the anchor while zooming |
| `opacity` | float | `1` | 0 to 1 | Picture opacity |

## Example

A picture that grows from 30% to its full fitted size in 5 seconds, centred on a transparent 1920x1080 canvas. Every frame keeps the canvas size, so later filters and the encoder see a fixed size:

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk \
  -f lavfi -i "color=black@0:s=1920x1080,format=rgba" -i src.mp4 -filter_complex \
  "[0]hwupload[c];[1]hwupload[s];[c][s]gpufx=graph='zoom-canvas.zip=zoom=0.3+0.7*min(t/5\,1)',hwdownload,format=rgba" \
  -c:v prores_ks -profile:v 4444 out.mov
```

Zoom into the top-left corner instead: `anchor=0,0&pivot=0,0`.

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

## Notes

- Use this instead of a growing frame size: FFmpeg filters after gpufx and encoders expect one size for the whole stream, so the "maximum size" is the canvas and the picture grows inside it.
- The picture is composited over the canvas with straight alpha; with a transparent canvas the output is transparent outside the picture. Keep an alpha format (`rgba`, `yuva420p`...) and an encoder with alpha to keep it.
- `src` has `mipmaps`, so shrinking it a lot does not alias.
