/*
 * Vulkan frames helpers shared by the gpufx filters.
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

#ifndef AVFILTER_VF_GPUFX_VK_H
#define AVFILTER_VF_GPUFX_VK_H

#include "config.h"
#include "libavutil/attributes.h"
#include "libavutil/frame.h"
#include "libavutil/hwcontext.h"
#include "libavutil/mem.h"
#include "libavutil/pixdesc.h"
#if CONFIG_VULKAN
#include "libavutil/hwcontext_vulkan.h"
#endif

#if CONFIG_VULKAN
/*
 * Whether fc holds each frame in one multiplane image whose planes libgpufx copies to and
 * from its own images (gpufx-core vulkan.rs, multiplane_vk_format).
 */
static av_unused int gpufx_vk_multiplane_known(const AVHWFramesContext *fc)
{
    const AVVulkanFramesContext *vk = fc->hwctx;

    if (av_pix_fmt_count_planes(fc->sw_format) < 2 || vk->format[1] != VK_FORMAT_UNDEFINED)
        return 0;
    switch (vk->format[0]) {
    case VK_FORMAT_G8_B8R8_2PLANE_420_UNORM:
    case VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16:
    case VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM:
    case VK_FORMAT_G8_B8_R8_3PLANE_422_UNORM:
    case VK_FORMAT_G8_B8_R8_3PLANE_444_UNORM:
    case VK_FORMAT_G16_B16_R16_3PLANE_420_UNORM:
    case VK_FORMAT_G16_B16_R16_3PLANE_422_UNORM:
    case VK_FORMAT_G16_B16_R16_3PLANE_444_UNORM:
        return 1;
    default:
        return 0;
    }
}
#endif

/*
 * Output frames of w x h fmt in one multiplane image each, as FFmpeg makes them itself
 * (hwupload, decoders) on a device opened without disable_multiplane=1: Vulkan encoders
 * (h264_vulkan...) take only those. libgpufx writes its own single-plane images, then
 * copies them into the planes, so no storage usage is needed. NULL when the device makes
 * one image per plane (disable_multiplane=1), the format has no such image libgpufx knows,
 * or the images cannot be copied into: the caller then makes per-plane storage images.
 */
static av_unused AVBufferRef *gpufx_vk_multiplane_frames(AVBufferRef *device, enum AVPixelFormat fmt,
                                                         int w, int h)
{
#if CONFIG_VULKAN
    AVBufferRef *ref;
    AVHWFramesContext *fc;
    AVVulkanFramesContext *vk;

    if (av_pix_fmt_count_planes(fmt) < 2 || !(ref = av_hwframe_ctx_alloc(device)))
        return NULL;
    fc            = (AVHWFramesContext *)ref->data;
    fc->format    = AV_PIX_FMT_VULKAN;
    fc->sw_format = fmt;
    fc->width     = w;
    fc->height    = h;
    vk            = fc->hwctx;
    /* FFmpeg adds what else the format supports (storage, video encode source...). */
    vk->usage     = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                    VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if (av_hwframe_ctx_init(ref) < 0 || !gpufx_vk_multiplane_known(fc) ||
        !(vk->usage & VK_IMAGE_USAGE_TRANSFER_DST_BIT))
        av_buffer_unref(&ref);
    return ref;
#else
    return NULL;
#endif
}

#endif /* AVFILTER_VF_GPUFX_VK_H */
