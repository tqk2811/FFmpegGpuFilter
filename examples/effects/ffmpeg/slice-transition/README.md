# Slice Transition

The second clip replaces the first in ten thin slices that open in a staggered sweep. `direction` picks the sweep and the slice axis. Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `slice-transition.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `direction` | int | `0` | 0 to 3 | 0 = hlslice (vertical slices, sweep from the left), 1 = hrslice (from the right), 2 = vuslice (horizontal slices, sweep from the top), 3 = vdslice (from the bottom) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='slice-transition.zip=progress=clip((t-1)/1.5\,0\,1)&direction=1',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='slice-transition.zip=progress=clip((t-1)/1.5\,0\,1)&direction=1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

Still pictures with the CLI:

```sh
./target/release/gpufx run 'examples/effects/ffmpeg/slice-transition=progress=0.5:direction=1' -i a.png -i b.png -o out.png
```

## Notes

Port of FFmpeg's `xfade` transition `hlslice` (`direction=0`), `hrslice` (1), `vuslice` (2) and `vdslice` (3). FFmpeg's `progress` runs from 1 to 0; here it runs from 0 (first clip) to 1 (second clip). The formula is FFmpeg's, evaluated per pixel.
