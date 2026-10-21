# Unsharp

Sharpen or blur with a box-shaped unsharp mask, with separate luma and chroma size and amount.

Port of FFmpeg's `unsharp`.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `unsharp.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `luma_msize_x` | int | `5` | 3 to 23 | Luma matrix horizontal size (`lx`); the window is 2 * (size / 2) + 1 wide |
| `luma_msize_y` | int | `5` | 3 to 23 | Luma matrix vertical size (`ly`) |
| `luma_amount` | float | `1` | -2 to 5 | Luma effect strength (`la`): negative blurs, positive sharpens |
| `chroma_msize_x` | int | `5` | 3 to 23 | Chroma matrix horizontal size (`cx`) |
| `chroma_msize_y` | int | `5` | 3 to 23 | Chroma matrix vertical size (`cy`) |
| `chroma_amount` | float | `0` | -2 to 5 | Chroma effect strength (`ca`) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='unsharp.zip=luma_amount=1.5',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='unsharp.zip=luma_amount=1.5',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'unsharp.zip=luma_amount=1.5' -i in.png -o out.png
```

## Notes

Two passes (horizontal, then vertical box average) through an intermediate texture. The effect separates the picture into luma and chroma (BT.709), as FFmpeg's planes, and the result is `c + (c - blurred) * amount`. The existing `sharpen` effect is a simpler fixed 3x3 mask.

Differences from FFmpeg:

- Luma and chroma are computed from RGB (BT.709) instead of read from YUV planes; chroma is full resolution.
- `alpha_msize_x`, `alpha_msize_y` and `alpha_amount` are not ported: the alpha channel is passed through unchanged.
- Pixels outside the picture repeat the edge pixel.
