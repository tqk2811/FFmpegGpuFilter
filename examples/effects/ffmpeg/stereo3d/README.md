# Stereo3D

Port of FFmpeg's `stereo3d`: converts between stereoscopic 3D layouts (side by side, above below, interleaved rows or columns) and anaglyph, mono or checkerboard output.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU. The frame is read as the `input` layout; side by side and interleaved columns need an even width, above below and interleaved rows an even height.

## Output

Same size as the first input (`src`). FFmpeg changes the size (a side by side input gives an anaglyph of half the width, an anaglyph input to side by side doubles it...); gpufx effects cannot resize, so each eye is stretched to the whole frame (or squeezed into its half, for the side by side and above below outputs) and the frame size stays. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `stereo3d.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `input` | int | `0` | 0 to 7 | Input layout: 0 `sbsl` (side by side, left eye first), 1 `sbsr`, 2 `abl` (above below, left eye first), 3 `abr`, 4 `irl` (interleaved rows, left eye on the even rows), 5 `irr`, 6 `icl` (interleaved columns, left eye on the even columns), 7 `icr` |
| `output` | int | `3` | 0 to 25 | Output layout, see the list below |

Output layouts, with FFmpeg's names:

| Value | Name | Layout |
|-------|------|--------|
| 0 to 3 | `arcg`, `arch`, `arcc`, `arcd` | anaglyph red/cyan: gray, half color, color, Dubois |
| 4 to 7 | `agmg`, `agmh`, `agmc`, `agmd` | anaglyph green/magenta: gray, half color, color, Dubois |
| 8 to 11 | `aybg`, `aybh`, `aybc`, `aybd` | anaglyph yellow/blue: gray, half color, color, Dubois |
| 12, 13 | `arbg`, `argg` | anaglyph red/blue gray, red/green gray |
| 14, 15 | `ml`, `mr` | mono, the left or the right eye |
| 16, 17 | `irl`, `irr` | interleaved rows, left or right eye on the even rows |
| 18, 19 | `sbsl`, `sbsr` | side by side, left or right eye first |
| 20, 21 | `abl`, `abr` | above below, left or right eye first |
| 22, 23 | `chl`, `chr` | checkerboard, left or right eye where x + y is even |
| 24, 25 | `icl`, `icr` | interleaved columns, left or right eye on the even columns |

## Example

Side by side video to a red/cyan Dubois anaglyph:

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i sbs.mp4 \
  -vf "format=nv12,gpufx=graph='stereo3d.zip=input=0&output=3',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i sbs.mp4 \
  -vf "format=nv12,gpufx=graph='stereo3d.zip=input=0&output=3',hwdownload,format=nv12" out.mp4
```

## Notes

Differences from FFmpeg:

- **Aspect ratio**: each eye is stretched to the whole frame, so its aspect ratio differs from FFmpeg's half-size outputs (e.g. `sbs2l`, `ab2l`) which keep the eye picture at half width or height.
- **Output size** stays the input's, see Output. The side by side and above below outputs squeeze each eye into half the frame, like FFmpeg's `sbs2l` and `ab2l`; there is no full-size (`sbsl` that doubles the width) variant. The two inputs `sbsl`/`sbs2l` (and `abl`/`ab2l`...) are the same here.
- **Not ported**: the alternating frames layouts (`al`, `ar`, they need two frames) and `hdmi` (it adds blank lines, so the size changes).
- Anaglyph colors are computed in floating point; FFmpeg uses integers on 8-bit RGB, so a value can differ by one.
- Eye resampling is bilinear for side by side and above below inputs and nearest for the interleaved ones.
