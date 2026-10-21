# RGBA Shift

Shifts the red, green, blue and alpha channels of the picture independently (a glitch/chromatic aberration look).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `rgba-shift.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `rh` | int | `0` | -255 to 255 | Shift red horizontally, in pixels |
| `rv` | int | `0` | -255 to 255 | Shift red vertically, in pixels |
| `gh` | int | `0` | -255 to 255 | Shift green horizontally, in pixels |
| `gv` | int | `0` | -255 to 255 | Shift green vertically, in pixels |
| `bh` | int | `0` | -255 to 255 | Shift blue horizontally, in pixels |
| `bv` | int | `0` | -255 to 255 | Shift blue vertically, in pixels |
| `ah` | int | `0` | -255 to 255 | Shift alpha horizontally, in pixels |
| `av` | int | `0` | -255 to 255 | Shift alpha vertically, in pixels |
| `edge` | int | `0` | 0 to 1 | Edge operation: 0 = smear (repeat the edge), 1 = wrap |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='rgba-shift.zip=rh=-8&bh=8',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='rgba-shift.zip=rh=-8&bh=8',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on PNGs:

```sh
gpufx run 'rgba-shift.zip=rh=-8:bh=8' -i in.png -o out.png
```

## Notes

Port of the `rgbashift` filter of FFmpeg (it lives in `vf_chromashift.c`). It is a separate effect from `chroma-shift` because it works on the R, G, B and A channels, not on chroma. Difference: FFmpeg only accepts RGB (planar or packed) input for it; gpufx converts any input to RGBA first.
