/*
 * gpufx: run GPU effect packages (zip with manifest.json + WGSL shaders).
 * SPDX-License-Identifier: MIT
 *
 * Error convention: functions returning int return 0 on success and a negative
 * value on failure; functions returning pointers return NULL on failure.
 * gpufx_last_error() then describes the failure for the calling thread.
 *
 * A GpufxEffect is not thread-safe: use one effect from one thread at a time.
 * Effects opened with the same backend share one GPU device.
 */
#ifndef GPUFX_H
#define GPUFX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GPUFX_API_VERSION 1

/* Names of the FFmpeg filters this project adds to libavfilter, for
 * avfilter_get_by_name() or a filter graph string. */
#define GPUFX_FILTER_NAME          "gpufx"
#define GPUFX_UPLOAD_FILTER_NAME   "gpufx_upload"
#define GPUFX_DOWNLOAD_FILTER_NAME "gpufx_download"
#define GPUFX_AI_FRAMERATE_FILTER_NAME "gpufx_ai_framerate"

typedef struct GpufxEffect GpufxEffect;

/* An RGBA8 image in CPU memory. stride is bytes per row, >= width * 4. */
typedef struct GpufxImage {
    const uint8_t *data;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
} GpufxImage;

/* Where the effect writes its RGBA8 result. stride is bytes per row, >= width * 4. */
typedef struct GpufxOutput {
    uint8_t *data;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
} GpufxOutput;

/*
 * Colour properties of a GpufxFrame. matrix, range and chroma_location only matter for
 * YUV formats; RGB and alpha are always full range.
 */
#define GPUFX_MATRIX_BT601  0 /* also BT.470BG, SMPTE 170M; FFmpeg's guess when unknown */
#define GPUFX_MATRIX_BT709  1
#define GPUFX_MATRIX_BT2020 2 /* non-constant luminance */

#define GPUFX_RANGE_LIMITED 0 /* "tv": luma 16..235, chroma 16..240, scaled for more bits */
#define GPUFX_RANGE_FULL    1 /* "pc", JPEG */

/* Where chroma samples sit in a subsampled format (the AVChromaLocation names). */
#define GPUFX_CHROMA_LEFT       0 /* MPEG-2, H.264: the usual default */
#define GPUFX_CHROMA_CENTER     1 /* MPEG-1, JPEG */
#define GPUFX_CHROMA_TOPLEFT    2
#define GPUFX_CHROMA_TOP        3
#define GPUFX_CHROMA_BOTTOMLEFT 4
#define GPUFX_CHROMA_BOTTOM     5

/*
 * The frame has premultiplied alpha. Effects see straight alpha: the colours are divided
 * by alpha after reading and multiplied again before writing, in RGB.
 */
#define GPUFX_FRAME_PREMULTIPLIED 1u

typedef struct GpufxColor {
    uint32_t matrix;          /* GPUFX_MATRIX_* */
    uint32_t range;           /* GPUFX_RANGE_* */
    uint32_t chroma_location; /* GPUFX_CHROMA_* */
    uint32_t flags;           /* GPUFX_FRAME_* */
} GpufxColor;

/*
 * A frame in CPU memory in one of the formats of gpufx_format_name(), converted to and
 * from RGBA on the GPU. format is the FFmpeg pixel format name ("nv12", "p010le",
 * "yuv420p"...). data and stride (bytes per row, >= the row size) are per plane, in the
 * FFmpeg plane order; unused planes are ignored. Samples above 8 bits are little endian.
 */
typedef struct GpufxFrame {
    const char *format;
    uint32_t width;
    uint32_t height;
    const uint8_t *data[4];
    uint32_t stride[4];
    GpufxColor color;
} GpufxFrame;

/* Where the effect writes its result, as GpufxFrame. */
typedef struct GpufxFrameOut {
    const char *format;
    uint32_t width;
    uint32_t height;
    uint8_t *data[4];
    uint32_t stride[4];
    GpufxColor color;
} GpufxFrameOut;

/* Per-frame values exposed to shaders as globals. */
typedef struct GpufxFrameInfo {
    double time;         /* seconds; globals.time, globals.time_int + globals.time_frac */
    uint64_t frame;      /* frame index; globals.frame */
    double pixel_aspect; /* sample aspect ratio (width / height of a pixel), 1 if unknown */
} GpufxFrameInfo;

/* Properties of one input stream, checked against the manifest rules. */
typedef struct GpufxStreamInfo {
    const char *format; /* FFmpeg pixel format name ("yuv420p"), or NULL if unknown */
    uint32_t width;
    uint32_t height;
} GpufxStreamInfo;

