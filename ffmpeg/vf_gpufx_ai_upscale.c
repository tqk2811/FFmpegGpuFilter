/*
 * gpufx_ai_upscale filter: super resolution with a neural network model (a gpufx-nn package
 * or bundle of kind super_resolution, such as Real-ESRGAN realesr-animevideov3) run by libgpufx
 * on the GPU.
 *
 * Each frame is converted to RGBA, upscaled by the model in tiles (so that 1080p and 4K frames
 * fit the GPU's buffer limits) and converted back into a frame scale times larger of the same
 * format. The input and output are GPU frames (Vulkan, D3D12, D3D11 or VideoToolbox) on
 * FFmpeg's device, as for the gpufx filter: put hwupload/gpufx_upload before it and
 * hwdownload/gpufx_download after it. The input frames are only read.
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

#include <gpufx.h>

#include "config.h"
#include "libavutil/imgutils.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"
#include "libavutil/hwcontext.h"
#if CONFIG_VULKAN
#include "libavutil/hwcontext_vulkan.h"
#include "libavutil/internal.h"
#endif
#if CONFIG_D3D12VA
#include "libavutil/hwcontext_d3d12va.h"
#endif
#if CONFIG_D3D11VA
#include "libavutil/hwcontext_d3d11va.h"
#endif

#include "avfilter.h"
#include "filters.h"
#include "formats.h"
#include "video.h"
#include "vf_gpufx_vk.h"
#include "vf_gpufx_frames.h"

typedef struct AiUpscaleContext {
    const AVClass *class;

    char *model;
    int scale;        /* output size / input size on each axis */
    int tile;         /* largest tile side in input pixels, 0: auto */
    int precision;    /* GPUFX_AI_PRECISION_* */

    GpufxAiUpscale *ai;
    enum AVPixelFormat hw_fmt;
    AVBufferRef *hw_device;   /* the device libgpufx runs on, held while it does */
    AVBufferRef *in_frames;   /* frames contexts held until the model is freed: libgpufx */
    AVBufferRef *out_frames;  /* keeps wrappers of their images */
    AVBufferRef **old_frames; /* frames contexts of earlier sizes (out) and later inputs, likewise */
    int nb_old_frames;
    int in_w, in_h;           /* the input size out_frames is made for */
    uint32_t vk_queue_family;

    int64_t nb_frames;
} AiUpscaleContext;

static int ai_error(AVFilterContext *ctx, const char *what)
{
    av_log(ctx, AV_LOG_ERROR, "%s: %s\n", what, gpufx_last_error());
    return AVERROR_EXTERNAL;
}

static av_cold int init(AVFilterContext *ctx)
{
    AiUpscaleContext *s = ctx->priv;

    if (!s->model || !*s->model) {
        av_log(ctx, AV_LOG_ERROR, "model is required: the path of a super_resolution package "
               "(e.g. packages/gpufx_ai_upscale/realesr-animevideov3.zip, see scripts/fetch-models).\n");
        return AVERROR(EINVAL);
    }
    if (gpufx_version() < GPUFX_API_VERSION) {
        av_log(ctx, AV_LOG_ERROR, "libgpufx API version %u is older than the headers (%u).\n",
               gpufx_version(), GPUFX_API_VERSION);
        return AVERROR(EINVAL);
    }
    if (!(s->ai = gpufx_ai_upscale_open(s->model, s->scale, s->tile, s->precision)))
        return ai_error(ctx, "Cannot open the model");
    return 0;
}

static av_cold void uninit(AVFilterContext *ctx)
{
    AiUpscaleContext *s = ctx->priv;

    if (s->nb_frames)
        av_log(ctx, AV_LOG_VERBOSE, "%"PRId64" frames upscaled\n", s->nb_frames);
    gpufx_ai_upscale_free(s->ai);
    s->ai = NULL;
    /* After the model, which may still hold wrappers of their images. */
    av_buffer_unref(&s->in_frames);
    av_buffer_unref(&s->out_frames);
    for (int k = 0; k < s->nb_old_frames; k++)
        av_buffer_unref(&s->old_frames[k]);
    av_freep(&s->old_frames);
    av_buffer_unref(&s->hw_device);
}

