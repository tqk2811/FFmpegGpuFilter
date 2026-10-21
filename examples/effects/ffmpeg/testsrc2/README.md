# Test Source 2

FFmpeg testsrc2 test pattern: bands, gradient strip, clock hands, rectangles, noise, bouncing square (generator).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU. It only sets the size (see Notes).

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `testsrc2.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `rate` | float | `25` | 1 to 240 | Frames per second that the frame counter `pts` of the noise follows (the motion itself uses the time `t`) |
| `opacity` | float | `1` | 0 to 1 | Blend over the input picture: 1 = only the generated picture, 0 = the input unchanged |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -f lavfi -i color=black:s=1280x720:r=25 \
  -vf "format=nv12,gpufx=graph='testsrc2.zip',hwdownload,format=nv12" -t 10 out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'testsrc2.zip' -i in.png -o out.png
```

## Notes

Port of FFmpeg's `testsrc2` source (vsrc_testsrc.c). Differences: the box with the time and frame number at the top left is not ported (no font); the noise of the checker is an integer hash of pixel and frame, not FFmpeg's linear congruential sequence; `alpha` is the `opacity` parameter. Everything else (six bands, the oblique gradient strip, three clock hands, beating rectangles, the bouncing 8x8 square) is a function of `t`.

The effect has no source of its own: gpufx effects always have an input, so the input `src` only sets the size (and is blended in by `opacity`). Use any video of the wanted size, for example `-f lavfi -i color=black:s=1280x720:r=25`.
