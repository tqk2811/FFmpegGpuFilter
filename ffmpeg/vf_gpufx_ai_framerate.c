/*
 * gpufx_ai_framerate filter: raise the frame rate with a neural frame interpolation model
 * (a gpufx-nn package of kind frame_interp, such as RIFE v4.6) run by libgpufx on the GPU.
 *
 * Like framerate and minterpolate, the output is a constant frame rate grid: each output
 * frame at time T between the source frames at T0 and T1 is made by the model at
 * t = (T - T0) / (T1 - T0); a grid point on a source frame is that frame itself. A pair of
 * source frames further apart than max_gap source frame durations (a gap in a VFR stream),
 * going back in time, or detected as a scene change is not interpolated: the nearer source
 * frame is repeated instead. The input and output are GPU frames (Vulkan, D3D12, D3D11 or
 * VideoToolbox), read and written in place on FFmpeg's device as by the gpufx filter: put
 * hwupload/gpufx_upload before it and hwdownload/gpufx_download after it.
 * libgpufx keeps the last source frame converted to RGBA on the GPU, so the filter holds
 * only a reference to it (to repeat it), not a copy.
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

#include <math.h>
#include <gpufx.h>

#include "config.h"
#include "libavutil/avassert.h"
#include "libavutil/mathematics.h"
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

/* More grid points than this from one source frame (a jump or the end of the stream) are skipped. */
#define MAX_BURST 10000

/* What an output grid point is made of. */
enum Kind { KIND_PREV, KIND_CUR, KIND_INTERP };

typedef struct AiFramerateContext {
    const AVClass *class;

    char *model;
    AVRational fps;   /* output rate; 0/1: twice the input's */
    double scene;     /* scene change SSIM threshold (0..1), 0: off */
    double max_gap;   /* pairs further apart than this many input frame durations are not interpolated */

    GpufxAiInterp *ai;
    enum AVPixelFormat hw_fmt;
    AVBufferRef *hw_device;   /* the device libgpufx runs on, held while it does */
    AVBufferRef *in_frames;   /* frames contexts held until the model is freed: libgpufx */
    AVBufferRef *out_frames;  /* keeps wrappers of their images */
    uint32_t vk_queue_family;
    int own_out;              /* the output frames context is not the input's: source frames are copied */

    double pos_scale;         /* input time base in output frame units */
    double in_step;           /* input frame duration in output frame units, 0 if unknown */
    AVFrame *prev;            /* last source frame, NULL before the first */
    double prev_pos;          /* its time in output frame units */
    int64_t next;             /* next output grid point */
    int meta_pending;         /* the metadata of prev (side data, key flag) was not sent yet */
    int warned_burst;

    /* The grid points of one source frame (at most max_out). */
    int max_out;
    enum Kind *kinds;
    int64_t *points;
    float *times;
    AVFrame **outs;
    union {
#if CONFIG_VULKAN
        GpufxVulkanFrame *vk;
#endif
#if CONFIG_D3D12VA
        GpufxD3D12Frame *d12;
#endif
#if CONFIG_D3D11VA
        GpufxD3D11Frame *d11;
#endif
#if CONFIG_VIDEOTOOLBOX
        GpufxVtFrame *vt;
#endif
        void *any;
    } gout;

    int64_t nb_interp, nb_repeat, nb_source;
} AiFramerateContext;

static int ai_error(AVFilterContext *ctx, const char *what)
{
    av_log(ctx, AV_LOG_ERROR, "%s: %s\n", what, gpufx_last_error());
    return AVERROR_EXTERNAL;
}

static av_cold int init(AVFilterContext *ctx)
{
    AiFramerateContext *s = ctx->priv;

    if (!s->model || !*s->model) {
        av_log(ctx, AV_LOG_ERROR, "model is required: the path of a frame_interp package "
               "(e.g. packages/gpufx_ai_framerate/rife-v4.6.zip, see scripts/fetch-models).\n");
        return AVERROR(EINVAL);
    }
    if (gpufx_version() < GPUFX_API_VERSION) {
        av_log(ctx, AV_LOG_ERROR, "libgpufx API version %u is older than the headers (%u).\n",
               gpufx_version(), GPUFX_API_VERSION);
        return AVERROR(EINVAL);
    }
    if (!(s->ai = gpufx_ai_interp_open(s->model)))
        return ai_error(ctx, "Cannot open the model");
    if (gpufx_ai_interp_set_scene(s->ai, s->scene) < 0)
        return ai_error(ctx, "Bad scene threshold");
    return 0;
}