static int hw_ok(enum AVPixelFormat fmt)
{
    switch (fmt) {
#if CONFIG_VULKAN
    case AV_PIX_FMT_VULKAN:       return gpufx_vulkan_supported();
#endif
#if CONFIG_D3D12VA
    case AV_PIX_FMT_D3D12:        return gpufx_d3d12_supported();
#endif
#if CONFIG_D3D11VA
    case AV_PIX_FMT_D3D11:        return gpufx_d3d12_supported();
#endif
#if CONFIG_VIDEOTOOLBOX
    case AV_PIX_FMT_VIDEOTOOLBOX: return gpufx_videotoolbox_supported();
#endif
    default:                      return 0;
    }
}

static int query_formats(const AVFilterContext *ctx,
                         AVFilterFormatsConfig **cfg_in,
                         AVFilterFormatsConfig **cfg_out)
{
    static const enum AVPixelFormat hw[] = {
        AV_PIX_FMT_VULKAN, AV_PIX_FMT_D3D12, AV_PIX_FMT_D3D11, AV_PIX_FMT_VIDEOTOOLBOX,
    };
    AVFilterFormats *formats = NULL;
    int ret;

    for (int j = 0; j < FF_ARRAY_ELEMS(hw); j++)
        if (hw_ok(hw[j]) && (ret = ff_add_format(&formats, hw[j])) < 0)
            return ret;
    if (!formats) {
        av_log((void *)ctx, AV_LOG_ERROR, "This FFmpeg and libgpufx share no GPU frame API.\n");
        return AVERROR(ENOSYS);
    }
    return ff_set_common_formats2(ctx, cfg_in, cfg_out, formats);
}

/* Whether libgpufx reads and writes frames of sw_format fmt of the GPU format hw_fmt. */
static int sw_format_ok(enum AVPixelFormat hw_fmt, enum AVPixelFormat fmt)
{
    if (!gpufx_format_supported(av_get_pix_fmt_name(fmt)))
        return 0;
    if (hw_fmt == AV_PIX_FMT_VULKAN)
        return 1;
    if (hw_fmt == AV_PIX_FMT_VIDEOTOOLBOX)
        return fmt == AV_PIX_FMT_NV12 || fmt == AV_PIX_FMT_P010;
    return fmt == AV_PIX_FMT_NV12 || fmt == AV_PIX_FMT_P010 || fmt == AV_PIX_FMT_RGBA || fmt == AV_PIX_FMT_RGBA64;
}

#if CONFIG_VULKAN
static int config_vulkan(AVFilterContext *ctx, AVHWFramesContext *fc)
{
    AiUpscaleContext *s = ctx->priv;
    AVHWDeviceContext *dev = fc->device_ctx;
    AVVulkanDeviceContext *hwctx = dev->hwctx;
    AVVulkanFramesContext *vkfc = fc->hwctx;
    GpufxVulkanDevice d = { 0 };
    int family = -1;

    if (gpufx_vk_host_copy_broken(fc)) {
        av_log(ctx, AV_LOG_ERROR, "The input has Vulkan frames of %s that FFmpeg fills with host "
               "image copies (hwupload?). " GPUFX_VK_HOST_COPY_HINT "\n", av_get_pix_fmt_name(fc->sw_format));
        return AVERROR(ENOSYS);
    }
    if (av_pix_fmt_count_planes(fc->sw_format) > 1 && vkfc->format[1] == VK_FORMAT_UNDEFINED) {
        av_log(ctx, AV_LOG_ERROR, "Multiplane Vulkan images are not supported; use gpufx_upload, or "
               "open the device with disable_multiplane=1.\n");
        return AVERROR(ENOSYS);
    }
    if (!(vkfc->usage & VK_IMAGE_USAGE_SAMPLED_BIT)) {
        av_log(ctx, AV_LOG_ERROR, "The input Vulkan frames of %s cannot be sampled; upload another format.\n",
               av_get_pix_fmt_name(fc->sw_format));
        return AVERROR(ENOSYS);
    }
    /* wgpu needs a graphics queue (see vf_gpufx.c). */
    for (int q = 0; q < hwctx->nb_qf && family < 0; q++)
        if (hwctx->qf[q].flags & VK_QUEUE_GRAPHICS_BIT)
            family = hwctx->qf[q].idx;
    if (family < 0) {
        av_log(ctx, AV_LOG_ERROR, "The Vulkan device has no graphics queue.\n");
        return AVERROR(ENOSYS);
    }
    d.get_instance_proc_addr = (void *)hwctx->get_proc_addr;
    d.instance               = hwctx->inst;
    d.physical_device        = hwctx->phys_dev;
    d.device                 = hwctx->act_dev;
    d.api_version            = VK_API_VERSION_1_3;
    d.queue_family           = family;
    d.queue_index            = 0;
    d.queue_flags            = hwctx->queue_flags;
    d.nb_instance_extensions = hwctx->nb_enabled_inst_extensions;
    d.instance_extensions    = hwctx->enabled_inst_extensions;
    d.nb_device_extensions   = hwctx->nb_enabled_dev_extensions;
    d.device_extensions      = hwctx->enabled_dev_extensions;
    d.device_features        = &hwctx->device_features;
    if (gpufx_ai_upscale_use_vulkan(s->ai, &d) < 0)
        return ai_error(ctx, "Cannot load the model on the Vulkan device");
    s->vk_queue_family = family;
    return 0;
}
#endif