/*
 * Returns GPUFX_API_VERSION of the loaded library. Versions only grow by additions
 * (new functions, constants): a library with a version >= the header's works, an older
 * one does not. A change that breaks existing callers renames the library. Pre-release: the
 * version stays 1 until the first release.
 */
uint32_t gpufx_version(void);

/* Message of the last error on this thread. Never NULL; valid until the next call. */
const char *gpufx_last_error(void);

/*
 * Pixel formats gpufx_effect_process_frames() takes and writes: "rgba", "rgba64le",
 * "nv12", "p010le", "yuv420p", "yuv422p", "yuv444p", their 10-bit "...10le" versions,
 * "yuva420p", "yuva444p". Static strings.
 */
uint32_t gpufx_format_count(void);
const char *gpufx_format_name(uint32_t index);
/* 1 if format is one of the above or an alias ("yuvj420p" and the like), else 0. */
int gpufx_format_supported(const char *format);

/*
 * Opens a graph of effects that runs in one GPU submission. The simplest graph is one
 * package or a chain of them:
 *   "vignette.zip"
 *   "wipe.zip=progress=t/2:angle=45|vignette.zip"
 * and the general form wires them with labels:
 *   "[0]split[a][b]; [a]blur.zip[ba]; [b]gray.zip|vignette.zip[gb]; [ba][gb]crossfade.zip[out]"
 * A package is a path (.zip file or unpacked directory). Effects opened from the same
 * path with the same backend share the compiled package while any of them is open: the
 * file is read again only after all of them are freed.
 * backend: NULL or "auto", "vulkan", "dx12", "metal".
 *
 * Statements are separated by ';'. Each reads labels, runs a node and writes labels.
 * [0], [1]... are the input pads (named "in0", "in1"...); every pad up to the highest
 * must be read. Other labels (letters, digits, '_', '-') are written once and read at
 * most once (split them to read them twice). Labels no statement reads are the output
 * pads, in the order they are written; gpufx_effect_output_name() gives their labels.
 * A node is:
 *   split         one label in, any number out (two when unlabelled), no copy (the
 *                 outputs are the input)
 *   null          one label in, one out, no copy
 *   a.zip|b.zip   packages chained: each effect takes the first unlabelled output of the
 *                 one before it; as many labels in as the first package has inputs.
 *                 Only the first package may take more than one input.
 * Labels after a package name its outputs from the first ("a.zip[x][y]"), or by
 * manifest name ("a.zip[matte=m]"); "[src=0][bg=1]a.zip" names inputs the same way.
 * One style per side of a package. A last package without labels writes all its
 * outputs as output pads; any other output without a label is dropped.
 * As in an FFmpeg filtergraph, labels may be left out. A statement without input labels
 * reads the input pads no label of the graph names, the lowest first (as many as its
 * first package has inputs, one for split and null): "[0][1]crossfade.zip" and
 * "crossfade.zip" read the same pads, and in "[1]a.zip[x]; b.zip[y]; ..." b.zip reads
 * [0]. Unlike ffmpeg -filter_complex, which binds the first unused stream in order,
 * this looks ahead at later statements too, because a pad may be read only once. A
 * statement without output labels writes output pads (named "out0", "out1"...,
 * skipping labels the graph uses; an unlabelled split writes two). On each side the
 * labels are left out entirely or all given. A graph of one statement without any
 * label whose node is a package chain (not split or null) is a chain: its input pads are
 * named after the inputs of the first package's manifest and its one output is
 * "default", as one FFmpeg filter; any label switches to "in0"... and "out0"... names.
 * A lone "null" is a valid graph that passes [0] through.
 *
 * An effect writes the size of its first input. Every input is uploaded once and every
 * output read back once; edges stay on the GPU in pooled textures that are reused once
 * their last reader has run. Between two effects the textures are RGBA on the GPU,
 * whatever the stream format is (no chroma subsampling, alpha kept). Cycles, labels read
 * but never written, written twice or read twice, unread pads and wrong label counts fail here;
 * the manifest size and format rules of every node are checked by
 * gpufx_effect_check_inputs().
 *
 * Inline options: a package takes named key=value pairs after its path, separated by
 * ':' (or '&'), as an FFmpeg filter does: "blur.zip=radius=8:enable=gt(t,1)". A key is
 * a parameter of that package, "enable" (an expression switching the effect, as
 * gpufx_effect_set_node_enabled() does per frame) or "bypass" ("0" or "auto"). '\'
 * escapes the next character (one of \ ' : & ; | = [ ]; before any other it is a plain
 * '\', as in Windows paths) and '...' quotes, so a path or value may hold ':', '|', '=',
 * '[', ']' or ';'; commas need no escape. An unknown key, a key given twice or a bypass
 * other than 0/auto fails here. Parameter values that are constants ("0.5", "1,0,0",
 * "#ff8800") are applied at open; expression values and the "enable"/"bypass" keys are
 * NOT applied: the library evaluates no expression, so the caller reads every option
 * back with gpufx_effect_option_count()/gpufx_effect_option() and evaluates the rest
 * itself.
 *
 * Parameters are named over all packages, in statement order (see
 * gpufx_effect_param_name()); gpufx_effect_find_param() also takes "label.name" where
 * label is the output label of a node ("ba.radius"). The other functions describe the
 * graph: input formats are every format the GPU converts,
 * gpufx_effect_output_format*() describe output 0.
 * No GPU device is made here: shaders are checked on a device with no GPU, limited to
 * the WebGPU default formats. The device comes from gpufx_effect_use_* or the first
 * frame, so a missing GPU is reported there, not by open.
 */