static av_cold void uninit(AVFilterContext *ctx)
{
    AiFramerateContext *s = ctx->priv;

    if (s->nb_source)
        av_log(ctx, AV_LOG_VERBOSE, "%"PRId64" source frames, %"PRId64" interpolated, %"PRId64" repeated\n",
               s->nb_source, s->nb_interp, s->nb_repeat);
    av_frame_free(&s->prev);
    for (int k = 0; s->outs && k < s->max_out; k++)
        av_frame_free(&s->outs[k]);
    av_freep(&s->outs);
    av_freep(&s->kinds);
    av_freep(&s->points);
    av_freep(&s->times);
    av_freep(&s->gout.any);
    gpufx_ai_interp_free(s->ai);
    s->ai = NULL;
    /* After the model, which may still hold wrappers of their images. */
    av_buffer_unref(&s->in_frames);
    av_buffer_unref(&s->out_frames);
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
    AiFramerateContext *s = ctx->priv;
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
    /* A multiplane image (Vulkan decoders) is read by copying its planes. */
    if (av_pix_fmt_count_planes(fc->sw_format) > 1 && vkfc->format[1] == VK_FORMAT_UNDEFINED &&
        !(vkfc->usage & VK_IMAGE_USAGE_TRANSFER_SRC_BIT)) {
        av_log(ctx, AV_LOG_ERROR, "Multiplane Vulkan images without transfer source usage cannot be "
               "copied; use gpufx_upload, or open the device with disable_multiplane=1.\n");
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
    if (gpufx_ai_interp_use_vulkan(s->ai, &d) < 0)
        return ai_error(ctx, "Cannot load the model on the Vulkan device");
    s->vk_queue_family = family;
    return 0;
}
#endif

/* Loads the model on the device of the input frames. */
static int config_device(AVFilterContext *ctx, AVHWFramesContext *fc)
{
    AiFramerateContext *s = ctx->priv;
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
        ret = gpufx_ai_interp_use_d3d12(s->ai, &d) < 0 ? ai_error(ctx, "Cannot load the model on the D3D12 device") : 0;
        break;
    }
#endif
#if CONFIG_D3D11VA
    case AV_PIX_FMT_D3D11: {
        AVD3D11VADeviceContext *hwctx = fc->device_ctx->hwctx;
        GpufxD3D11Device d = { hwctx->device, hwctx->device_context };
        ret = gpufx_ai_interp_use_d3d11(s->ai, &d) < 0 ? ai_error(ctx, "Cannot load the model on the D3D11 device") : 0;
        break;
    }
#endif
#if CONFIG_VIDEOTOOLBOX
    case AV_PIX_FMT_VIDEOTOOLBOX:
        ret = gpufx_ai_interp_use_videotoolbox(s->ai) < 0 ? ai_error(ctx, "Cannot load the model for VideoToolbox frames") : 0;
        break;
#endif
    default:
        break;
    }
    return ret;
}

/* Whether libgpufx can write frames of the input's frames context (then source frames pass as they are). */
static int input_writable(const AiFramerateContext *s, AVHWFramesContext *in)
{
    switch (s->hw_fmt) {
#if CONFIG_VULKAN
    case AV_PIX_FMT_VULKAN: {
        const VkImageUsageFlags usage = ((AVVulkanFramesContext *)in->hwctx)->usage;
        /* A decoder's pool (video profile in create_pnext) is not borrowed for the new frames. */
        if (((AVVulkanFramesContext *)in->hwctx)->create_pnext)
            return 0;
        /* Multiplane images are written through copies of libgpufx's own plane images. */
        if (gpufx_vk_multiplane_known(in))
            return !!(usage & VK_IMAGE_USAGE_TRANSFER_DST_BIT);
        return !!(usage & VK_IMAGE_USAGE_STORAGE_BIT);
    }
#endif
#if CONFIG_D3D12VA
    case AV_PIX_FMT_D3D12:
        return 1; /* without unordered access libgpufx writes through a copy */
#endif
#if CONFIG_D3D11VA
    case AV_PIX_FMT_D3D11:
        return !!(((AVD3D11VAFramesContext *)in->hwctx)->MiscFlags & D3D11_RESOURCE_MISC_SHARED_NTHANDLE);
#endif
    default:
        return 0;
    }
}