/* Loads the model on the device of the input frames. */
static int config_device(AVFilterContext *ctx, AVHWFramesContext *fc)
{
    AiUpscaleContext *s = ctx->priv;
    int ret = AVERROR(ENOSYS);

    switch (s->hw_fmt) {
#if CONFIG_VULKAN
    case AV_PIX_FMT_VULKAN:
        ret = config_vulkan(ctx, fc);
        break;
#endif
#if CONFIG_D3D12VA
    case AV_PIX_FMT_D3D12: {
        AVD3D12VADeviceContext *hwctx = fc->device_ctx->hwctx;
        GpufxD3D12Device d = { hwctx->device };
        ret = gpufx_ai_upscale_use_d3d12(s->ai, &d) < 0 ? ai_error(ctx, "Cannot load the model on the D3D12 device") : 0;
        break;
    }
#endif
#if CONFIG_D3D11VA
    case AV_PIX_FMT_D3D11: {
        AVD3D11VADeviceContext *hwctx = fc->device_ctx->hwctx;
        GpufxD3D11Device d = { hwctx->device, hwctx->device_context };
        ret = gpufx_ai_upscale_use_d3d11(s->ai, &d) < 0 ? ai_error(ctx, "Cannot load the model on the D3D11 device") : 0;
        break;
    }
#endif
#if CONFIG_VIDEOTOOLBOX
    case AV_PIX_FMT_VIDEOTOOLBOX:
        ret = gpufx_ai_upscale_use_videotoolbox(s->ai) < 0 ? ai_error(ctx, "Cannot load the model for VideoToolbox frames") : 0;
        break;
#endif
    default:
        break;
    }
    return ret;
}

/*
 * The frames context of the output frames for inputs of w x h: same device and format as the
 * input, scale times larger, with the usage libgpufx writes (Vulkan storage images; D3D12
 * unordered access, else a GPU copy; D3D11 shared NT handle textures). Earlier ones are kept
 * until uninit (libgpufx may hold wrappers of its images).
 */