GpufxEffect *gpufx_effect_open_graph(const char *graph, const char *backend);

/*
 * Inline options of the effects, in the order they were written: effect gets the index
 * of the effect (as in "index.name"), key and value strings owned by fx.
 */
uint32_t gpufx_effect_option_count(const GpufxEffect *fx);
int gpufx_effect_option(const GpufxEffect *fx, uint32_t index, uint32_t *effect,
                        const char **key, const char **value);
void gpufx_effect_free(GpufxEffect *fx);

/* Strings below are owned by the effect and live as long as it does. */
const char *gpufx_effect_name(const GpufxEffect *fx);
/*
 * Adapter and API in use, e.g. "NVIDIA GeForce RTX 4070 (Vulkan)". An effect is opened
 * without a device: it gets one from gpufx_effect_use_vulkan/d3d12/d3d11/videotoolbox(), or else the
 * backend's own from gpufx_effect_use_default_device() or its first frame (the string
 * says so until then).
 */
const char *gpufx_effect_device(const GpufxEffect *fx);
/* Makes or reuses the device of the backend given at open, unless the effect has a device. */
int gpufx_effect_use_default_device(GpufxEffect *fx);

uint32_t gpufx_effect_input_count(const GpufxEffect *fx);
const char *gpufx_effect_input_name(const GpufxEffect *fx, uint32_t index);

/*
 * Pixel formats an input accepts (FFmpeg names): every format the GPU converter
 * supports (the manifest has no `formats` field). Formats outside the list are
 * rejected by gpufx_effect_check_inputs().
 */
uint32_t gpufx_effect_input_format_count(const GpufxEffect *fx, uint32_t input);
const char *gpufx_effect_input_format(const GpufxEffect *fx, uint32_t input, uint32_t index);

/*
 * Pixel formats output pad 0 may have: every format the GPU converter writes (the
 * manifest has no `formats` field). The sw_format default is that of the output's
 * source input when it is in the list, else "rgba"; the filter option out_format
 * overrides it.
 */
uint32_t gpufx_effect_output_format_count(const GpufxEffect *fx);
const char *gpufx_effect_output_format(const GpufxEffect *fx, uint32_t index);

/*
 * Output pads: one per output of the last effect for an effect or a chain
 * ("default" for one, else the manifest output names), any number for a graph
 * (named after their labels).
 */
uint32_t gpufx_effect_output_count(const GpufxEffect *fx);
const char *gpufx_effect_output_name(const GpufxEffect *fx, uint32_t output);
/*
 * The input pad output follows (effects follow their first input): its frame
 * rate and aspect ratio, and its size unless an effect stacks its inputs (see
 * gpufx_effect_output_size()). A negative value when there is no such output.
 */
int gpufx_effect_output_source(const GpufxEffect *fx, uint32_t output);
/*
 * Size of output for input pads of these sizes (count = the input count):
 * the size of its gpufx_effect_output_source() pad, or for effects such as
 * hstack/vstack (manifest output size) the stacked size. 0 on success; a
 * negative value (see gpufx_last_error()) when the sizes break a size rule or
 * the output is larger than the GPU allows.
 */
int gpufx_effect_output_size(const GpufxEffect *fx, uint32_t output, const GpufxStreamInfo *streams, uint32_t count,
                             uint32_t *width, uint32_t *height);
/* gpufx_effect_output_format*() for any output pad. */
uint32_t gpufx_effect_output_pad_format_count(const GpufxEffect *fx, uint32_t output);
const char *gpufx_effect_output_pad_format(const GpufxEffect *fx, uint32_t output, uint32_t index);

/*
 * Checks one stream per input against the manifest rules (pixel format, size limits,
 * same_size). Returns a negative value and sets gpufx_last_error() on a mismatch.
 */
