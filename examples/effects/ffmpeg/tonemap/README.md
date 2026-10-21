# Tonemap

Compresses the brightness range with a tone-mapping operator (none, linear, gamma, clip, reinhard, hable, mobius).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `tonemap.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `tonemap` | int | `0` | 0 to 6 | Algorithm: 0 none, 1 linear, 2 gamma, 3 clip, 4 reinhard, 5 hable, 6 mobius |
| `param` | float | `0` | 0 to 100 | Algorithm parameter; 0 = FFmpeg's default for the algorithm (gamma 1.8, mobius 0.3, others 1). Reinhard: the value p, valid in (0,1] (larger values are treated as 1), is turned into (1-p)/p |
| `desat` | float | `2` | 0 to 100 | Desaturation strength of values brighter than this luma; 0 turns it off |
| `peak` | float | `0` | 0 to 100 | Signal peak override; 0 = 1.0 (the SDR white) |

Port of FFmpeg's `tonemap`. The option names, defaults and ranges are FFmpeg's (`param` uses 0 for FFmpeg's NaN default). FFmpeg works on linear-light float RGB and takes the peak from the frame's HDR side data when `peak` is 0; here the pixel values are the texture's 0..1 values and `peak` 0 means 1.0. HDR values above 1 exist only on the 16-bit float path (a float texture); with 8-bit or 10-bit input the values never exceed 1, so only a `peak` below 1 or a `param` changes the picture much. The desaturation uses BT.709 luma coefficients, FFmpeg takes them from the frame's colorspace tag. The input is not converted to linear light; apply a transfer function first if you need it.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='tonemap.zip=tonemap=5&desat=0',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='tonemap.zip=tonemap=5&desat=0',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'tonemap.zip=tonemap=5:desat=0' -i in.png -o out.png
```
