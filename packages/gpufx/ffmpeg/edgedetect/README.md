# Edge Detect (Canny)

Canny edge detector: gaussian blur, Sobel gradient, non-maximum suppression and double threshold.

Port of FFmpeg's `edgedetect` (Canny edge detector), modes `wires`, `colormix` and `canny`.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `edgedetect.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `high` | float | `0.196078431` | 0 to 1 | High threshold (default 50/255) |
| `low` | float | `0.0784313725` | 0 to 1 | Low threshold (default 20/255) |
| `mode` | int | `0` | 0 to 2 | 0 = wires (gray wires on black, from the luma), 1 = colormix (edges of R, G, B averaged with the source), 2 = canny (edges of R, G, B on black) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='edgedetect.zip=mode=2&low=0.05&high=0.2',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='edgedetect.zip=mode=2&low=0.05&high=0.2',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'edgedetect.zip=mode=2&low=0.05&high=0.2' -i in.png -o out.png
```

## Notes

Three passes: (1) 5x5 gaussian blur (sigma 1.4, integer kernel divided by 159), (2) Sobel gradient `|gx| + |gy|` with non-maximum suppression along the gradient direction rounded to 0, 45, 90 or 135 degrees, (3) double threshold (a pixel above `high` is kept; one above `low` is kept when one of its eight neighbours is above `high`) and the output mode. The intermediate textures hold 8-bit values (the blurred picture and the suppressed magnitude clipped to 255), which is also what FFmpeg stores, so the gradient itself is never stored: pass 2 computes it again for the two neighbours it compares with.

Modes: 0 = `wires` (white/gray wires on black, from the luma), 1 = `colormix` (`(edge + source) / 2` per channel), 2 = `canny` (edges of each channel on black).

Differences from FFmpeg:

- FFmpeg's `wires` accepts only gray; here it works on the luma (BT.709) of the RGB picture. `colormix` and `canny` work on R, G, B channels instead of the planes of the pixel format (`planes` is not ported). The alpha channel is passed through unchanged.
- The border (the outermost pixel ring for the gradient, two rings for the blur) is handled as FFmpeg does: it is copied by the blur and has no gradient.
- `high` and `low` are rounded to 8-bit levels like FFmpeg's `low_u8`/`high_u8`.
