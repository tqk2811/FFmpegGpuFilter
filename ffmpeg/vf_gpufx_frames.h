/*
 * Frame description helpers shared by the gpufx filters that hand GPU frames to libgpufx
 * (gpufx, gpufx_ai_framerate): colour properties and Vulkan frames.
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef AVFILTER_VF_GPUFX_FRAMES_H
#define AVFILTER_VF_GPUFX_FRAMES_H

#include <string.h>
#include <gpufx.h>

#include "config.h"
#include "libavutil/attributes.h"
#include "libavutil/error.h"
#include "libavutil/frame.h"
#include "libavutil/hwcontext.h"
#include "libavutil/log.h"
#include "libavutil/pixdesc.h"
#if CONFIG_VULKAN
#include "libavutil/hwcontext_vulkan.h"
#endif
#include "avfilter.h"

static av_unused int has_alpha(enum AVPixelFormat fmt)
{
    return !!(av_pix_fmt_desc_get(fmt)->flags & AV_PIX_FMT_FLAG_ALPHA);
}

/* GPUFX_MATRIX_* of a colorspace, or -1 when only swscale converts it. */
static av_unused int gpu_matrix(enum AVColorSpace cs)
{
    switch (cs) {
    case AVCOL_SPC_BT709:      return GPUFX_MATRIX_BT709;
    case AVCOL_SPC_BT2020_NCL: return GPUFX_MATRIX_BT2020;
    /* Unknown matrices are BT.601 for swscale too. */
    case AVCOL_SPC_UNSPECIFIED:
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M:  return GPUFX_MATRIX_BT601;
    default:                   return -1;
    }
}

static av_unused uint32_t gpu_chroma_location(const AVFrame *f, int full_range)
{
    switch (f->chroma_location) {
    case AVCHROMA_LOC_CENTER:     return GPUFX_CHROMA_CENTER;
    case AVCHROMA_LOC_TOPLEFT:    return GPUFX_CHROMA_TOPLEFT;
    case AVCHROMA_LOC_TOP:        return GPUFX_CHROMA_TOP;
    case AVCHROMA_LOC_BOTTOMLEFT: return GPUFX_CHROMA_BOTTOMLEFT;
    case AVCHROMA_LOC_BOTTOM:     return GPUFX_CHROMA_BOTTOM;
    case AVCHROMA_LOC_LEFT:       return GPUFX_CHROMA_LEFT;
    /*
     * Unspecified: centred for full range (JPEG/MJPEG convention), else left (the
     * MPEG-2/H.264 default). swscale makes its own guess on the frames it converts.
     */
    default:                      return full_range ? GPUFX_CHROMA_CENTER : GPUFX_CHROMA_LEFT;
    }
}

/* fmt: the format of the pixels, f->format or the sw_format of a hardware frame. */
static av_unused uint32_t alpha_flags_fmt(const AVFrame *f, enum AVPixelFormat fmt)
{
    return f->alpha_mode == AVALPHA_MODE_PREMULTIPLIED && has_alpha(fmt) ?
           GPUFX_FRAME_PREMULTIPLIED : 0;
}

/*
 * Colour properties of f for libgpufx. Returns the format name when the GPU converts
 * f as it is, or NULL when swscale must convert it (other formats or matrices).
 */
static av_unused const char *gpu_color_fmt(const AVFrame *f, enum AVPixelFormat fmt, GpufxColor *c)
{
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(fmt);
    int matrix = GPUFX_MATRIX_BT601;

    if (!gpufx_format_supported(desc->name))
        return NULL;
    if (!(desc->flags & AV_PIX_FMT_FLAG_RGB) && (matrix = gpu_matrix(f->colorspace)) < 0)
        return NULL;
    c->matrix          = matrix;
    /* yuvj formats are full range whatever the frame says, as for swscale. */
    c->range           = f->color_range == AVCOL_RANGE_JPEG || !strncmp(desc->name, "yuvj", 4) ?
                         GPUFX_RANGE_FULL : GPUFX_RANGE_LIMITED;
    c->chroma_location = gpu_chroma_location(f, c->range == GPUFX_RANGE_FULL);
    c->flags           = alpha_flags_fmt(f, fmt);
    return desc->name;
}


#if CONFIG_VULKAN
static av_unused int vk_fill(AVFilterContext *ctx, const AVFrame *f, GpufxVulkanFrame *v, const char *what)
{
    AVHWFramesContext *fc = (AVHWFramesContext *)f->hw_frames_ctx->data;
    AVVulkanFramesContext *vkfc = fc->hwctx;
    AVVkFrame *vkf = (AVVkFrame *)f->data[0];
    const char *name = gpu_color_fmt(f, fc->sw_format, &v->color);

    if (!name) {
        av_log(ctx, AV_LOG_ERROR, "%s: Vulkan frames of %s in colorspace %s are not converted on the "
               "GPU; set a supported matrix (BT.601, BT.709, BT.2020) before uploading.\n", what,
               av_get_pix_fmt_name(fc->sw_format), av_color_space_name(f->colorspace));
        return AVERROR(ENOSYS);
    }
    v->format    = name;
    v->width     = f->width;
    v->height    = f->height;
    v->nb_images = 0;
    for (int j = 0; j < 4 && vkf->img[j]; j++) {
        v->image[j]        = (uint64_t)vkf->img[j];
        v->vk_format[j]    = vkfc->format[j];
        v->layout[j]       = vkf->layout[j];
        v->semaphore[j]    = (uint64_t)vkf->sem[j];
        v->sem_value[j]    = vkf->sem_value[j];
        v->queue_family[j] = vkf->queue_family[j];
        v->nb_images++;
    }
    return 0;
}

static av_unused void vk_store(const AVFrame *f, const GpufxVulkanFrame *v)
{
    AVVkFrame *vkf = (AVVkFrame *)f->data[0];

    for (uint32_t j = 0; j < v->nb_images; j++) {
        vkf->layout[j]    = v->layout[j];
        vkf->sem_value[j] = v->sem_value[j];
        vkf->access[j]    = VK_ACCESS_2_SHADER_READ_BIT | VK_ACCESS_2_SHADER_WRITE_BIT;
    }
}

#endif

#endif /* AVFILTER_VF_GPUFX_FRAMES_H */