int gpufx_effect_check_inputs(const GpufxEffect *fx, const GpufxStreamInfo *streams, uint32_t count);

/*
 * Parameters. For one effect the names are those of the manifest. In a chain they are
 * "label.name", where label is the package file name without ".zip", or "index.name"
 * (0 based) when two packages share a label or the label is a number.
 */
uint32_t gpufx_effect_param_count(const GpufxEffect *fx);
const char *gpufx_effect_param_name(const GpufxEffect *fx, uint32_t index);
/* Numbers parameter index takes: 1 for a scalar, 2 to 4 for a vector or a color, 0 for an
 * expression parameter. Negative (gpufx_last_error()) for a bad index. */
int gpufx_effect_param_components(const GpufxEffect *fx, uint32_t index);

/*
 * Index of a parameter for gpufx_effect_param_name(). Takes the full name, "label.name",
 * "index.name", or a bare name that only one effect of the chain has. A prefix of
 * digits is always an index. Returns a negative
 * value and sets gpufx_last_error() when no parameter or several match.
 * The functions below take the same names.
 */
int gpufx_effect_find_param(const GpufxEffect *fx, const char *name);

/* Sets a parameter from text: "0.5", "1,0,0", "#ff8800", "true". */
int gpufx_effect_set_param(GpufxEffect *fx, const char *name, const char *value);
/* Sets the first count (1..4) components of a parameter. */
int gpufx_effect_set_param_values(GpufxEffect *fx, const char *name,
                                  const double *values, uint32_t count);

/*
 * Effects of a chain or graph switched on and off. node names effects as
 * the prefix of a parameter name does: a package label naming one effect, an index
 * ("0", "1"... always valid) or a graph statement's output label (every effect of that
 * statement); "" is the only effect of a single effect. An effect switched off copies
 * its first input into its output, without planning or binding anything again.
 * gpufx_effect_find_node returns 0 when node names effects, else -1.
 * gpufx_effect_all_nodes_disabled returns 1 when every effect is off: the outputs are
 * then their input pads, as with the filter disabled.
 */
int gpufx_effect_find_node(const GpufxEffect *fx, const char *node);
int gpufx_effect_set_node_enabled(GpufxEffect *fx, const char *node, int enabled);
int gpufx_effect_all_nodes_disabled(const GpufxEffect *fx);

/*
 * Which input passes when switched off.
 * gpufx_effect_set_node_bypass picks the input the effects node names copy while off:
 * an input index of each (0 by default), or GPUFX_BYPASS_LAST for the last input of
 * each. It fails when an effect has no such input. An input of another size than the
 * effect's output makes processing fail while the effect is off.
 * gpufx_effect_set_bypass picks the input pad every output passes when the whole effect
 * is bypassed (info NULL): a pad index, GPUFX_BYPASS_FIRST (default: the pad each output
 * has the size of) or GPUFX_BYPASS_NODES (the pad reached through the inputs the effects
 * pass when off, for every effect off). gpufx_effect_bypass_pad returns the pad output
 * passes by that choice, or -1.
 */
#define GPUFX_BYPASS_FIRST  (-1)
#define GPUFX_BYPASS_NODES  (-2)
#define GPUFX_BYPASS_LAST   (-3)
int gpufx_effect_set_node_bypass(GpufxEffect *fx, const char *node, int input);
/*
 * Writes the indices of the effects node names to out (at most capacity of them, out may
 * be NULL) and returns how many there are, or -1 when node names none. Two names that
 * give equal lists name the same effects.
 */
int gpufx_effect_node_effects(const GpufxEffect *fx, const char *node, int *out, int capacity);
int gpufx_effect_set_bypass(GpufxEffect *fx, int pad);
int gpufx_effect_bypass_pad(const GpufxEffect *fx, int output);

/*
 * Runs the effect. inputs holds one image per input, in order. out must have the size of
 * inputs[0]. Fails when the input sizes break the manifest rules.
 * Same as gpufx_effect_process_frames() with "rgba" frames.
 */
int gpufx_effect_process(GpufxEffect *fx, const GpufxImage *inputs, uint32_t nb_inputs,
                         const GpufxOutput *out, const GpufxFrameInfo *info);

/*
 * Runs the effect on frames of any gpufx_format_name() format: inputs are converted to
 * RGBA (rgba16float, so 10-bit survives) on the GPU, every effect of the chain runs, and
 * the result is converted to out's format and colour properties on the GPU before it is
 * read back. Inputs and out may each have another format. out must have the size of
 * inputs[0]. The planes of out must not overlap each other or any input plane (refused). The manifest format rules are the caller's to check
 * (gpufx_effect_check_inputs()); the frames' formats here are only how they are stored.
 */
