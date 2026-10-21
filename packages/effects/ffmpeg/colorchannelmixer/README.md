# Color Channel Mixer

Mixes the red, green, blue and alpha channels with a 4x4 matrix.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `colorchannelmixer.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `rr` | float | `1` | -2 to 2 | Gain of the red channel in the red channel |
| `rg` | float | `0` | -2 to 2 | Gain of the green channel in the red channel |
| `rb` | float | `0` | -2 to 2 | Gain of the blue channel in the red channel |
| `ra` | float | `0` | -2 to 2 | Gain of the alpha channel in the red channel |
| `gr` | float | `0` | -2 to 2 | Gain of the red channel in the green channel |
| `gg` | float | `1` | -2 to 2 | Gain of the green channel in the green channel |
| `gb` | float | `0` | -2 to 2 | Gain of the blue channel in the green channel |
| `ga` | float | `0` | -2 to 2 | Gain of the alpha channel in the green channel |
| `br` | float | `0` | -2 to 2 | Gain of the red channel in the blue channel |
| `bg` | float | `0` | -2 to 2 | Gain of the green channel in the blue channel |
| `bb` | float | `1` | -2 to 2 | Gain of the blue channel in the blue channel |
| `ba` | float | `0` | -2 to 2 | Gain of the alpha channel in the blue channel |
| `ar` | float | `0` | -2 to 2 | Gain of the red channel in the alpha channel |
| `ag` | float | `0` | -2 to 2 | Gain of the green channel in the alpha channel |
| `ab` | float | `0` | -2 to 2 | Gain of the blue channel in the alpha channel |
| `aa` | float | `1` | -2 to 2 | Gain of the alpha channel in the alpha channel |
| `pc` | int | `0` | 0 to 6 | Preserve color mode: 0 = none, 1 = lum, 2 = max, 3 = avg, 4 = sum, 5 = nrm, 6 = pwr |
| `pa` | float | `0` | 0 to 1 | Amount of the color preservation |


Port of FFmpeg's `colorchannelmixer`. Names are `<output channel><input channel>`: `rg` is the gain of green in the red channel. With `pc` set, the output color is scaled so its lightness (the mode) matches the input, blended by `pa`.

Differences: the `avg` mode adds `1/255` as FFmpeg does for 8-bit; the result is not rounded to the pixel depth. The alpha output `a` is written as is (the shader sees straight alpha).

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorchannelmixer.zip=rr=0.393&rg=0.769&rb=0.189&gr=0.349&gg=0.686&gb=0.168&br=0.272&bg=0.534&bb=0.131',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='colorchannelmixer.zip=rr=0.393&rg=0.769&rb=0.189&gr=0.349&gg=0.686&gb=0.168&br=0.272&bg=0.534&bb=0.131',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'colorchannelmixer.zip=rr=0&rb=1&bb=0&br=1' -i in.png -o out.png
```
