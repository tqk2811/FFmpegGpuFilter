# rife-v4.6

RIFE v4.6 frame interpolation model as a gpufx-nn package (`io.json` kind `frame_interp`), for the FFmpeg filter
`gpufx_ai_framerate` of the gpufx project.

## Source

The weights are the ncnn model `models/rife-v4.6` of
[nihui/rife-ncnn-vulkan](https://github.com/nihui/rife-ncnn-vulkan) (RIFE: Real-Time Intermediate Flow Estimation
for Video Frame Interpolation, Huang et al.), converted by `gpufx-nnconv`. The pinned URLs and sha256 are in
`models/rife-v4.6/source.json` of the gpufx repository.

## Use

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_framerate=model=rife-v4.6.zip,gpufx_download,format=nv12" out.mp4
```

The default output rate is twice the input's; `fps=` sets another one. See the gpufx README for all options.

## Performance

Measured on an RTX 4060 Laptop GPU, per interpolated frame:

| Size | Vulkan |
|---|---|
| 1080p | about 45 ms |
| 4K | about 174 ms |

D3D12 and D3D11 are about 1.7x slower than Vulkan on the same GPU, so prefer Vulkan when it is available. The
first run compiles the shaders (set `GPUFX_SHADER_CACHE` to keep them). The VideoToolbox (macOS) path and the
linux64 bundle have not been tested.

## License

See the `LICENSE` file in this package: the license of the converted model files. Read it before redistributing
the package.
