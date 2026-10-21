# Displace

Displaces the first input by the brightness of two map inputs (x and y).

## Inputs

- `src`: Picture to displace
- `xmap`: Horizontal displacement map (must have the same size as the first input)
- `ymap`: Vertical displacement map (must have the same size as the first input)

A map value of 128 (mid gray) means no displacement; a darker value moves the source pixel to the left (up for `ymap`), a lighter one to the right (down).

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `displace.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `edge` | int | `1` | 0 to 3 | What happens beyond the edge: 0 = blank (black), 1 = smear (repeat the edge), 2 = wrap, 3 = mirror |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 -i xmap.mp4 -i ymap.mp4 -filter_complex \
  "[0][1][2]gpufx=graph='displace.zip=edge=1',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 -i xmap.mp4 -i ymap.mp4 -filter_complex \
  "[0][1][2]gpufx=graph='displace.zip=edge=1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on PNGs:

```sh
gpufx run 'displace.zip=edge=1' -i in.png -i xmap.png -i ymap.png -o out.png
```

## Notes

Port of FFmpeg's `displace` filter. Differences: FFmpeg displaces each plane with the same plane of the maps; the shader reads the BT.709 luma of the RGB value of each map pixel (the same for gray maps). The shift is rounded to whole pixels and is `value*255 - 128`, like FFmpeg; blank is opaque black. FFmpeg keeps the maps in sync by frame timestamps (`framesync`); the gpufx filter feeds one frame of every input per output frame.