int gpufx_effect_process_frames(GpufxEffect *fx, const GpufxFrame *inputs, uint32_t nb_inputs,
                                const GpufxFrameOut *out, const GpufxFrameInfo *info);

/*
 * gpufx_effect_process_frames() for any number of outputs: outs holds
 * one frame per output pad, each the size of its gpufx_effect_output_source() input.
 * Everything runs in one GPU submission and all outputs are read back together through
 * one shared buffer. No plane may overlap another (refused).
 * gpufx_effect_process_frames() and gpufx_effect_convert_frame() refuse a graph with
 * several outputs.
 */
int gpufx_effect_process_graph(GpufxEffect *fx, const GpufxFrame *inputs, uint32_t nb_inputs,
                               const GpufxFrameOut *outs, uint32_t nb_outputs,
                               const GpufxFrameInfo *info);

/*
 * Bypass for any number of outputs: each output is its
 * gpufx_effect_output_source() input converted to its format, without running the effects.
 * inputs may hold only the first pads, as long as every output's source is among them.
 */
int gpufx_effect_convert_graph(GpufxEffect *fx, const GpufxFrame *inputs, uint32_t nb_inputs,
                               const GpufxFrameOut *outs, uint32_t nb_outputs);

/*
 * Converts input to out's format and colour properties without running
 * the effects, as a disabled filter passes its first input through. input stands for
 * the first input; out must have its size.
 */
int gpufx_effect_convert_frame(GpufxEffect *fx, const GpufxFrame *input, const GpufxFrameOut *out);

/*
 * Vulkan frames without copies. The effect runs on a Vulkan device the
 * caller made (FFmpeg's AVVulkanDeviceContext) and reads and writes its VkImages in
 * place. Handles are passed without <vulkan/vulkan.h>: dispatchable handles as
 * pointers, non-dispatchable ones (VkImage, VkSemaphore) as uint64_t.
 */

/* 1 when this library can share a Vulkan device (Linux, Windows), else 0. */
int gpufx_vulkan_supported(void);

typedef struct GpufxVulkanDevice {
    void *get_instance_proc_addr; /* PFN_vkGetInstanceProcAddr of the instance's loader */
    void *instance;               /* VkInstance */
    void *physical_device;        /* VkPhysicalDevice */
    void *device;                 /* VkDevice */
    uint32_t api_version;         /* API version of the instance, at least 1.1 */
    /*
     * The queue gpufx submits to (a family with graphics and compute, since wgpu records render
     * passes; and the queue in it), and the VkDeviceQueueCreateFlags it was created with.
     * While gpufx_effect_process_vulkan() runs, no other thread may submit to that queue (lock it around the call).
     */
    uint32_t queue_family;
    uint32_t queue_index;
    uint32_t queue_flags;
    /* Extensions enabled on the instance and on the device. */
    uint32_t nb_instance_extensions;
    const char *const *instance_extensions;
    uint32_t nb_device_extensions;
    const char *const *device_extensions;
    /*
     * VkPhysicalDeviceFeatures2 chain of the features enabled on the device: gpufx
     * (wgpu) uses no feature or extension the device was not created with. Only read
     * during gpufx_effect_use_vulkan().
     */
    const void *device_features;
} GpufxVulkanDevice;

/*
 * Moves an open effect (and its parameter values) to the Vulkan device dev: the packages
 * are compiled again for it, unless an effect already uses that device (shared, by
 * VkDevice, like the packages). dev must outlive the effect. Only effects moved this way
 * take gpufx_effect_process_vulkan().
 */
int gpufx_effect_use_vulkan(GpufxEffect *fx, const GpufxVulkanDevice *dev);

/*
 * A frame of Vulkan images, one VkImage per plane of format (FFmpeg: one image per plane,
 * i.e. AVVulkanFramesContext without multiplane images), each of the per-plane formats
 * VK_FORMAT_R8_UNORM, R8G8_UNORM, R8G8B8A8_UNORM or their R16 versions, as FFmpeg uses
 * them. Inputs need SAMPLED usage, outputs STORAGE.
 */
typedef struct GpufxVulkanFrame {
    const char *format;          /* pixel format of the planes (FFmpeg's sw_format name) */
    uint32_t width;
    uint32_t height;
    uint32_t nb_images;          /* one per plane */
    uint64_t image[4];           /* VkImage */
    int32_t vk_format[4];        /* VkFormat of each image */
    int32_t layout[4];           /* in: VkImageLayout; out: the layout it is left in */
    uint64_t semaphore[4];       /* timeline VkSemaphore of each image */
    uint64_t sem_value[4];       /* in: value to wait for; out: value signalled when done */
    uint32_t queue_family[4];    /* owner, or VK_QUEUE_FAMILY_IGNORED (concurrent sharing) */
    GpufxColor color;
} GpufxVulkanFrame;

