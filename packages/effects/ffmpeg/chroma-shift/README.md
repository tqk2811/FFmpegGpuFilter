# Chroma Shift

Shifts the chroma (Cb and Cr) of the picture horizontally and vertically, leaving the luma in place.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `chroma-shift.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `cbh` | int | `0` | -255 to 255 | Shift chroma-blue horizontally, in pixels |
| `cbv` | int | `0` | -255 to 255 | Shift chroma-blue vertically, in pixels |
| `crh` | int | `0` | -255 to 255 | Shift chroma-red horizontally, in pixels |
| `crv` | int | `0` | -255 to 255 | Shift chroma-red vertically, in pixels |
| `edge` | int | `0` | 0 to 1 | Edge operation: 0 = smear (repeat the edge), 1 = wrap |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='chroma-shift.zip=cbh=6&crh=-6',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='chroma-shift.zip=cbh=6&crh=-6',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on PNGs:

```sh
gpufx run 'chroma-shift.zip=cbh=6:crh=-6' -i in.png -o out.png
```

## Notes

Port of FFmpeg's `chromashift` filter. Differences: shaders see RGB, so the pixel is converted to BT.709 luma and Cb/Cr, the chroma is read from the shifted position and the pixel is converted back (FFmpeg moves the U and V planes directly); the shift is in pixels of the full picture (FFmpeg shifts in chroma-plane pixels, which are 2 pixels wide in yuv420p). See also `rgba-shift`.
