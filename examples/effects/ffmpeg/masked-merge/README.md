# Masked Merge

Port of FFmpeg's `maskedmerge` filter: merge the base and overlay clips through a mask. Where the mask is black the output is the base, where it is white the overlay, in between a mix: `base * (1 - mask) + overlay * mask`.

FFmpeg uses the mask plane that matches each YUV plane; gpufx works on RGB, so each RGB channel is merged with the same channel of the mask (a gray mask gives the same result on all three). The output alpha is the alpha of the base.

## Inputs

- `base`: Base clip (where the mask is black)
- `overlay`: Overlay clip (where the mask is white, must have the same size as the base)
- `mask`: Mask clip (must have the same size as the base)

## Output

Same size as the first input (`base`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

None.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i base.mp4 -i overlay.mp4 -i mask.mp4 -filter_complex \
  "[0][1][2]gpufx=graph='masked-merge.zip',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i base.mp4 -i overlay.mp4 -i mask.mp4 -filter_complex \
  "[0][1][2]gpufx=graph='masked-merge.zip',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on three PNGs:

```sh
gpufx run 'masked-merge.zip' -i base.png -i overlay.png -i mask.png -o out.png
```
