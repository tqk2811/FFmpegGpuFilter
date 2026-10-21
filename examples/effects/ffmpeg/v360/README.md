# V360

Port of FFmpeg's `v360`: converts 360 degree video between projections and rotates the view.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU. The whole frame is read as the `input` projection.

## Output

Same size as the first input (`src`), laid out as the `output` projection. FFmpeg picks the output size from the projections (for example equirect 2:1 to cubemap 3x2 gives 3:2); gpufx effects cannot resize, so here the output always has the input's size and the projection is drawn into it. Choose the input size for the shape you want (2:1 for equirect, 3:2 for `cube3x2`, 6:1 for `cube6x1`, 1:6 for `cube1x6`, 1:1 for `ball`, `fisheye`, `octahedron`...), or use `d_fov` so the flat, fisheye and similar projections follow the frame's aspect ratio. Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `NAME.zip=name=value`. Several options are separated by `&` in an FFmpeg `graph='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `input` | int | `0` | 0 to 19 | Input projection, see the list below |
| `output` | int | `1` | 0 to 19 | Output projection, same numbering |
| `interp` | int | `1` | 0 to 2 | Interpolation: 0 nearest, 1 linear, 2 cubic (FFmpeg `bicubic`) |
| `yaw` | float | `0` | -360 to 360 | Yaw rotation in degrees |
| `pitch` | float | `0` | -360 to 360 | Pitch rotation in degrees |
| `roll` | float | `0` | -360 to 360 | Roll rotation in degrees |
| `rorder` | int | `0` | 0 to 5 | Rotation order: 0 ypr, 1 yrp, 2 pyr, 3 pry, 4 ryp, 5 rpy |
| `h_fov`, `v_fov` | float | `0` | 0 to 360 | Output field of view in degrees; 0 = the default of the projection (flat and cylindrical 90x45, equisolid, orthographic, stereographic, fisheye and dfisheye 180x180, others 360x180) |
| `d_fov` | float | `0` | 0 to 360 | Output diagonal field of view; above 0 it replaces `h_fov` and `v_fov` using the frame size |
| `ih_fov`, `iv_fov`, `id_fov` | float | `0` | 0 to 360 | The same for the input |
| `h_flip`, `v_flip`, `d_flip` | bool | `false` | | Flip the output horizontally, vertically or in depth |
| `ih_flip`, `iv_flip` | bool | `false` | | Flip the input horizontally or vertically |
| `h_offset`, `v_offset` | float | `0` | -1 to 1 | Output off-axis offset |
| `background` | color | `#000000` | RGBA | Fill where the output projection or the input does not cover the sphere |

Projections (`input` and `output`): 0 equirect, 1 cube3x2, 2 cube6x1, 3 cube1x6, 4 eac (equi-angular cubemap), 5 flat, 6 dfisheye (dual fisheye), 7 fisheye, 8 stereographic, 9 mercator, 10 ball, 11 hammer, 12 sinusoidal, 13 pannini, 14 cylindrical, 15 cylindricalea (cylindrical equal area), 16 equisolid, 17 orthographic, 18 octahedron, 19 hequirect (half equirect).

## Example

Equirectangular video to a view looking 40 degrees to the right (a flat view with a 100 degree diagonal field of view):

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=graph='v360.zip=input=0&output=5&yaw=40&d_fov=100',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=graph='v360.zip=input=0&output=5&yaw=40&d_fov=100',hwdownload,format=nv12" out.mp4
```

## Notes

Differences from FFmpeg:

- **Output size**: the same as the input's, see Output. `w` and `h` do not exist.
- **Not ported**: `barrel`, `barrelsplit` (Facebook formats), `tsp`, `tetrahedron`, `perspective` (output only), the stereo options `in_stereo` and `out_stereo`, `in_trans` and `out_trans`, the cube face options `in_forder`, `in_frot`, `out_forder`, `out_frot` (the default order `rludfb` with no rotation is used), the cube pads `in_pad`, `out_pad`, `fin_pad`, `fout_pad`, `alpha_mask`, `reset_rot` and the interpolations `lagrange9`, `lanczos`, `spline16`, `gauss` and `mitchell`.
- **Uncovered pixels**: FFmpeg paints the pixel (0, 0) of the input where an input projection with a limited view (flat, fisheye, stereographic, equisolid, orthographic, pannini, cylindrical...) or an output projection with a limited shape (ball, hammer, equisolid, orthographic) does not cover the sphere. gpufx paints `background`.
- **Cubemap seams**: the interpolation window of `cube3x2`, `cube6x1` and `cube1x6` inputs stays inside the face (FFmpeg reads the neighbour face), so the edges between faces can differ slightly with linear and cubic interpolation. `nearest` matches.
- **Angles** go to 360 degrees in either direction (FFmpeg 180).
- On the same test image (equirect, 512x256) the results of FFmpeg 8.0 and gpufx agree to about 60 dB PSNR for the ported projections.