/*
 * The frames context of the output: the input's when libgpufx can write its frames (source
 * frames are then passed on as they are), else one of the same device, format and size with
 * the usage libgpufx writes (Vulkan storage images; D3D12 unordered access, else a GPU copy;
 * D3D11 shared NT handle textures), and every source frame is copied into it on the GPU
 * (through RGBA, like the interpolated frames).
 */
static int config_out_frames(AVFilterContext *ctx, AVHWFramesContext *in)
{
    AiFramerateContext *s = ctx->priv;

    if (input_writable(s, in)) {
        s->own_out = 0;
        return (s->out_frames = av_buffer_ref(s->in_frames)) ? 0 : AVERROR(ENOMEM);
    }
    s->own_out = 1;
    av_log(ctx, AV_LOG_VERBOSE, "The input frames cannot be written by the GPU: source frames are copied.\n");
    /* Multiplane images where the device makes them (Vulkan encoders take only those). */
    if (s->hw_fmt == AV_PIX_FMT_VULKAN &&
        (s->out_frames = gpufx_vk_multiplane_frames(s->hw_device, in->sw_format, in->width, in->height)))
        return 0;
    for (int uav = 1; uav >= 0; uav--) {
        AVBufferRef *ref = av_hwframe_ctx_alloc(s->hw_device);
        AVHWFramesContext *fc;
        AVFrame *probe;
        int ret;

        if (!ref)
            return AVERROR(ENOMEM);
        fc            = (AVHWFramesContext *)ref->data;
        fc->format    = s->hw_fmt;
        fc->sw_format = in->sw_format;
        fc->width     = in->width;
        fc->height    = in->height;
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
            AVD3D11VAFramesContext *h = fc->hwctx;
            h->BindFlags = D3D11_BIND_SHADER_RESOURCE | (uav ? D3D11_BIND_UNORDERED_ACCESS : 0);
            h->MiscFlags = D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
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
            s->out_frames = ref;
            return 0;
        }
        av_buffer_unref(&ref);
        /* Vulkan and VideoToolbox have one kind of frames. */
        if (s->hw_fmt != AV_PIX_FMT_D3D12 && s->hw_fmt != AV_PIX_FMT_D3D11)
            break;
    }
    av_log(ctx, AV_LOG_ERROR, "Cannot make %s GPU frames for the interpolated frames.\n",
           av_get_pix_fmt_name(in->sw_format));
    return AVERROR(ENOSYS);
}

/* Size of the largest GpufxXxxFrame, for s->gout. */
static size_t gframe_size(void)
{
    return FFMAX(FFMAX(sizeof(GpufxVulkanFrame), sizeof(GpufxD3D12Frame)),
                 FFMAX(sizeof(GpufxD3D11Frame), sizeof(GpufxVtFrame)));
}