static int config_out_frames(AVFilterContext *ctx, enum AVPixelFormat sw_format, int w, int h)
{
    AiUpscaleContext *s = ctx->priv;
    int64_t ow = (int64_t)w * s->scale, oh = (int64_t)h * s->scale;

    if (ow > INT_MAX || oh > INT_MAX || av_image_check_size((unsigned)ow, (unsigned)oh, 0, ctx) < 0) {
        av_log(ctx, AV_LOG_ERROR, "A %dx%d frame upscaled %d times is too large.\n", w, h, s->scale);
        return AVERROR(EINVAL);
    }
    for (int uav = 1; uav >= 0; uav--) {
        AVBufferRef *ref = av_hwframe_ctx_alloc(s->hw_device);
        AVHWFramesContext *fc;
        AVFrame *probe;
        int ret;

        if (!ref)
            return AVERROR(ENOMEM);
        fc            = (AVHWFramesContext *)ref->data;
        fc->format    = s->hw_fmt;
        fc->sw_format = sw_format;
        fc->width     = (int)ow;
        fc->height    = (int)oh;
#if CONFIG_VULKAN
        if (s->hw_fmt == AV_PIX_FMT_VULKAN)
            ((AVVulkanFramesContext *)fc->hwctx)->flags = AV_VK_FRAME_FLAG_DISABLE_MULTIPLANE;
#endif
#if CONFIG_D3D12VA
        if (s->hw_fmt == AV_PIX_FMT_D3D12 && uav)
            ((AVD3D12VAFramesContext *)fc->hwctx)->resource_flags |= D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
#endif
#if CONFIG_D3D11VA
        if (s->hw_fmt == AV_PIX_FMT_D3D11) {
            AVD3D11VAFramesContext *hc = fc->hwctx;
            hc->BindFlags = D3D11_BIND_SHADER_RESOURCE | (uav ? D3D11_BIND_UNORDERED_ACCESS : 0);
            hc->MiscFlags = D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
        }
#endif
        ret = gpufx_hwframe_ctx_init(ref);
#if CONFIG_VULKAN
        if (ret >= 0 && s->hw_fmt == AV_PIX_FMT_VULKAN &&
            !(((AVVulkanFramesContext *)fc->hwctx)->usage & VK_IMAGE_USAGE_STORAGE_BIT))
            ret = AVERROR(ENOSYS);
#endif
        /* Some devices accept the context but fail to create its textures: try one. */
        if (ret >= 0) {
            if (!(probe = av_frame_alloc())) {
                av_buffer_unref(&ref);
                return AVERROR(ENOMEM);
            }
            ret = av_hwframe_get_buffer(ref, probe, 0);
            av_frame_free(&probe);
        }
        if (ret >= 0) {
            if (s->out_frames && (ret = av_dynarray_add_nofree(&s->old_frames, &s->nb_old_frames, s->out_frames)) < 0) {
                av_buffer_unref(&ref);
                return ret;
            }
            s->out_frames = ref;
            s->in_w       = w;
            s->in_h       = h;
            return 0;
        }
        av_buffer_unref(&ref);
        /* Vulkan and VideoToolbox have one kind of frames. */
        if (s->hw_fmt != AV_PIX_FMT_D3D12 && s->hw_fmt != AV_PIX_FMT_D3D11)
            break;
    }
    av_log(ctx, AV_LOG_ERROR, "Cannot make %"PRId64"x%"PRId64" %s GPU frames for the upscaled frames.\n",
           ow, oh, av_get_pix_fmt_name(sw_format));
    return AVERROR(ENOSYS);
}

static int config_output(AVFilterLink *outlink)
{
    AVFilterContext *ctx = outlink->src;
    AiUpscaleContext *s = ctx->priv;
    AVFilterLink *inlink = ctx->inputs[0];
    FilterLink *il = ff_filter_link(inlink);
    FilterLink *ol = ff_filter_link(outlink);
    AVHWFramesContext *fc;
    int ret;

    if (!il->hw_frames_ctx) {
        av_log(ctx, AV_LOG_ERROR, "The input has no GPU frames context.\n");
        return AVERROR(EINVAL);
    }
    fc = (AVHWFramesContext *)il->hw_frames_ctx->data;
    s->hw_fmt = inlink->format;
    if (!sw_format_ok(s->hw_fmt, fc->sw_format)) {
        av_log(ctx, AV_LOG_ERROR, "GPU frames of %s are not supported; upload nv12, p010le, rgba or "
               "rgba64le.\n", av_get_pix_fmt_name(fc->sw_format));
        return AVERROR(ENOSYS);
    }
    if (!(s->in_frames = av_buffer_ref(il->hw_frames_ctx)) ||
        !(s->hw_device = av_buffer_ref(fc->device_ref)))
        return AVERROR(ENOMEM);
    if ((ret = config_device(ctx, fc)) < 0 ||
        (ret = config_out_frames(ctx, fc->sw_format, inlink->w, inlink->h)) < 0)
        return ret;
    av_log(ctx, AV_LOG_VERBOSE, "Model on %s\n", gpufx_ai_upscale_device(s->ai));

    outlink->w = inlink->w * s->scale;
    outlink->h = inlink->h * s->scale;
    outlink->sample_aspect_ratio = inlink->sample_aspect_ratio;
    av_buffer_unref(&ol->hw_frames_ctx);
    if (!(ol->hw_frames_ctx = av_buffer_ref(s->out_frames)))
        return AVERROR(ENOMEM);
    av_log(ctx, AV_LOG_VERBOSE, "%dx%d -> %dx%d\n", inlink->w, inlink->h, outlink->w, outlink->h);
    return 0;
}

