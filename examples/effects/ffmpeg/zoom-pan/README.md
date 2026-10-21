# Zoom and Pan

Zoom and pan with the zoom, x and y given as expressions of the time (Ken Burns).

Approximation of FFmpeg's `zoompan` (`libavfilter/vf_zoompan.c`).

## Inputs

- `src`: any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `zoom-pan.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. Parameters of type `expr` are GPU expressions (api 2, see [Expression parameters](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md#expression-parameters)): numbers, the listed variables, `pi`, `tau`, `e`, `+ - * / ^`, and the functions `sin cos tan asin acos atan atan2 abs sign min max clamp mix step smoothstep pow sqrt exp log floor ceil round fract` only (no `if`, `gt`, `lt`, `mod`: use `step`, `mix`, `fract`); commas inside an FFmpeg command line are escaped as `\,`. The other values are literals or FFmpeg expressions in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `fps` | float | `25` | 1 to 240 | Frame rate used to compute `on` (output frame number) from the time |
| `zoom` | expr | `1` | - | Zoom, clipped to 1..10. iw, ih input size, ow, oh output size (pixels), time seconds, on frame number |
| `x` | expr | `0` | - | Left edge of the shown area in input pixels, clipped to 0..iw-iw/zoom. Variables of `zoom` plus `zoom` (the value just computed) |
| `y` | expr | `0` | - | Top edge of the shown area in input pixels, clipped to 0..ih-ih/zoom. Variables of `x` plus `x` |

## Differences from FFmpeg

- **Stateless.** FFmpeg's `zoompan` accumulates: `pzoom`, `px`, `py` (the previous values) let an expression build the zoom frame by frame (`zoom='min(zoom+0.0015,1.5)'`), and `duration`/`pduration`, `in`, `frame` count the frames of each input. Here the three expressions are **pure functions of time** and none of those variables exist, so seeking and split renders give the same picture. Write the accumulation as a closed form of `time`: `min(1+0.0015*25*time,1.5)` (0.0015 per frame at 25 fps is 0.0375 per second).
- `zoom` is also a variable of `x` and `y` (the value just computed, like FFmpeg), `x` of `y`; the classic center is `x=iw/2-(iw/zoom/2)`, `y=ih/2-(ih/zoom/2)`.
- Zoom is clipped to 1..10 and the position to the input like FFmpeg; the crop is not rounded to the chroma subsampling and the scaling is bilinear (FFmpeg: bicubic via swscale).
- The output has the size of the input (no `s=` option). The effect is applied to every frame passing through (FFmpeg's `d` option, which turns one input frame into several output frames, does not exist); `fps` only sets how `on` is derived from the time. Variables `in_w`, `in_h`, `out_w`, `out_h`, `it`, `ot`, `a`, `sar`, `dar`, `hsub`, `vsub` are not provided (`iw`, `ih`, `ow`, `oh`, `time`, `on` are).

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='zoom-pan.zip=zoom=1+0.05*time&x=iw/2-(iw/zoom/2)&y=ih/2-(ih/zoom/2)',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).
