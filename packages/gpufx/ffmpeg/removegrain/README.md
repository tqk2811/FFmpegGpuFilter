# Remove Grain

Spatial denoiser/sharpener with 25 modes over the 3x3 neighbourhood (clip to neighbours, medians, blurs, edge-directed averages).

Port of FFmpeg's `removegrain`.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `removegrain.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `m0` | int | `0` | 0 to 24 | Mode for the red channel (0 = unchanged) |
| `m1` | int | `0` | 0 to 24 | Mode for the green channel (0 = unchanged) |
| `m2` | int | `0` | 0 to 24 | Mode for the blue channel (0 = unchanged) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='removegrain.zip=m0=17&m1=17&m2=17',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='removegrain.zip=m0=17&m1=17&m2=17',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'removegrain.zip=m0=17&m1=17&m2=17' -i in.png -o out.png
```

## Notes

One pass; all 24 modes of FFmpeg's C reference functions are ported (not only a subset): 0 unchanged; 1 clip to the min/max of the 8 neighbours; 2 to 4 clip to the 2nd/3rd/4th-order statistics of the neighbours (2 and 3 are the "soft" clips, 4 is a median of the neighbours); 5 to 9 clip along the line (of the 4 through the centre) that changes the centre least, by different criteria; 10 take the neighbour closest to the centre; 11 and 12 3x3 blur (1 2 1 kernel); 13 to 16 average along the line with the smallest difference (13/15 skip odd rows, 14/16 even rows, the other rows are copied); 17 clip to the intersection of the line ranges; 18 clip along the line with the smallest maximum difference; 19 mean of the 8 neighbours; 20 mean of the 3x3; 21 and 22 clip to the range of line averages; 23 and 24 limit the change by the line contrast.

Each mode uses 8-bit integer math exactly like FFmpeg (including its tie-break order). The first and last row and column are copied.

Differences from FFmpeg:

- `m0`, `m1` and `m2` apply to the R, G and B channels (FFmpeg: the first three planes of the pixel format, `m3` for alpha is not ported; alpha is passed through). The default 0 leaves the picture unchanged, as in FFmpeg.
- Mixed odd/even skipping modes behave per channel (FFmpeg sets the skip flag for the whole frame).
