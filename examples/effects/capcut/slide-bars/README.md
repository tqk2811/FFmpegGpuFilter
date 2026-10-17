# Slide Bars

Four horizontal strips of the second clip slide in from alternating sides with motion blur, then the picture shakes and ripples as a ring flare bursts out (CapCut "Slide Bars"). Drive `progress` from 0 to 1.

Recreated from the CapCut transition of the same name; CapCut's default length for it is about 0.8 s, so drive `progress` over roughly that long. The ripple map and the flare are drawn procedurally (soft expanding rings), not taken from CapCut's video clips. As in CapCut, the ripple starts with a sudden 3% sideways jump at scene time 0.6 s (the first frame of CapCut's ripple map is black, which pushes the whole picture), and it keeps the picture pushed about 3% sideways until the very end, so the last frame snaps back to the plain second clip.

**Set `duration` to the real transition length in seconds** (the same length the `progress` expression spans); the shake wobbles on the real clock.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `slide-bars.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `duration` | float | `0.8` | 0.01 to 10 | Real transition length in seconds; sets the speed of the shake |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='slide-bars.zip=progress=clip((t-1)/0.8\,0\,1)&duration=0.8',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='slide-bars.zip=progress=clip((t-1)/0.8\,0\,1)&duration=0.8',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'slide-bars.zip=progress=0.5' -i a.png -i b.png -o out.png
```
