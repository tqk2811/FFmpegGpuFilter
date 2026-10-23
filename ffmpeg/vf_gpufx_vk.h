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

/*
 * av_hwframe_ctx_init() for a frames context gpufx creates, without host image copy.
 *
 * FFmpeg 9 adds VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT to every Vulkan frames context when
 * VK_EXT_host_image_copy is enabled (except on NVIDIA/MoltenVK), whatever usage the caller
 * set, and then av_hwframe_transfer_data() copies with the host. The Intel Windows driver
 * fails to allocate such images (rgba, single-plane) or corrupts multi-planar host copies:
 * see docs/INTEL_VULKAN.md. The images are made at the first frame, so dropping the flag
 * right after the init gives images without it, and transfers take the buffer path.
 * The initial pool is allocated after that, by hand (the Vulkan pool grows as needed).
 * This relies on hwcontext_vulkan.c of FFmpeg 9.0 (03d9533): images made in vulkan_pool_alloc,
 * and prepare_frame/transfers reading usage per call. Re-check it on every FFmpeg update.
 * The test image of the init still has the flag: a driver that refuses to create it fails.
 */
static av_unused int gpufx_hwframe_ctx_init(AVBufferRef *ref)
{
#if CONFIG_VULKAN
    AVHWFramesContext *fc = (AVHWFramesContext *)ref->data;
    AVFrame **frames;
    int n = fc->initial_pool_size, ret = 0, i;

    if (fc->format != AV_PIX_FMT_VULKAN)
        return av_hwframe_ctx_init(ref);
    fc->initial_pool_size = 0;
    ret = av_hwframe_ctx_init(ref);
    fc->initial_pool_size = n;
    if (ret < 0)
        return ret;
    ((AVVulkanFramesContext *)fc->hwctx)->usage &= ~VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT;
    if (n <= 0)
        return 0;
    if (!(frames = av_calloc(n, sizeof(*frames))))
        return AVERROR(ENOMEM);
    for (i = 0; i < n && ret >= 0; i++)
        if (!(frames[i] = av_frame_alloc()))
            ret = AVERROR(ENOMEM);
        else
            ret = av_hwframe_get_buffer(ref, frames[i], 0);
    for (i = 0; i < n; i++)
        av_frame_free(&frames[i]);
    av_free(frames);
    return ret;
#else
    return av_hwframe_ctx_init(ref);
#endif
}

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
    if (gpufx_hwframe_ctx_init(ref) < 0 || !gpufx_vk_multiplane_known(fc) ||
        !(vk->usage & VK_IMAGE_USAGE_TRANSFER_DST_BIT))
        av_buffer_unref(&ref);
    return ref;
#else
    return NULL;
#endif
}

/*
 * Whether Vulkan frames made elsewhere (hwupload) are copied by FFmpeg with the host on the
 * Intel Windows driver in a way that fails or corrupts the picture: host image copy on an
 * optimal-tiling image (allocation fails) or on a multi-planar image (chroma lands in plane 0).
 * Linear single-plane images (disable_multiplane=1,linear_images=1) copy fine. Decoder frames
 * are written by the GPU, not by host copies.
 */
static av_unused int gpufx_vk_host_copy_broken(AVHWFramesContext *fc)
{
#if CONFIG_VULKAN
    const AVVulkanFramesContext *vk;
    const AVVulkanDeviceContext *dev;
    PFN_vkGetPhysicalDeviceProperties2 props2;
    VkPhysicalDeviceDriverProperties drv = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
    };
    VkPhysicalDeviceProperties2 props = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
        .pNext = &drv,
    };
    int multiplane;

    if (fc->format != AV_PIX_FMT_VULKAN)
        return 0;
    vk = fc->hwctx;
    if (!(vk->usage & VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT) ||
        (vk->usage & VK_IMAGE_USAGE_VIDEO_DECODE_DST_BIT_KHR))
        return 0;
    multiplane = av_pix_fmt_count_planes(fc->sw_format) > 1 && vk->format[1] == VK_FORMAT_UNDEFINED;
    if (!multiplane && vk->tiling == VK_IMAGE_TILING_LINEAR)
        return 0;
    dev    = fc->device_ctx->hwctx;
    props2 = (PFN_vkGetPhysicalDeviceProperties2)
             dev->get_proc_addr(dev->inst, "vkGetPhysicalDeviceProperties2");
    if (!props2)
        return 0;
    props2(dev->phys_dev, &props);
    return drv.driverID == VK_DRIVER_ID_INTEL_PROPRIETARY_WINDOWS;
#else
    return 0;
#endif
}

#define GPUFX_VK_HOST_COPY_HINT \
    "FFmpeg copies these frames with VK_EXT_host_image_copy, which the Intel Windows Vulkan " \
    "driver gets wrong (allocation fails or chroma is corrupted), so frames from hwupload or " \
    "another FFmpeg Vulkan filter are refused. Use gpufx_upload instead of hwupload (and gpufx_download instead of hwdownload), or D3D11 frames, or open the device " \
    "with -init_hw_device vulkan=vk:N,disable_multiplane=1,linear_images=1. " \
    "See docs/INTEL_VULKAN.md."

#endif /* AVFILTER_VF_GPUFX_VK_H */