/*
 * gpufx_effect_process_graph() on Vulkan frames: one submission to the device's queue
 * waits for every image's semaphore at sem_value, runs the conversions and effects
 * reading and writing the images directly (no copy, no readback), and signals each
 * semaphore at sem_value + 1. On return the work is submitted, not finished: layout and
 * sem_value of every image are updated, and the caller stores them in its frames
 * (AVVkFrame) while it still holds them (lock_frame). With info NULL the effects are
 * bypassed as in gpufx_effect_convert_graph().
 * The effect keeps wrappers (image views, bind groups) of the images of recent frames
 * until gpufx_effect_free(): every image passed here must stay valid until then (keep a
 * reference to its frames context), and a destroyed image must not come back under the
 * same VkImage and semaphore handles while the effect lives.
 */
int gpufx_effect_process_vulkan(GpufxEffect *fx, GpufxVulkanFrame *inputs, uint32_t nb_inputs,
                                GpufxVulkanFrame *outs, uint32_t nb_outputs,
                                const GpufxFrameInfo *info);

/*
 * Direct3D 12 and Direct3D 11 frames on the GPU (Windows; elsewhere the
 * functions fail). Handles are passed as void pointers, without <d3d12.h>.
 *
 * D3D12: the effect runs on the caller's ID3D12Device (FFmpeg's AVD3D12VADeviceContext)
 * and reads and writes its resources in place: NV12 and P010 resources plane by plane
 * (plane slices), RGBA8/RGBA16 ones as they are. What cannot be used in place costs one
 * GPU copy into a texture gpufx keeps (one frame per pad): an input that is a slice of a
 * texture array (decoders) or larger than the frame, and an output without
 * D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS.
 */

/* 1 when this library takes D3D12 and D3D11 frames (Windows), else 0. */
int gpufx_d3d12_supported(void);

typedef struct GpufxD3D12Device {
    void *device; /* ID3D12Device */
} GpufxD3D12Device;

/*
 * Moves an open effect (and its parameter values) to the D3D12 device dev, as
 * gpufx_effect_use_vulkan() does. Fails when wgpu does not get the same ID3D12Device for
 * the device's adapter (another adapter than wgpu lists, another D3D12 runtime).
 */
int gpufx_effect_use_d3d12(GpufxEffect *fx, const GpufxD3D12Device *dev);

typedef struct GpufxD3D12Frame {
    const char *format;   /* nv12, p010le, rgba or rgba64le (FFmpeg's sw_format name) */
    uint32_t width;
    uint32_t height;
    void *resource;       /* ID3D12Resource (AVD3D12VAFrame.texture) */
    uint32_t subresource; /* array slice (AVD3D12VAFrame.subresource_index) */
    void *fence;          /* ID3D12Fence (AVD3D12VAFrame.sync_ctx.fence) */
    uint64_t fence_value; /* in: value to wait for; out: value signalled when done */
    GpufxColor color;
} GpufxD3D12Frame;

/*
 * gpufx_effect_process_graph() on D3D12 frames: one submission on gpufx's queue of the
 * device waits for every frame's fence at fence_value, runs the effects and signals each
 * fence at fence_value + 1 (fence_value is updated; store it in the frame). Frames are in
 * D3D12_RESOURCE_STATE_COMMON before and after. On return the work is submitted; the
 * next call waits until it is done, since FFmpeg's uploads into a frame do not wait for
 * its fence. With info NULL the effects are bypassed.
 */
int gpufx_effect_process_d3d12(GpufxEffect *fx, GpufxD3D12Frame *inputs, uint32_t nb_inputs,
                               GpufxD3D12Frame *outs, uint32_t nb_outputs,
                               const GpufxFrameInfo *info);

/*
 * D3D11: wgpu has no D3D11 backend, so the effect runs on wgpu's D3D12 device of the same
 * adapter. Textures made with D3D11_RESOURCE_MISC_SHARED_NTHANDLE are opened there
 * without a copy (outputs must be such textures); other inputs are copied once on the
 * immediate context into a shared texture gpufx keeps (one frame per input pad). A fence
 * shared by both devices orders the work: D3D11 work queued after the call waits for the
 * effects on the GPU. Needs D3D11.4 (ID3D11Device5, Windows 10 1703 or later).
 */
typedef struct GpufxD3D11Device {
    void *device;         /* ID3D11Device */
    void *device_context; /* its immediate ID3D11DeviceContext */
} GpufxD3D11Device;