static int config_output(AVFilterLink *outlink)
{
    AVFilterContext *ctx = outlink->src;
    AiFramerateContext *s = ctx->priv;
    AVFilterLink *inlink = ctx->inputs[0];
    FilterLink *il = ff_filter_link(inlink);
    FilterLink *ol = ff_filter_link(outlink);
    AVHWFramesContext *fc;
    AVRational fps = s->fps;
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
    if ((ret = config_device(ctx, fc)) < 0 || (ret = config_out_frames(ctx, fc)) < 0)
        return ret;
    av_log(ctx, AV_LOG_VERBOSE, "Model on %s\n", gpufx_ai_interp_device(s->ai));

    if (!fps.num || !fps.den) {
        if (!il->frame_rate.num || !il->frame_rate.den) {
            av_log(ctx, AV_LOG_ERROR, "The input frame rate is unknown: set fps.\n");
            return AVERROR(EINVAL);
        }
        fps = av_mul_q(il->frame_rate, (AVRational){ 2, 1 });
    }
    ol->frame_rate      = fps;
    outlink->time_base  = av_inv_q(fps);
    outlink->w          = inlink->w;
    outlink->h          = inlink->h;
    outlink->sample_aspect_ratio = inlink->sample_aspect_ratio;
    s->pos_scale = av_q2d(av_div_q(inlink->time_base, outlink->time_base));
    s->in_step   = il->frame_rate.num && il->frame_rate.den ? av_q2d(av_div_q(fps, il->frame_rate)) : 0;
    /* Grid points per source frame, with room for VFR gaps up to max_gap. */
    s->max_out = (int)ceil(FFMAX(s->in_step, 1.0) * FFMAX(s->max_gap, 1.0)) + 3; /* + the source copy */
    if (!s->own_out && fc->initial_pool_size > 0)
        av_log(ctx, AV_LOG_WARNING, "The output frames are those of the input, whose pool has a fixed size of %d "
               "frames: up to %d more may be needed here (the outputs of one source frame plus the one kept); "
               "raise extra_hw_frames when uploading, or the stream may stall.\n",
               fc->initial_pool_size, s->max_out + 1);
    if (!(s->kinds  = av_calloc(s->max_out, sizeof(*s->kinds)))  ||
        !(s->points = av_calloc(s->max_out, sizeof(*s->points))) ||
        !(s->times  = av_calloc(s->max_out, sizeof(*s->times)))  ||
        !(s->outs   = av_calloc(s->max_out, sizeof(*s->outs)))   ||
        !(s->gout.any = av_calloc(s->max_out, gframe_size())))
        return AVERROR(ENOMEM);
    av_buffer_unref(&ol->hw_frames_ctx);
    if (!(ol->hw_frames_ctx = av_buffer_ref(s->out_frames)))
        return AVERROR(ENOMEM);
    av_log(ctx, AV_LOG_VERBOSE, "%d/%d fps -> %d/%d fps, scene=%g\n", il->frame_rate.num,
           il->frame_rate.den, fps.num, fps.den, s->scene);
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
static int run_vulkan(AVFilterContext *ctx, AVFrame *in, int n)
{
    AiFramerateContext *s = ctx->priv;
    AVHWDeviceContext *dev = (AVHWDeviceContext *)s->hw_device->data;
    AVVulkanDeviceContext *hwctx = dev->hwctx;
    GpufxVulkanFrame vin, *vout = s->gout.vk;
    int ret = 0;

    for (int k = -1; k < n; k++) {
        AVFrame *f = k < 0 ? in : s->outs[k];
        AVHWFramesContext *fc = (AVHWFramesContext *)f->hw_frames_ctx->data;
        ((AVVulkanFramesContext *)fc->hwctx)->lock_frame(fc, (AVVkFrame *)f->data[0]);
    }
    ret = vk_fill(ctx, in, &vin, "input");
    for (int k = 0; k < n && ret >= 0; k++)
        ret = vk_fill(ctx, s->outs[k], &vout[k], "output");
    if (ret >= 0) {
#if FF_API_VULKAN_SYNC_QUEUES
FF_DISABLE_DEPRECATION_WARNINGS
        hwctx->lock_queue(dev, s->vk_queue_family, 0);
FF_ENABLE_DEPRECATION_WARNINGS
#endif
        ret = gpufx_ai_interp_process_vulkan(s->ai, &vin, n ? vout : NULL, n, s->times);
#if FF_API_VULKAN_SYNC_QUEUES
FF_DISABLE_DEPRECATION_WARNINGS
        hwctx->unlock_queue(dev, s->vk_queue_family, 0);
FF_ENABLE_DEPRECATION_WARNINGS
#endif
        if (ret < 0) {
            ret = ai_error(ctx, "Interpolation failed");
        } else {
            vk_store(in, &vin);
            for (int k = 0; k < n; k++)
                vk_store(s->outs[k], &vout[k]);
        }
    }
    for (int k = -1; k < n; k++) {
        AVFrame *f = k < 0 ? in : s->outs[k];
        AVHWFramesContext *fc = (AVHWFramesContext *)f->hw_frames_ctx->data;
        ((AVVulkanFramesContext *)fc->hwctx)->unlock_frame(fc, (AVVkFrame *)f->data[0]);
    }
    return ret;
}
#endif

#if CONFIG_D3D12VA
static int run_d3d12(AVFilterContext *ctx, AVFrame *in, int n)
{
    AiFramerateContext *s = ctx->priv;
    GpufxD3D12Frame gin, *gout = s->gout.d12;

    for (int k = -1; k < n; k++) {
        AVFrame *f = k < 0 ? in : s->outs[k];
        AVD3D12VAFrame *d = (AVD3D12VAFrame *)f->data[0];
        GpufxD3D12Frame *g = k < 0 ? &gin : &gout[k];

        if (!(g->format = frame_color(ctx, f, &g->color)))
            return AVERROR(ENOSYS);
        g->width       = f->width;
        g->height      = f->height;
        g->resource    = d->texture;
        g->subresource = d->subresource_index;
        g->fence       = d->sync_ctx.fence;
        g->fence_value = d->sync_ctx.fence_value;
    }
    if (gpufx_ai_interp_process_d3d12(s->ai, &gin, n ? gout : NULL, n, s->times) < 0)
        return ai_error(ctx, "Interpolation failed");
    for (int k = -1; k < n; k++) {
        AVFrame *f = k < 0 ? in : s->outs[k];
        AVD3D12VAFrame *d = (AVD3D12VAFrame *)f->data[0];
        const GpufxD3D12Frame *g = k < 0 ? &gin : &gout[k];

        d->sync_ctx.fence_value = FFMAX(d->sync_ctx.fence_value, g->fence_value);
    }
    return 0;
}
#endif

#if CONFIG_D3D11VA
static int run_d3d11(AVFilterContext *ctx, AVFrame *in, int n)
{
    AiFramerateContext *s = ctx->priv;
    AVD3D11VADeviceContext *hwctx = ((AVHWDeviceContext *)s->hw_device->data)->hwctx;
    GpufxD3D11Frame gin, *gout = s->gout.d11;
    int ret;

    for (int k = -1; k < n; k++) {
        AVFrame *f = k < 0 ? in : s->outs[k];
        GpufxD3D11Frame *g = k < 0 ? &gin : &gout[k];

        if (!(g->format = frame_color(ctx, f, &g->color)))
            return AVERROR(ENOSYS);
        g->width       = f->width;
        g->height      = f->height;
        g->texture     = f->data[0];
        g->array_slice = (uint32_t)(intptr_t)f->data[1];
    }
    hwctx->lock(hwctx->lock_ctx);
    ret = gpufx_ai_interp_process_d3d11(s->ai, &gin, n ? gout : NULL, n, s->times);
    hwctx->unlock(hwctx->lock_ctx);
    return ret < 0 ? ai_error(ctx, "Interpolation failed") : 0;
}
#endif

#if CONFIG_VIDEOTOOLBOX
static int run_videotoolbox(AVFilterContext *ctx, AVFrame *in, int n)
{
    AiFramerateContext *s = ctx->priv;
    GpufxVtFrame gin, *gout = s->gout.vt;

    for (int k = -1; k < n; k++) {
        AVFrame *f = k < 0 ? in : s->outs[k];
        GpufxVtFrame *g = k < 0 ? &gin : &gout[k];

        if (!(g->format = frame_color(ctx, f, &g->color)))
            return AVERROR(ENOSYS);
        g->width        = f->width;
        g->height       = f->height;
        g->pixel_buffer = f->data[3];
    }
    if (gpufx_ai_interp_process_videotoolbox(s->ai, &gin, n ? gout : NULL, n, s->times) < 0)
        return ai_error(ctx, "Interpolation failed");
    return 0;
}
#endif

/* Hands the source frame in to libgpufx and makes the n frames of s->times between the last one and it. */
static int run(AVFilterContext *ctx, AVFrame *in, int n)
{
    AiFramerateContext *s = ctx->priv;

    switch (s->hw_fmt) {
#if CONFIG_VULKAN
    case AV_PIX_FMT_VULKAN:       return run_vulkan(ctx, in, n);
#endif
#if CONFIG_D3D12VA
    case AV_PIX_FMT_D3D12:        return run_d3d12(ctx, in, n);
#endif
#if CONFIG_D3D11VA
    case AV_PIX_FMT_D3D11:        return run_d3d11(ctx, in, n);
#endif
#if CONFIG_VIDEOTOOLBOX
    case AV_PIX_FMT_VIDEOTOOLBOX: return run_videotoolbox(ctx, in, n);
#endif
    default:                      return AVERROR_BUG;
    }
}

/*
 * Drops what belongs to one source frame only: the key flag and the per-frame side data (captions,
 * SEI, timecodes...). Side data describing the picture itself (HDR, ICC, rotation, stereo...) is
 * kept, so it is a list of what to drop: unknown types stay.
 */
static void strip_source_meta(AVFrame *f)
{
    f->flags &= ~AV_FRAME_FLAG_KEY;
    for (int i = f->nb_side_data - 1; i >= 0; i--) {
        switch (f->side_data[i]->type) {
        case AV_FRAME_DATA_A53_CC:
        case AV_FRAME_DATA_SEI_UNREGISTERED:
        case AV_FRAME_DATA_S12M_TIMECODE:
        case AV_FRAME_DATA_GOP_TIMECODE:
        case AV_FRAME_DATA_AFD:
        case AV_FRAME_DATA_REGIONS_OF_INTEREST:
        case AV_FRAME_DATA_VIDEO_ENC_PARAMS:
        case AV_FRAME_DATA_MOTION_VECTORS:
        case AV_FRAME_DATA_FILM_GRAIN_PARAMS:
        case AV_FRAME_DATA_DETECTION_BBOXES:
            av_frame_remove_side_data(f, f->side_data[i]->type);
            break;
        default:
            break;
        }
    }
}

/*
 * Sends a reference to src (or src itself when own) at grid point n. Only the first send of a
 * source frame (keep_meta) carries its key flag and side data: the others are copies.
 */
static int send(AVFilterContext *ctx, AVFrame *src, int own, int64_t n, int keep_meta)
{
    AVFrame *f = own ? src : av_frame_clone(src);

    if (!f)
        return AVERROR(ENOMEM);
    if (!keep_meta)
        strip_source_meta(f);
    f->pts      = n;
    f->duration = 1;
    return ff_filter_frame(ctx->outputs[0], f);
}

/* Output frames for the first n entries of s->times, with the properties of in. */
static int alloc_outs(AVFilterContext *ctx, const AVFrame *in, int n)
{
    AiFramerateContext *s = ctx->priv;
    int ret = 0;

    for (int k = 0; k < n; k++) {
        AVFrame *o;

        av_frame_free(&s->outs[k]);
        if (!(o = av_frame_alloc()) || (ret = av_hwframe_get_buffer(s->out_frames, o, 0)) < 0 ||
            (ret = av_frame_copy_props(o, in)) < 0) {
            av_frame_free(&o);
            return ret < 0 ? ret : AVERROR(ENOMEM);
        }
        if (s->times[k] < 1.0f)
            o->flags &= ~AV_FRAME_FLAG_KEY;
        s->outs[k] = o;
    }
    return 0;
}

/* Whether a and b are GPU frames of the same size and format. */
static int same_geometry(const AVFrame *a, const AVFrame *b)
{
    return a->width == b->width && a->height == b->height && a->format == b->format &&
           a->hw_frames_ctx && b->hw_frames_ctx &&
           ((AVHWFramesContext *)a->hw_frames_ctx->data)->sw_format ==
           ((AVHWFramesContext *)b->hw_frames_ctx->data)->sw_format;
}

static int filter_frame(AVFilterContext *ctx, AVFrame *in)
{
    AiFramerateContext *s = ctx->priv;
    AVFrame *cur = in; /* the source frame as output: in, or its copy (own_out) */
    double pos, dt = 0;
    int nb = 0, n_interp = 0, interpolate = 0, ret = 0, j = 0, first = !s->prev, discont = 0;
    int cur_meta = 1; /* the metadata of cur was not sent yet */
    int64_t n;

    s->nb_source++;
    if (in->pts == AV_NOPTS_VALUE)
        pos = s->prev ? s->prev_pos + (s->in_step > 0 ? s->in_step : 1.0) : 0.0;
    else
        pos = in->pts * s->pos_scale;

    if (first) {
        /* The first source frame: on the grid point nearest to it. */
        s->next = llrint(pos);
    } else {
        dt = pos - s->prev_pos;
        if (dt <= 0) {
            av_log(ctx, AV_LOG_WARNING, "Source frame at %.3fs is not after the previous one at %.3fs: "
                   "not interpolated.\n", pos * av_q2d(ctx->outputs[0]->time_base),
                   s->prev_pos * av_q2d(ctx->outputs[0]->time_base));
            /* The timeline does not go back: the frame takes the place of the previous one. */
            pos = s->prev_pos;
            discont = 1;
        }
        if (!same_geometry(s->prev, in)) {
            av_log(ctx, AV_LOG_WARNING, "The size or format of the source frames changed: not interpolated.\n");
            discont = 1;
        }
        if (pos + 1e-6 - s->next > MAX_BURST) {
            if (!s->warned_burst)
                av_log(ctx, AV_LOG_WARNING, "A jump of %.0f output frames (a timestamp jump?): skipped.\n",
                       pos - s->next);
            s->warned_burst = 1;
            s->next = (int64_t)floor(pos + 1e-6);
            discont = 1;
        }
        /* Pairs too far apart (or with too many grid points between them) are not interpolated. */
        interpolate = !discont && (s->in_step > 0 ? dt <= s->max_gap * s->in_step : dt <= s->max_out - 3);
        discont |= !interpolate;
    }
    for (n = s->next; interpolate && n <= pos + 1e-6; n++) {
        double t = (n - s->prev_pos) / dt;

        av_assert0(nb < s->max_out - 1);
        s->points[nb] = n;
        if (t >= 1.0 - 1e-4)
            s->kinds[nb] = KIND_CUR;
        else if (t <= 1e-4)
            s->kinds[nb] = KIND_PREV;
        else {
            s->kinds[nb] = KIND_INTERP;
            s->times[n_interp++] = (float)t;
        }
        nb++;
    }
    /* A discontinuity: libgpufx forgets the previous frame. */
    if (discont && !first)
        gpufx_ai_interp_reset(s->ai);
    /* libgpufx always takes the frame (it keeps it for the next pair); with frames of our own,
     * it also copies it into one (time 1). */
    if (s->own_out)
        s->times[n_interp] = 1.0f;
    if ((ret = alloc_outs(ctx, in, n_interp + s->own_out)) < 0 ||
        (ret = run(ctx, in, n_interp + s->own_out)) < 0)
        goto fail;
    if (s->own_out) {
        cur = s->outs[n_interp];
        s->outs[n_interp] = NULL;
        av_frame_free(&in);
    }
    if (first) {
        s->points[0] = s->next;
        s->kinds[0]  = KIND_CUR;
        nb = 1;
        n  = s->next + 1;
    }
    for (int k = 0; k < nb && ret >= 0; k++) {
        switch (s->kinds[k]) {
        case KIND_PREV:
            s->nb_repeat++;
            ret = send(ctx, s->prev, 0, s->points[k], s->meta_pending);
            s->meta_pending = 0;
            break;
        case KIND_CUR:
            ret = send(ctx, cur, 0, s->points[k], cur_meta);
            cur_meta = 0;
            break;
        case KIND_INTERP:
            s->nb_interp++;
            ret = send(ctx, s->outs[j], 1, s->points[k], 0);
            s->outs[j++] = NULL;
            break;
        }
    }
    /* Not interpolated: the nearer source frame on every grid point up to this one. */
    if (!interpolate && !first) {
        for (n = s->next; n <= pos + 1e-6 && ret >= 0; n++) {
            int is_cur = dt > 0 && (n - s->prev_pos) / dt >= 0.5;

            s->nb_repeat += !is_cur;
            if (is_cur) {
                ret = send(ctx, cur, 0, n, cur_meta);
                cur_meta = 0;
            } else {
                ret = send(ctx, s->prev, 0, n, s->meta_pending);
                s->meta_pending = 0;
            }
        }
    }
    s->next = n;
    av_frame_free(&s->prev);
    s->prev     = cur;
    s->prev_pos = pos;
    s->meta_pending = cur_meta;
    return ret;
fail:
    av_frame_free(&in);
    return ret;
}

static int activate(AVFilterContext *ctx)
{
    AiFramerateContext *s = ctx->priv;
    AVFilterLink *inlink = ctx->inputs[0];
    AVFilterLink *outlink = ctx->outputs[0];
    AVFrame *in;
    int64_t pts;
    int status, ret;

    FF_FILTER_FORWARD_STATUS_BACK(outlink, inlink);

    if ((ret = ff_inlink_consume_frame(inlink, &in)) < 0)
        return ret;
    if (ret > 0) {
        ret = filter_frame(ctx, in);
        if (ret >= 0 && ff_inlink_queued_frames(inlink))
            ff_filter_set_ready(ctx, 100);
        return ret;
    }
    if (ff_inlink_acknowledge_status(inlink, &status, &pts)) {
        /* The last source frame lasts until the end of the stream. */
        if (s->prev && pts != AV_NOPTS_VALUE) {
            double end = pts * s->pos_scale;

            if (end - s->next > MAX_BURST) {
                av_log(ctx, AV_LOG_WARNING, "The stream ends %.0f output frames after the last one: skipped.\n",
                       end - s->next);
                s->next = (int64_t)ceil(end - 1e-6) - 1;
            }
            while (s->next < end - 1e-6 && (ret = send(ctx, s->prev, 0, s->next, s->meta_pending)) >= 0) {
                s->meta_pending = 0;
                s->next++;
                s->nb_repeat++;
            }
            if (ret < 0)
                return ret;
        }
        ff_outlink_set_status(outlink, status, s->next);
        return 0;
    }
    FF_FILTER_FORWARD_WANTED(outlink, inlink);
    return FFERROR_NOT_READY;
}

#define OFFSET(x) offsetof(AiFramerateContext, x)
#define FLAGS (AV_OPT_FLAG_FILTERING_PARAM | AV_OPT_FLAG_VIDEO_PARAM)

static const AVOption gpufx_ai_framerate_options[] = {
    { "model",   "frame interpolation package (gpufx-nn, io.json kind frame_interp), e.g. packages/gpufx_ai_framerate/rife-v4.6.zip", OFFSET(model), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, FLAGS },
    { "fps",     "output frame rate; default: twice the input's", OFFSET(fps), AV_OPT_TYPE_RATIONAL, { .dbl = 0 }, 0, INT_MAX, FLAGS },
    { "scene",   "scene change SSIM threshold (32x32): below it a pair is a cut and is not interpolated; 0: off", OFFSET(scene), AV_OPT_TYPE_DOUBLE, { .dbl = 0.2 }, 0, 1, FLAGS },
    { "max_gap", "pairs further apart than this many input frame durations are repeated, not interpolated", OFFSET(max_gap), AV_OPT_TYPE_DOUBLE, { .dbl = 2.0 }, 1, 100, FLAGS },
    { NULL }
};

AVFILTER_DEFINE_CLASS(gpufx_ai_framerate);

static const AVFilterPad inputs[] = {
    {
        .name = "default",
        .type = AVMEDIA_TYPE_VIDEO,
    },
};

static const AVFilterPad outputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_VIDEO,
        .config_props = config_output,
    },
};

const FFFilter ff_vf_gpufx_ai_framerate = {
    .p.name         = "gpufx_ai_framerate",
    .p.description  = NULL_IF_CONFIG_SMALL("Raise the frame rate with a neural frame interpolation model on the GPU."),
    .p.priv_class   = &gpufx_ai_framerate_class,
    .priv_size      = sizeof(AiFramerateContext),
    .flags_internal = FF_FILTER_FLAG_HWFRAME_AWARE,
    .init           = init,
    .uninit         = uninit,
    .activate       = activate,
    FILTER_INPUTS(inputs),
    FILTER_OUTPUTS(outputs),
    FILTER_QUERY_FUNC2(query_formats),
};
