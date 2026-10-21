# realesr-animevideov3

Real-ESRGAN `realesr-animevideov3` super-resolution model as a gpufx-nn bundle (`io.json` kind
`super_resolution`), for the FFmpeg filter `gpufx_ai_upscale` of the gpufx project. The bundle holds the x2, x3
and x4 scale variants; pick one at run time with `scale=`.

## Source

The weights are the ncnn `realesr-animevideov3` (SRVGGNetCompact) models of
[Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) (Real-ESRGAN: Training Real-World Blind Super-Resolution
with Pure Synthetic Data, Wang et al.), converted by `gpufx-nnconv`. The pinned URLs and sha256 are in
`packages/gpufx_ai_upscale/realesr-animevideov3/source.json` of the gpufx repository; they match the official
`realesrgan-ncnn-vulkan` release. The x2 and x3 graphs run the x4 network and bicubic-downscale the result, as in
the original models.

## Use

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_upscale=model=realesr-animevideov3.zip:scale=2,gpufx_download,format=nv12" out.mp4
```

`scale=` selects the 2, 3 or 4 variant of the bundle. See the gpufx README for all options.

## License

See the `LICENSE` file in this package (BSD 3-Clause): the license of the converted model files. Read it before
redistributing the package.
