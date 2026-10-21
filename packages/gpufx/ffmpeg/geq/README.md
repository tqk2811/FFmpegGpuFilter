# Generic Equation

Per-pixel red, green, blue and alpha expressions of the position, the time and the pixel's own channel values.

Port of FFmpeg's `geq` (`libavfilter/vf_geq.c`), RGB expressions only.

## Inputs

- `src`: any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `geq.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. Parameters of type `expr` are GPU expressions (api 2, see [Expression parameters](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md#expression-parameters)): numbers, the listed variables, `pi`, `tau`, `e`, `+ - * / ^`, and the functions `sin cos tan asin acos atan atan2 abs sign min max clamp mix step smoothstep pow sqrt exp log floor ceil round fract` only (no `if`, `gt`, `lt`, `mod`: use `step`, `mix`, `fract`); commas inside an FFmpeg command line are escaped as `\,`. The other values are literals or FFmpeg expressions in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `fps` | float | `25` | 1 to 240 | Frame rate used to compute N from the time |
| `r` | expr | `R` | - | Red expression, result 0..255 |
| `g` | expr | `G` | - | Green expression, result 0..255 |
| `b` | expr | `B` | - | Blue expression, result 0..255 |
| `a` | expr | `A` | - | Alpha expression, result 0..255 |

## Differences from FFmpeg

- Variables: `X`, `Y` (pixel column and row), `W`, `H` (size), `T` (seconds), `N` (frame number, `floor(T*fps)`), and the current pixel's `R`, `G`, `B`, `A`, all on the 0..255 scale as in FFmpeg's 8-bit `geq`. Results are 0..255 (clamped).
- **No `p(x,y)` pixel access.** An `expr` is a pure math expression and cannot sample the picture, so `r(X+1,Y)`, `lum()`, `cb()`, `cr()`, `alpha()`, `p()` and the like do not exist. Only the current pixel's own values are available, which covers per-pixel color maps, procedural patterns and time animation, but not neighbor-based filters or geometric warps.
- Always RGB (FFmpeg's `geq` works in YUV, `lum_expr`/`cb_expr`/`cr_expr`, unless `r`/`g`/`b` are given); there is no `interpolation`, no `lum`/`cb`/`cr`/`alpha` options and no `SW`/`SH` (chroma subsampling) variables.
- `N` is computed from the exact time and `fps` (default 25) so seeking and dropped frames do not shift it.
- Operators `<`, `>`, `==`, `%`, `if`, `lt`, `gt`... are not available; use `step(edge,x)`, `mix`, `fract`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='geq.zip=r=R*(1-X/W)+255*X/W&g=G&b=B*(1-Y/H)',hwdownload,format=nv12" out.mp4

# a time animation
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='geq.zip=r=127.5+127.5*sin(T*2+X/50)',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).
