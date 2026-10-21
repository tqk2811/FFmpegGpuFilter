# Mandelbrot

Mandelbrot set zooming in over time (generator).

Precision: the shader uses f32 (FFmpeg uses double), so the picture turns blocky after about 60 s at the default zoom speed, when the view gets too small for f32 to tell neighbouring pixels apart.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU. It only sets the size (see Notes).

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `mandelbrot.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `start_x` | float | `-0.7436438870371587` | -2 to 2 | Real part of the zoom center |
| `start_y` | float | `-0.13182590420531198` | -2 to 2 | Imaginary part of the zoom center |
| `start_scale` | float | `3` | 0.00001 to 100 | View height in the complex plane at time 0 |
| `end_scale` | float | `0.3` | 0.00001 to 100 | View height in the complex plane at `end_time` |
| `end_time` | float | `16` | 0.001 to 100000 | Seconds to go from `start_scale` to `end_scale` (exponentially; goes on past it) |
| `maxiter` | int | `255` | 1 to 2000 | Iteration limit per pixel (capped at 2000) |
| `bailout` | float | `10` | 2 to 1000 | Escape radius |
| `inner_mode` | int | `0` | 0 to 2 | Points inside the set: 0 black, 1 white, 2 colored by the last z |
| `outer_mode` | int | `1` | 0 to 3 | Points outside: 0 iteration count, 1 smooth iteration count, 2 white, 3 colored by the escaping z |
| `opacity` | float | `1` | 0 to 1 | Blend over the input picture: 1 = only the generated picture, 0 = the input unchanged |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -f lavfi -i color=black:s=1280x720:r=25 \
  -vf "format=nv12,gpufx=graph='mandelbrot.zip=end_time=10&maxiter=400',hwdownload,format=nv12" -t 10 out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'mandelbrot.zip=end_time=10:maxiter=400' -i in.png -o out.png
```

## Notes

Port of FFmpeg's `mandelbrot` source (vsrc_mandelbrot.c). Differences: the zoom is a function of time `t` in seconds (`end_time`, FFmpeg's `end_pts` is in time-base ticks); the default `maxiter` is 255 and the cap 2000 (FFmpeg: 7189) to bound the per-pixel loop; coloring is a cosine palette (FFmpeg uses its own color table) and only the `black`/`white`/`outz`-like inner modes and the `iteration_count`/`normalized_iteration_count`/`white`/`outz`-like outer modes are ported (no `period`, `convergence`, `mincol`, `morphing`); no orbit cache. The math runs in f32, so zoom ratios beyond about 1e-4 of the view height turn blocky; keep `end_scale` above about 0.0005 for a 1080 px picture.

The effect has no source of its own: gpufx effects always have an input, so the input `src` only sets the size (and is blended in by `opacity`). Use any video of the wanted size, for example `-f lavfi -i color=black:s=1280x720:r=25`.
