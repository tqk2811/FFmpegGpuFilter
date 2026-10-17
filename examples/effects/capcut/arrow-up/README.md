# Arrow Up

An upward chevron edge sweeps from the bottom to the top and reveals the second clip, trailed by two gold chevron stripes (CapCut "Arrow Up"). The chevron and stripes are generated in the shader (no matte video). Drive `progress` from 0 to 1.

Recreated from the CapCut transition of the same name; CapCut's default length for it is about 0.8 s, so drive `progress` over roughly that long.

**Timing:** CapCut drives this effect from matte videos over a 2 s animation, so the wipe itself fills only `progress` 0.2 to 0.7. The edge position per frame, the flank slope, the stripe thickness, spacing and colour were measured from those videos; landscape frames (aspect 4:3 and wider) use the 16:9 layout, square and portrait frames the 1:1 layout, scaled to cover the frame.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `arrow-up.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='arrow-up.zip=progress=clip((t-1)/0.8\,0\,1)',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='arrow-up.zip=progress=clip((t-1)/0.8\,0\,1)',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'arrow-up.zip=progress=0.5' -i a.png -i b.png -o out.png
```