int gpufx_effect_use_d3d11(GpufxEffect *fx, const GpufxD3D11Device *dev);

typedef struct GpufxD3D11Frame {
    const char *format;   /* nv12, p010le, rgba or rgba64le */
    uint32_t width;
    uint32_t height;
    void *texture;        /* ID3D11Texture2D (AVFrame.data[0]) */
    uint32_t array_slice; /* (intptr_t)AVFrame.data[1] */
    GpufxColor color;
} GpufxD3D11Frame;

/* As gpufx_effect_process_d3d12(); the caller holds the immediate context's lock. */
int gpufx_effect_process_d3d11(GpufxEffect *fx, const GpufxD3D11Frame *inputs, uint32_t nb_inputs,
                               const GpufxD3D11Frame *outs, uint32_t nb_outputs,
                               const GpufxFrameInfo *info);

/*
 * VideoToolbox frames (macOS; elsewhere the functions fail). A frame is
 * FFmpeg's AV_PIX_FMT_VIDEOTOOLBOX frame: a CVPixelBufferRef (AVFrame.data[3]) backed by
 * an IOSurface, in nv12 (420v/420f) or p010le (x420/xf20). The effect runs on the system's
 * Metal device and reads and writes the IOSurface planes in place (R8 + RG8, R16 + RG16
 * textures). Writing p010le needs R16/RG16 storage textures, which some GPUs lack: the
 * call then fails with a message saying so.
 */

/* 1 when this library takes VideoToolbox frames (macOS), else 0. */
int gpufx_videotoolbox_supported(void);

/*
 * Moves an open effect (and its parameter values) to the Metal device used for
 * VideoToolbox frames, as gpufx_effect_use_vulkan() does.
 */
int gpufx_effect_use_videotoolbox(GpufxEffect *fx);

typedef struct GpufxVtFrame {
    const char *format;  /* nv12 or p010le (FFmpeg's sw_format name), as the buffer's */
    uint32_t width;
    uint32_t height;
    void *pixel_buffer;  /* CVPixelBufferRef (AVFrame.data[3]) */
    GpufxColor color;
} GpufxVtFrame;

/*
 * gpufx_effect_process_graph() on VideoToolbox frames. There is no fence: the call
 * returns once the GPU work is done, so the buffers can be read (hwdownload) or encoded
 * right away. The caller keeps other users off the buffers during the call. With info
 * NULL the effects are bypassed.
 */
int gpufx_effect_process_videotoolbox(GpufxEffect *fx, const GpufxVtFrame *inputs, uint32_t nb_inputs,
                                      const GpufxVtFrame *outs, uint32_t nb_outputs,
                                      const GpufxFrameInfo *info);

/*
 * Frame interpolation with a gpufx-nn package whose io.json has kind
 * "frame_interp" (RIFE v4, docs/NN_MODEL_FORMAT.md), on the GPU frames above. Same frames,
 * devices and synchronisation as the gpufx_effect_*_vulkan/d3d12/d3d11/videotoolbox calls.
 *
 * Each process call takes the next source frame (input) and makes nb_outputs frames
 * between the previous source frame and it, frame k at time times[k] in (0, 1] (0: the
 * previous frame, 1: input). A time of 1 copies the source frame into that output. The
 * source frame is converted to RGBA once and kept on the GPU for the next call, so the
 * caller need not hold it. Only times below 1 need a previous source frame: on the first
 * call after open, gpufx_ai_interp_reset() or a change of frame size such outputs fail, so
 * pass nb_outputs 0 or only times of 1 (the source frame is still taken for the next call). The
 * outputs have the input's size; the source frames themselves are not written.
 */
typedef struct GpufxAiInterp GpufxAiInterp;

/* Checks that model names a file; the model is loaded by gpufx_ai_interp_use_*. */
GpufxAiInterp *gpufx_ai_interp_open(const char *model);
void gpufx_ai_interp_free(GpufxAiInterp *ai);
/* The device the model runs on, "" before gpufx_ai_interp_use_*. */
const char *gpufx_ai_interp_device(const GpufxAiInterp *ai);

/*
 * Scene change threshold, an SSIM in 0..1 checked as the official RIFE inference_video.py
 * does (both frames scaled to 32x32, SSIM over RGB): a pair whose SSIM is below it is a cut,
 * and each frame made is the nearer source frame instead of an interpolation. 0 (the default)
 * interpolates every pair; RIFE uses 0.2.
 */
int gpufx_ai_interp_set_scene(GpufxAiInterp *ai, double threshold);
/* Forgets the previous source frame (a discontinuity): the next call makes no frame below time 1. */
void gpufx_ai_interp_reset(GpufxAiInterp *ai);