/* True when ref's frames context is already held in old_frames. */
static int holds_frames(const AiUpscaleContext *s, const AVBufferRef *ref)
{
    for (int k = 0; k < s->nb_old_frames; k++)
        if (s->old_frames[k]->data == ref->data)
            return 1;
    return 0;
}

#if CONFIG_D3D12VA || CONFIG_D3D11VA || CONFIG_VIDEOTOOLBOX
static const char *frame_color(AVFilterContext *ctx, const AVFrame *f, GpufxColor *c)
{
    AVHWFramesContext *fc = (AVHWFramesContext *)f->hw_frames_ctx->data;
    const char *name = gpu_color_fmt(f, fc->sw_format, c);

    if (!name)
        av_log(ctx, AV_LOG_ERROR, "Frames of %s in colorspace %s are not converted on the GPU; set a "
               "supported matrix (BT.601, BT.709, BT.2020) before uploading.\n",
               av_get_pix_fmt_name(fc->sw_format), av_color_space_name(f->colorspace));
    return name;
}
#endif

#if CONFIG_VULKAN
static int run_vulkan(AVFilterContext *ctx, AVFrame *in, AVFrame *out)
{
    AiUpscaleContext *s = ctx->priv;
    AVHWDeviceContext *dev = (AVHWDeviceContext *)s->hw_device->data;
    AVVulkanDeviceContext *hwctx = dev->hwctx;
    GpufxVulkanFrame vin, vout;
    AVFrame *frames[2] = { in, out };
    int ret;

    for (int k = 0; k < 2; k++) {
        AVHWFramesContext *fc = (AVHWFramesContext *)frames[k]->hw_frames_ctx->data;
        ((AVVulkanFramesContext *)fc->hwctx)->lock_frame(fc, (AVVkFrame *)frames[k]->data[0]);
    }
    ret = vk_fill(ctx, in, &vin, "input");
    if (ret >= 0)
        ret = vk_fill(ctx, out, &vout, "output");
    if (ret >= 0) {
#if FF_API_VULKAN_SYNC_QUEUES
FF_DISABLE_DEPRECATION_WARNINGS
        hwctx->lock_queue(dev, s->vk_queue_family, 0);
FF_ENABLE_DEPRECATION_WARNINGS
#endif
        ret = gpufx_ai_upscale_process_vulkan(s->ai, &vin, &vout);
#if FF_API_VULKAN_SYNC_QUEUES
FF_DISABLE_DEPRECATION_WARNINGS
        hwctx->unlock_queue(dev, s->vk_queue_family, 0);
FF_ENABLE_DEPRECATION_WARNINGS
#endif
        if (ret < 0) {
            ret = ai_error(ctx, "Upscaling failed");
        } else {
            vk_store(in, &vin);
            vk_store(out, &vout);
        }
    }
    for (int k = 0; k < 2; k++) {
        AVHWFramesContext *fc = (AVHWFramesContext *)frames[k]->hw_frames_ctx->data;
        ((AVVulkanFramesContext *)fc->hwctx)->unlock_frame(fc, (AVVkFrame *)frames[k]->data[0]);
    }
    return ret;
}
#endif

#if CONFIG_D3D12VA
static int run_d3d12(AVFilterContext *ctx, AVFrame *in, AVFrame *out)
{
    AiUpscaleContext *s = ctx->priv;
    GpufxD3D12Frame g[2];
    AVFrame *frames[2] = { in, out };

    for (int k = 0; k < 2; k++) {
        AVD3D12VAFrame *d = (AVD3D12VAFrame *)frames[k]->data[0];

        if (!(g[k].format = frame_color(ctx, frames[k], &g[k].color)))
            return AVERROR(ENOSYS);
        g[k].width       = frames[k]->width;
        g[k].height      = frames[k]->height;
        g[k].resource    = d->texture;
        g[k].subresource = d->subresource_index;
        g[k].fence       = d->sync_ctx.fence;
        g[k].fence_value = d->sync_ctx.fence_value;
    }
    if (gpufx_ai_upscale_process_d3d12(s->ai, &g[0], &g[1]) < 0)
        return ai_error(ctx, "Upscaling failed");
    for (int k = 0; k < 2; k++) {
        AVD3D12VAFrame *d = (AVD3D12VAFrame *)frames[k]->data[0];

        d->sync_ctx.fence_value = FFMAX(d->sync_ctx.fence_value, g[k].fence_value);
    }
    return 0;
}
#endif

