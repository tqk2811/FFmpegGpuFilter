# Scroll

Scroll the picture horizontally and vertically at a constant speed, wrapping around.

Port of FFmpeg's `scroll` (`libavfilter/vf_scroll.c`).

## Inputs

- `src`: any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `scroll.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. Parameters of type `expr` are GPU expressions (api 2, see [Expression parameters](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md#expression-parameters)): numbers, the listed variables, `pi`, `tau`, `e`, `+ - * / ^`, and the functions `sin cos tan asin acos atan atan2 abs sign min max clamp mix step smoothstep pow sqrt exp log floor ceil round fract` only (no `if`, `gt`, `lt`, `mod`: use `step`, `mix`, `fract`); commas inside an FFmpeg command line are escaped as `\,`. The other values are literals or FFmpeg expressions in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `hspeed` | float | `0` | -10 to 10 | Horizontal speed in frame widths per second; positive moves the picture to the left |
| `vspeed` | float | `0` | -10 to 10 | Vertical speed in frame heights per second; positive moves the picture up |
| `hpos` | float | `0` | 0 to 1 | Initial horizontal position, 0..1 |
| `vpos` | float | `0` | 0 to 1 | Initial vertical position, 0..1 |

## Differences from FFmpeg

- **Speed is per second**, not per frame: FFmpeg adds `horizontal * width` to the position every frame, here the position is `speed * time` frame sizes, so a given FFmpeg value corresponds to `value * frame_rate` here, and dropped frames or a different frame rate do not change the motion. The range is -10..10 instead of -1..1.
- The parameters are `hspeed`, `vspeed` (FFmpeg: `horizontal`/`h`, `vertical`/`v`); `hpos`, `vpos` are the same. Positive speeds move the picture left / up and the picture wraps around, like FFmpeg.
- The position is truncated to whole pixels of the full frame (FFmpeg rounds the chroma planes separately), so chroma of a subsampled video may differ by one pixel.
- Evaluated from the exact time at every frame, so seeking gives the same picture; FFmpeg's position depends on how many frames came before.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='scroll.zip=hspeed=0.1&vspeed=0.05',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).
