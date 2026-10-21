# Crossfade (xfade)

Transition from the first to the second input with any transition of FFmpeg's `xfade` filter (`transition=wipeleft`...), or with an expression (`transition=custom`). Drive `progress` from 0 to 1.

Port of FFmpeg's `xfade` (`libavfilter/vf_xfade.c`): all 58 transitions of its `XFadeTransitions` enum plus `custom`, under the same names (FFmpeg's numbers also work).

## Inputs

- `first`: outgoing clip
- `second`: incoming clip (must have the same size as the first input)

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `xfade.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. Parameters of type `expr` are GPU expressions (api 2, see [Expression parameters](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md#expression-parameters)): numbers, the listed variables, `pi`, `tau`, `e`, `+ - * / ^`, and the functions `sin cos tan asin acos atan atan2 abs sign min max clamp mix step smoothstep pow sqrt exp log floor ceil round fract` only (no `if`, `gt`, `lt`, `mod`: use `step`, `mix`, `fract`); commas inside an FFmpeg command line are escaped as `\,`. The other values are literals or FFmpeg expressions in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `transition` | enum | `fade` | see below | FFmpeg's transition name (or its number), see the table below |
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip; at exactly 0 and 1 the output is forced to the first / second clip |
| `expr` | expr | `A*P + B*(1-P)` | - | Only for `transition=custom`. Result for one color channel, 0..255. `X`, `Y` pixel position, `W`, `H` size, `P` = 1 - progress (FFmpeg's `P`: 1 at the start, 0 at the end), `A` and `B` the channel value of the first / second clip, 0..255, `PLANE` the channel: 0, 1, 2 = R, G, B |

### Transitions

The numbers are the values of FFmpeg's `XFadeTransitions` enum (the names are those of FFmpeg's `transition=` option); `-1` is `custom`.

| Number | FFmpeg name |
|--------|-------------|
| -1 | `custom` |
| 0 | `fade` |
| 1 | `wipeleft` |
| 2 | `wiperight` |
| 3 | `wipeup` |
| 4 | `wipedown` |
| 5 | `slideleft` |
| 6 | `slideright` |
| 7 | `slideup` |
| 8 | `slidedown` |
| 9 | `circlecrop` |
| 10 | `rectcrop` |
| 11 | `distance` |
| 12 | `fadeblack` |
| 13 | `fadewhite` |
| 14 | `radial` |
| 15 | `smoothleft` |
| 16 | `smoothright` |
| 17 | `smoothup` |
| 18 | `smoothdown` |
| 19 | `circleopen` |
| 20 | `circleclose` |
| 21 | `vertopen` |
| 22 | `vertclose` |
| 23 | `horzopen` |
| 24 | `horzclose` |
| 25 | `dissolve` |
| 26 | `pixelize` |
| 27 | `diagtl` |
| 28 | `diagtr` |
| 29 | `diagbl` |
| 30 | `diagbr` |
| 31 | `hlslice` |
| 32 | `hrslice` |
| 33 | `vuslice` |
| 34 | `vdslice` |
| 35 | `hblur` |
| 36 | `fadegrays` |
| 37 | `wipetl` |
| 38 | `wipetr` |
| 39 | `wipebl` |
| 40 | `wipebr` |
| 41 | `squeezeh` |
| 42 | `squeezev` |
| 43 | `zoomin` |
| 44 | `fadefast` |
| 45 | `fadeslow` |
| 46 | `hlwind` |
| 47 | `hrwind` |
| 48 | `vuwind` |
| 49 | `vdwind` |
| 50 | `coverleft` |
| 51 | `coverright` |
| 52 | `coverup` |
| 53 | `coverdown` |
| 54 | `revealleft` |
| 55 | `revealright` |
| 56 | `revealup` |
| 57 | `revealdown` |

### progress, offset and duration

FFmpeg's `xfade` has the options `offset` (when the transition starts) and `duration`; gpufx sees single frames, so the effect has one `progress` instead: the transition runs while it goes from 0 to 1. The same as FFmpeg's `offset=OFFSET:duration=DURATION` is

```
progress=clip((t-OFFSET)/DURATION\,0\,1)
```

(inside the graph `t` is the time of the frame in seconds, so it has to be the time within the output of the filter; with a non-zero start of the second clip subtract it as with any gpufx transition.) FFmpeg itself works with `P = 1 - progress`, which is what `P` in `expr` is.

## Differences from FFmpeg

- FFmpeg computes on the planes of the stored frame (Y, U, V for most videos, with the chroma planes at their own resolution); gpufx computes on the RGBA channels of the full-size picture. For the pure picking transitions (wipes, slides, cover/reveal, crops, pixelize...) the result is the same; the color-processing ones (`distance`, `fadegrays`, `fadefast`, `fadeslow`) differ slightly, because the difference or the gray is taken on RGB (`distance` converts to YUV with BT.601 for the difference; `fadegrays` dips to the luma of each clip, as for YUV video). `fadegrays` takes the gray as BT.601 luma (FFmpeg: Y on YUV input, the plain (R+G+B)/3 on RGB input).
- `progress` 0 is exactly the first clip and `progress` 1 exactly the second clip (forced). FFmpeg's integer comparisons leave a column/row or the corner pixel of the wrong clip at the ends of the wipes and of `distance`, and `circlecrop`/`rectcrop` blank the outer ring there. Between the ends the formulas are FFmpeg's.
- `radial` sweeps 2 * (pi + 1) instead of FFmpeg's 2.5 * pi so that the second clip is complete at `progress` 1. `circlecrop` and `rectcrop` compare with `<=` instead of `<` (and on float sizes, so mid-transition the box is up to one pixel larger; at progress 0.5 the centre row and column still show). `squeezeh` and `squeezev` scale the rows (columns) with `size - 1`, so the start is the first clip pixel for pixel.
- The random ones (`dissolve`, the four winds) use FFmpeg's `fract(sin(x * 12.9898 + y * 78.233) * 43758.545)`. GPUs compute `sin` of large arguments less precisely than a CPU and differently from each other, so the ragged edge can differ from FFmpeg's and between GPUs.
- `hblur` averages up to width / 2 taps per pixel at the middle of the transition, so on 4K it may be slow enough to hit a GPU timeout.
- `custom`: the expression runs per pixel and color channel with `A`/`B` on the 0..255 scale; `PLANE` is 0, 1, 2 for R, G, B where FFmpeg's planes are usually Y, U, V (so an expression that treats the planes differently gives another picture). The results are clamped to 0..255 (FFmpeg wraps), alpha is blended linearly with `progress`. FFmpeg's pixel functions `a0`..`a3` and `b0`..`b3` (read the clip at any position) do not exist, and neither do the comparison functions `gt`, `lt`, `if`: use `step` and `mix`. FFmpeg's `if(gt(X,W*P),A,B)` is `mix(B,A,step(X,W*P))`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='xfade.zip=transition=circleopen&progress=clip((t-1)/1.5\,0\,1)',hwdownload,format=yuv420p" out.mp4
```

Custom expression (a wipe, `transition=custom`):

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='xfade.zip=transition=custom&progress=clip((t-1)/1.5\,0\,1)&expr=mix(B\,A\,step(X\,W*P))',hwdownload,format=yuv420p" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

Still pictures with the CLI:

```sh
./target/release/gpufx run '[0][1]packages/gpufx/ffmpeg/xfade=transition=wipeleft:progress=0.5' -i a.png -i b.png -o out.png
```