#if CONFIG_D3D11VA
static int run_d3d11(AVFilterContext *ctx, AVFrame *in, AVFrame *out)
{
    AiUpscaleContext *s = ctx->priv;
    AVD3D11VADeviceContext *hwctx = ((AVHWDeviceContext *)s->hw_device->data)->hwctx;
    GpufxD3D11Frame g[2];
    AVFrame *frames[2] = { in, out };
    int ret;

    for (int k = 0; k < 2; k++) {
        if (!(g[k].format = frame_color(ctx, frames[k], &g[k].color)))
            return AVERROR(ENOSYS);
        g[k].width       = frames[k]->width;
        g[k].height      = frames[k]->height;
        g[k].texture     = frames[k]->data[0];
        g[k].array_slice = (uint32_t)(intptr_t)frames[k]->data[1];
    }
    hwctx->lock(hwctx->lock_ctx);
    ret = gpufx_ai_upscale_process_d3d11(s->ai, &g[0], &g[1]);
    hwctx->unlock(hwctx->lock_ctx);
    return ret < 0 ? ai_error(ctx, "Upscaling failed") : 0;
}
#endif

#if CONFIG_VIDEOTOOLBOX
static int run_videotoolbox(AVFilterContext *ctx, AVFrame *in, AVFrame *out)
{
    AiUpscaleContext *s = ctx->priv;
    GpufxVtFrame g[2];
    AVFrame *frames[2] = { in, out };

    for (int k = 0; k < 2; k++) {
        if (!(g[k].format = frame_color(ctx, frames[k], &g[k].color)))
            return AVERROR(ENOSYS);
        g[k].width        = frames[k]->width;
        g[k].height       = frames[k]->height;
        g[k].pixel_buffer = frames[k]->data[3];
    }
    if (gpufx_ai_upscale_process_videotoolbox(s->ai, &g[0], &g[1]) < 0)
        return ai_error(ctx, "Upscaling failed");
    return 0;
}
#endif

static int run(AVFilterContext *ctx, AVFrame *in, AVFrame *out)
{
    AiUpscaleContext *s = ctx->priv;

    switch (s->hw_fmt) {
#if CONFIG_VULKAN
    case AV_PIX_FMT_VULKAN:       return run_vulkan(ctx, in, out);
#endif
#if CONFIG_D3D12VA
    case AV_PIX_FMT_D3D12:        return run_d3d12(ctx, in, out);
#endif
#if CONFIG_D3D11VA
    case AV_PIX_FMT_D3D11:        return run_d3d11(ctx, in, out);
#endif
#if CONFIG_VIDEOTOOLBOX
    case AV_PIX_FMT_VIDEOTOOLBOX: return run_videotoolbox(ctx, in, out);
#endif
    default:                      return AVERROR_BUG;
    }
}

