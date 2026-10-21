# Wind Transition

The second clip blows in over the first with a ragged, randomly offset edge. `direction` picks where the wind comes from. Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `wind-transition.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `direction` | int | `0` | 0 to 3 | 0 = hlwind (rows, the edge enters from the left), 1 = hrwind (from the right), 2 = vuwind (columns, from the top), 3 = vdwind (from the bottom) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='wind-transition.zip=progress=clip((t-1)/1.5\,0\,1)&direction=1',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='wind-transition.zip=progress=clip((t-1)/1.5\,0\,1)&direction=1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

Still pictures with the CLI:

```sh
./target/release/gpufx run 'examples/effects/ffmpeg/wind-transition=progress=0.5:direction=1' -i a.png -i b.png -o out.png
```

## Notes

Port of FFmpeg's `xfade` transition `hlwind` (`direction=0`), `hrwind` (1), `vuwind` (2) and `vdwind` (3). The random offset is FFmpeg's `fract(sin(x * 12.9898 + y * 78.233) * 43758.545)`: per row for the horizontal winds (`x` = 0) and per column for the vertical ones (`y` = 0), so it is the same for every frame. GPUs compute `sin` less precisely than a CPU for large arguments, so the ragged edge can differ from FFmpeg's. The pattern takes `sin` of large arguments, so it can also differ between GPUs and backends.
