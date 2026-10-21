# Crossfade Custom Expression

Transition from the first to the second input, where every pixel and channel is an expression of X, Y, W, H, P, A and B. Drive `progress` from 0 to 1.

Port of FFmpeg's `xfade` with `transition=custom:expr=...` (`libavfilter/vf_xfade.c`).

## Inputs

- `first`: outgoing clip
- `second`: incoming clip (must have the same size as the first input)

## Output

Same size as the first input. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `xfade-custom.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. Parameters of type `expr` are GPU expressions (api 2, see [Expression parameters](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md#expression-parameters)): numbers, the listed variables, `pi`, `tau`, `e`, `+ - * / ^`, and the functions `sin cos tan asin acos atan atan2 abs sign min max clamp mix step smoothstep pow sqrt exp log floor ceil round fract` only (no `if`, `gt`, `lt`, `mod`: use `step`, `mix`, `fract`); commas inside an FFmpeg command line are escaped as `\,`. The other values are literals or FFmpeg expressions in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip; at exactly 0 and 1 the output is forced to the first / second clip |
| `expr` | expr | `A*P + B*(1-P)` | - | Result for one color channel, 0..255. X, Y pixel position, W, H size, P = 1 - progress (FFmpeg's P: 1 at the start, 0 at the end), A and B the channel value of the first / second clip, 0..255 |

## Differences from FFmpeg

- The expression runs once per pixel and color channel with `A`/`B` being that channel of the first / second clip on the 0..255 scale. FFmpeg evaluates the planes of the stored frame (Y, U, V for most videos), gpufx the RGB channels, so an expression that treats the channels differently gives a different picture; the common ones (mix, wipes, masks by position) look the same.
- `P` is FFmpeg's `P`: **1 at the start of the transition and 0 at the end** (the parameter `progress` here goes 0 to 1, `P = 1 - progress`). The default `A*P + B*(1-P)` is a plain crossfade.
- At `progress` 0 the output is exactly the first clip and at 1 exactly the second clip (forced, whatever the expression gives); in between the result is clamped to 0..255. FFmpeg does not clamp (an out-of-range value wraps).
- Alpha is blended linearly with `progress`; the expression does not see an alpha plane.
- No `PLANE` variable and no comparison functions (`gt`, `lt`, `if`): use `step(edge,x)` and `mix`. FFmpeg's `if(gt(X,W*P),A,B)` is `mix(B,A,step(X,W*P))` (the two differ only at exact equality, since `step(e,x)` is 1 when `x >= e`).
- The duration/offset of FFmpeg's `xfade` filter are replaced by `progress`: drive it with an FFmpeg expression of `t`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='xfade-custom.zip=progress=clip((t-1)/1.5\,0\,1)&expr=mix(B\\,A\\,step(X\\,W*P))',hwdownload,format=yuv420p" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).