static int filter_frame(AVFilterLink *inlink, AVFrame *in)
{
    AVFilterContext *ctx = inlink->dst;
    AiUpscaleContext *s = ctx->priv;
    AVHWFramesContext *fc;
    AVFrame *out = NULL;
    int ret;

    if (!in->hw_frames_ctx || in->format != s->hw_fmt) {
        av_log(ctx, AV_LOG_ERROR, "The input frame is not a GPU frame of the configured kind.\n");
        ret = AVERROR(EINVAL);
        goto fail;
    }
    fc = (AVHWFramesContext *)in->hw_frames_ctx->data;
    /* A new size (the filter graph is not reconfigured, -reinit_filter 0): output frames of it. */
    if (in->width != s->in_w || in->height != s->in_h ||
        fc->sw_format != ((AVHWFramesContext *)s->out_frames->data)->sw_format) {
        if (!sw_format_ok(s->hw_fmt, fc->sw_format)) {
            av_log(ctx, AV_LOG_ERROR, "GPU frames of %s are not supported.\n", av_get_pix_fmt_name(fc->sw_format));
            ret = AVERROR(ENOSYS);
            goto fail;
        }
        av_log(ctx, AV_LOG_WARNING, "The input changed from %dx%d to %dx%d %s: the output is now %dx%d.\n",
               s->in_w, s->in_h, in->width, in->height, av_get_pix_fmt_name(fc->sw_format),
               in->width * s->scale, in->height * s->scale);
        if ((ret = config_out_frames(ctx, fc->sw_format, in->width, in->height)) < 0)
            goto fail;
    }
    /* A new input frames context (e.g. a new upload pool for the new size): hold it like the first. */
    if (in->hw_frames_ctx->data != s->in_frames->data && !holds_frames(s, in->hw_frames_ctx)) {
        AVBufferRef *ref = av_buffer_ref(in->hw_frames_ctx);

        ret = ref ? av_dynarray_add_nofree(&s->old_frames, &s->nb_old_frames, ref) : AVERROR(ENOMEM);
        if (ret < 0) {
            av_buffer_unref(&ref);
            goto fail;
        }
    }
    if (!(out = av_frame_alloc())) {
        ret = AVERROR(ENOMEM);
        goto fail;
    }
    if ((ret = av_hwframe_get_buffer(s->out_frames, out, 0)) < 0 ||
        (ret = av_frame_copy_props(out, in)) < 0)
        goto fail;
    if ((ret = run(ctx, in, out)) < 0)
        goto fail;
    s->nb_frames++;
    av_frame_free(&in);
    return ff_filter_frame(ctx->outputs[0], out);
fail:
    av_frame_free(&out);
    av_frame_free(&in);
    return ret;
}

#define OFFSET(x) offsetof(AiUpscaleContext, x)
#define FLAGS (AV_OPT_FLAG_FILTERING_PARAM | AV_OPT_FLAG_VIDEO_PARAM)

static const AVOption gpufx_ai_upscale_options[] = {
    { "model",     "super resolution package or bundle (gpufx-nn, io.json kind super_resolution), e.g. packages/gpufx_ai_upscale/realesr-animevideov3.zip", OFFSET(model), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, FLAGS },
    { "scale",     "output size / input size on each axis; the package must have it", OFFSET(scale), AV_OPT_TYPE_INT, { .i64 = 2 }, 1, 16, FLAGS },
    { "tile",      "largest tile side in input pixels; 0: the fewest tiles that fit the GPU", OFFSET(tile), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 16384, FLAGS },
    { "precision", "arithmetic of the convolutions", OFFSET(precision), AV_OPT_TYPE_INT, { .i64 = GPUFX_AI_PRECISION_AUTO }, 0, 1, FLAGS, .unit = "precision" },
        { "auto", "f16 where the GPU has it, else f32", 0, AV_OPT_TYPE_CONST, { .i64 = GPUFX_AI_PRECISION_AUTO }, 0, 0, FLAGS, .unit = "precision" },
        { "f32",  "f32 everywhere",                     0, AV_OPT_TYPE_CONST, { .i64 = GPUFX_AI_PRECISION_F32 },  0, 0, FLAGS, .unit = "precision" },
    { NULL }
};

AVFILTER_DEFINE_CLASS(gpufx_ai_upscale);

static const AVFilterPad inputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_VIDEO,
        .filter_frame = filter_frame,
    },
};

static const AVFilterPad outputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_VIDEO,
        .config_props = config_output,
    },
};

const FFFilter ff_vf_gpufx_ai_upscale = {
    .p.name         = "gpufx_ai_upscale",
    .p.description  = NULL_IF_CONFIG_SMALL("Upscale frames with a neural super resolution model on the GPU."),
    .p.priv_class   = &gpufx_ai_upscale_class,
    .priv_size      = sizeof(AiUpscaleContext),
    .flags_internal = FF_FILTER_FLAG_HWFRAME_AWARE,
    .init           = init,
    .uninit         = uninit,
    FILTER_INPUTS(inputs),
    FILTER_OUTPUTS(outputs),
    FILTER_QUERY_FUNC2(query_formats),
};