/* Load the model on the caller's device (once; a later call with the same device is free). */
int gpufx_ai_interp_use_vulkan(GpufxAiInterp *ai, const GpufxVulkanDevice *dev);
int gpufx_ai_interp_use_d3d12(GpufxAiInterp *ai, const GpufxD3D12Device *dev);
int gpufx_ai_interp_use_d3d11(GpufxAiInterp *ai, const GpufxD3D11Device *dev);
int gpufx_ai_interp_use_videotoolbox(GpufxAiInterp *ai);

/*
 * As gpufx_effect_process_vulkan() and the others with one input and nb_outputs outputs
 * (outs may be NULL when nb_outputs is 0); the semaphore values, layouts and fence values
 * of input and outs are updated the same way.
 */
int gpufx_ai_interp_process_vulkan(GpufxAiInterp *ai, GpufxVulkanFrame *input,
                                   GpufxVulkanFrame *outs, uint32_t nb_outputs, const float *times);
int gpufx_ai_interp_process_d3d12(GpufxAiInterp *ai, GpufxD3D12Frame *input,
                                  GpufxD3D12Frame *outs, uint32_t nb_outputs, const float *times);
/* The caller holds the immediate context's lock. */
int gpufx_ai_interp_process_d3d11(GpufxAiInterp *ai, const GpufxD3D11Frame *input,
                                  const GpufxD3D11Frame *outs, uint32_t nb_outputs, const float *times);
int gpufx_ai_interp_process_videotoolbox(GpufxAiInterp *ai, const GpufxVtFrame *input,
                                         const GpufxVtFrame *outs, uint32_t nb_outputs,
                                         const float *times);

/*
 * Super resolution with a gpufx-nn package (or multi-scale bundle) whose io.json has kind
 * "super_resolution" (Real-ESRGAN, docs/NN_MODEL_FORMAT.md), on the GPU frames above. Same
 * frames, devices and synchronisation as gpufx_ai_interp_*.
 *
 * Each process call converts input to RGBA, runs the model on it in tiles and writes the result
 * into out, which must be scale times the input's size on each axis (any supported format; the
 * input is only read). Frames of a new size are fine: the tiles are laid out again for them.
 */
typedef struct GpufxAiUpscale GpufxAiUpscale;

/* GPUFX_AI_PRECISION_*: the arithmetic of the convolutions. */
#define GPUFX_AI_PRECISION_AUTO 0 /* f16 where the device has it, else f32 */
#define GPUFX_AI_PRECISION_F32  1

/*
 * Checks that model exists; the model (the variant of scale, for a bundle) is loaded by
 * gpufx_ai_upscale_use_*, which fails when the package has no such scale (the error lists the
 * scales it has). tile: largest tile side in input pixels, 0 picks the fewest tiles that fit
 * the device's buffer limits.
 */
GpufxAiUpscale *gpufx_ai_upscale_open(const char *model, uint32_t scale, uint32_t tile, int precision);
void gpufx_ai_upscale_free(GpufxAiUpscale *ai);
/* The device the model runs on and its precision, "" before gpufx_ai_upscale_use_*, NULL when ai is NULL. */
const char *gpufx_ai_upscale_device(const GpufxAiUpscale *ai);

/* Load the model on the caller's device (once; a later call with the same device is free). */
int gpufx_ai_upscale_use_vulkan(GpufxAiUpscale *ai, const GpufxVulkanDevice *dev);
int gpufx_ai_upscale_use_d3d12(GpufxAiUpscale *ai, const GpufxD3D12Device *dev);
int gpufx_ai_upscale_use_d3d11(GpufxAiUpscale *ai, const GpufxD3D11Device *dev);
int gpufx_ai_upscale_use_videotoolbox(GpufxAiUpscale *ai);

/*
 * As gpufx_effect_process_vulkan() and the others with one input and one output; the
 * semaphore values, layouts and fence values of input and out are updated the same way.
 */
int gpufx_ai_upscale_process_vulkan(GpufxAiUpscale *ai, GpufxVulkanFrame *input, GpufxVulkanFrame *out);
int gpufx_ai_upscale_process_d3d12(GpufxAiUpscale *ai, GpufxD3D12Frame *input, GpufxD3D12Frame *out);
/* The caller holds the immediate context's lock. */
int gpufx_ai_upscale_process_d3d11(GpufxAiUpscale *ai, const GpufxD3D11Frame *input,
                                   const GpufxD3D11Frame *out);
int gpufx_ai_upscale_process_videotoolbox(GpufxAiUpscale *ai, const GpufxVtFrame *input,
                                          const GpufxVtFrame *out);

#ifdef __cplusplus
}
#endif

#endif /* GPUFX_H */
