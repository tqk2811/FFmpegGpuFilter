# realesr-general-x4v3

Real-ESRGAN `realesr-general-x4v3` super-resolution model as a gpufx-nn bundle (`io.json` kind
`super_resolution`), for the FFmpeg filter `gpufx_ai_upscale` of the gpufx project. The bundle holds the single x4
scale variant; select it at run time with `scale=4`.

## Source

The weights are the ncnn `realesr-generalv3-x4` (SRVGGNetCompact) model of
[Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) (Real-ESRGAN: Training Real-World Blind Super-Resolution
with Pure Synthetic Data, Wang et al.), converted by `gpufx-nnconv`. The pinned URLs and sha256 are in
`models/realesr-general-x4v3/source.json` of the gpufx repository; they match the official
`realesrgan-ncnn-vulkan` release. The graph ends with a clip to `[0, 1]`.

## Use

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx_ai_upscale=model=realesr-general-x4v3.zip:scale=4,gpufx_download,format=nv12" out.mp4
```

## License

See the `LICENSE` file in this package (BSD 3-Clause): the license of the converted model files. Read it before
redistributing the package.
