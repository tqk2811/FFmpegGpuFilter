//! Frame interpolation (`gpufx_ai_interp_*`) and super resolution (`gpufx_ai_upscale_*`) with gpufx-nn packages
//! on the frames of the GPU frame APIs. See `include/gpufx.h`.

use std::ffi::{c_char, c_int, CString};
use std::sync::Arc;

use gpufx_core::nn::{InterpFrames, Precision, UpscaleFrames, UpscaleOptions};
use gpufx_core::GpuContext;

use super::{
    guard, str_arg, GpufxD3D11Device, GpufxD3D11Frame, GpufxD3D12Device, GpufxD3D12Frame, GpufxVtFrame, GpufxVulkanDevice, GpufxVulkanFrame,
};

pub struct GpufxAiInterp {
    path: String,
    /// The model on its device, once given one.
    run: Option<InterpFrames>,
    device: CString,
    threshold: f32,
}

impl GpufxAiInterp {
    /// Loads the model on `ctx` (once per device).
    fn open_on(&mut self, ctx: Arc<GpuContext>, api: &str) -> Result<(), String> {
        if self.run.as_ref().is_some_and(|r| Arc::ptr_eq(r.context(), &ctx)) {
            return Ok(());
        }
        let device = format!("{} ({api} device shared with the caller)", ctx.description());
        let mut run = InterpFrames::open(ctx, &self.path).map_err(|e| format!("{}: {e}", self.path))?;
        run.set_scene_threshold(self.threshold).map_err(|e| e.to_string())?;
        self.run = Some(run);
        self.device = CString::new(device).unwrap_or_default();
        Ok(())
    }

    /// The model, with the times of the next call set.
    unsafe fn ready(&mut self, times: *const f32, n: u32) -> Result<&mut InterpFrames, String> {
        let run = self.run.as_mut().ok_or("no device yet: call gpufx_ai_interp_use_* first")?;
        let times = if n == 0 {
            &[][..]
        } else if times.is_null() {
            return Err("times is NULL".into());
        } else {
            std::slice::from_raw_parts(times, n as usize)
        };
        run.set_times(times).map_err(|e| e.to_string())?;
        Ok(run)
    }
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_interp_open(model: *const c_char) -> *mut GpufxAiInterp {
    guard(std::ptr::null_mut(), || {
        let path = str_arg(model, "model")?;
        let meta = std::fs::metadata(path).map_err(|e| format!("{path}: {e}"))?;
        if !meta.is_file() {
            return Err(format!("{path}: not a file"));
        }
        let ai = GpufxAiInterp { path: path.to_string(), run: None, device: CString::default(), threshold: 0.0 };
        Ok(Box::into_raw(Box::new(ai)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_interp_free(ai: *mut GpufxAiInterp) {
    if !ai.is_null() {
        drop(Box::from_raw(ai));
    }
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_interp_device(ai: *const GpufxAiInterp) -> *const c_char {
    ai.as_ref().map_or(std::ptr::null(), |ai| ai.device.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_interp_set_scene(ai: *mut GpufxAiInterp, threshold: f64) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("interp is NULL")?;
        let threshold = threshold as f32;
        if let Some(run) = ai.run.as_mut() {
            run.set_scene_threshold(threshold).map_err(|e| e.to_string())?;
        } else if !(0.0..=1.0).contains(&threshold) {
            return Err(format!("scene threshold {threshold} is not in [0, 1]"));
        }
        ai.threshold = threshold;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_interp_reset(ai: *mut GpufxAiInterp) {
    if let Some(run) = ai.as_mut().and_then(|ai| ai.run.as_mut()) {
        run.reset();
    }
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_interp_use_vulkan(ai: *mut GpufxAiInterp, dev: *const GpufxVulkanDevice) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("interp is NULL")?;
        let dev = dev.as_ref().ok_or("device is NULL")?;
        imp::use_vulkan(ai, dev)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_interp_process_vulkan(
    ai: *mut GpufxAiInterp,
    input: *mut GpufxVulkanFrame,
    outs: *mut GpufxVulkanFrame,
    nb_outputs: u32,
    times: *const f32,
) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("interp is NULL")?;
        imp::process_vulkan(ai, input, outs, nb_outputs, times)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_interp_use_d3d12(ai: *mut GpufxAiInterp, dev: *const GpufxD3D12Device) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("interp is NULL")?;
        let dev = dev.as_ref().ok_or("device is NULL")?;
        imp::use_d3d12(ai, dev)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_interp_process_d3d12(
    ai: *mut GpufxAiInterp,
    input: *mut GpufxD3D12Frame,
    outs: *mut GpufxD3D12Frame,
    nb_outputs: u32,
    times: *const f32,
) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("interp is NULL")?;
        imp::process_d3d12(ai, input, outs, nb_outputs, times)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_interp_use_d3d11(ai: *mut GpufxAiInterp, dev: *const GpufxD3D11Device) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("interp is NULL")?;
        let dev = dev.as_ref().ok_or("device is NULL")?;
        imp::use_d3d11(ai, dev)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_interp_process_d3d11(
    ai: *mut GpufxAiInterp,
    input: *const GpufxD3D11Frame,
    outs: *const GpufxD3D11Frame,
    nb_outputs: u32,
    times: *const f32,
) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("interp is NULL")?;
        imp::process_d3d11(ai, input, outs, nb_outputs, times)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_interp_use_videotoolbox(ai: *mut GpufxAiInterp) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("interp is NULL")?;
        imp::use_videotoolbox(ai)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_interp_process_videotoolbox(
    ai: *mut GpufxAiInterp,
    input: *const GpufxVtFrame,
    outs: *const GpufxVtFrame,
    nb_outputs: u32,
    times: *const f32,
) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("interp is NULL")?;
        imp::process_videotoolbox(ai, input, outs, nb_outputs, times)?;
        Ok(0)
    })
}

/// The per-API halves, each built where its API exists (the others fail, as for effects).
mod imp {
    #[allow(unused_imports)]
    use super::*;

    #[cfg(any(windows, all(unix, not(target_vendor = "apple"))))]
    pub unsafe fn use_vulkan(ai: &mut GpufxAiInterp, dev: &GpufxVulkanDevice) -> Result<(), String> {
        let ctx = crate::vk::device_context(dev)?;
        ai.open_on(ctx, "Vulkan")
    }

    #[cfg(any(windows, all(unix, not(target_vendor = "apple"))))]
    pub unsafe fn process_vulkan(
        ai: &mut GpufxAiInterp,
        input: *mut GpufxVulkanFrame,
        outs: *mut GpufxVulkanFrame,
        n: u32,
        times: *const f32,
    ) -> Result<(), String> {
        let run = ai.ready(times, n)?;
        let raw = input.as_mut().ok_or("input is NULL")?;
        let mut frame = crate::vk::frame(raw, "input")?;
        let mut os = if n == 0 { Vec::new() } else { crate::vk::frames(outs, n, "out")? };
        run.process_vulkan(&mut frame, &mut os).map_err(|e| e.to_string())?;
        crate::vk::write_back(std::slice::from_ref(&frame), std::slice::from_mut(raw));
        if n > 0 {
            crate::vk::write_back(&os, std::slice::from_raw_parts_mut(outs, n as usize));
        }
        Ok(())
    }

    #[cfg(not(any(windows, all(unix, not(target_vendor = "apple")))))]
    pub unsafe fn use_vulkan(_: &mut GpufxAiInterp, _: &GpufxVulkanDevice) -> Result<(), String> {
        Err("this libgpufx is built without Vulkan frame support".into())
    }

    #[cfg(not(any(windows, all(unix, not(target_vendor = "apple")))))]
    pub unsafe fn process_vulkan(
        _: &mut GpufxAiInterp,
        _: *mut GpufxVulkanFrame,
        _: *mut GpufxVulkanFrame,
        _: u32,
        _: *const f32,
    ) -> Result<(), String> {
        Err("this libgpufx is built without Vulkan frame support".into())
    }

    #[cfg(windows)]
    pub unsafe fn use_d3d12(ai: &mut GpufxAiInterp, dev: &GpufxD3D12Device) -> Result<(), String> {
        let ctx = crate::dx::shared(dev.device as usize, || GpuContext::from_d3d12(dev.device))?;
        ai.open_on(ctx, "D3D12")
    }

    #[cfg(windows)]
    pub unsafe fn use_d3d11(ai: &mut GpufxAiInterp, dev: &GpufxD3D11Device) -> Result<(), String> {
        let ctx = crate::dx::shared(dev.device as usize, || GpuContext::from_d3d11(dev.device, dev.device_context))?;
        ai.open_on(ctx, "D3D11")
    }

    #[cfg(windows)]
    pub unsafe fn process_d3d12(
        ai: &mut GpufxAiInterp,
        input: *mut GpufxD3D12Frame,
        outs: *mut GpufxD3D12Frame,
        n: u32,
        times: *const f32,
    ) -> Result<(), String> {
        let run = ai.ready(times, n)?;
        let raw_in = crate::dx::list(input, 1, "input")?;
        let raw_out: &mut [GpufxD3D12Frame] = if n == 0 { &mut [] } else { crate::dx::list(outs, n, "outs")? };
        let mut ins = crate::dx::d3d12_frames(raw_in, "input")?;
        let mut os = crate::dx::d3d12_frames(raw_out, "out")?;
        run.process_d3d12(&mut ins[0], &mut os).map_err(|e| e.to_string())?;
        for (f, r) in ins.iter().zip(raw_in.iter_mut()).chain(os.iter().zip(raw_out.iter_mut())) {
            r.fence_value = f.fence_value;
        }
        Ok(())
    }

    #[cfg(windows)]
    pub unsafe fn process_d3d11(
        ai: &mut GpufxAiInterp,
        input: *const GpufxD3D11Frame,
        outs: *const GpufxD3D11Frame,
        n: u32,
        times: *const f32,
    ) -> Result<(), String> {
        let run = ai.ready(times, n)?;
        let ins = crate::dx::d3d11_frames(crate::dx::list(input as *mut GpufxD3D11Frame, 1, "input")?, "input")?;
        let os =
            if n == 0 { Vec::new() } else { crate::dx::d3d11_frames(crate::dx::list(outs as *mut GpufxD3D11Frame, n, "outs")?, "out")? };
        run.process_d3d11(&ins[0], &os).map_err(|e| e.to_string())
    }

    #[cfg(not(windows))]
    pub(super) const NO_DX: &str = "D3D12 and D3D11 frames are only supported on Windows";

    #[cfg(not(windows))]
    pub unsafe fn use_d3d12(_: &mut GpufxAiInterp, _: &GpufxD3D12Device) -> Result<(), String> {
        Err(NO_DX.into())
    }

    #[cfg(not(windows))]
    pub unsafe fn use_d3d11(_: &mut GpufxAiInterp, _: &GpufxD3D11Device) -> Result<(), String> {
        Err(NO_DX.into())
    }

    #[cfg(not(windows))]
    pub unsafe fn process_d3d12(
        _: &mut GpufxAiInterp,
        _: *mut GpufxD3D12Frame,
        _: *mut GpufxD3D12Frame,
        _: u32,
        _: *const f32,
    ) -> Result<(), String> {
        Err(NO_DX.into())
    }

    #[cfg(not(windows))]
    pub unsafe fn process_d3d11(
        _: &mut GpufxAiInterp,
        _: *const GpufxD3D11Frame,
        _: *const GpufxD3D11Frame,
        _: u32,
        _: *const f32,
    ) -> Result<(), String> {
        Err(NO_DX.into())
    }

    #[cfg(target_vendor = "apple")]
    pub unsafe fn use_videotoolbox(ai: &mut GpufxAiInterp) -> Result<(), String> {
        let ctx = crate::vt::context()?;
        ai.open_on(ctx, "VideoToolbox")
    }

    #[cfg(target_vendor = "apple")]
    pub unsafe fn process_videotoolbox(
        ai: &mut GpufxAiInterp,
        input: *const GpufxVtFrame,
        outs: *const GpufxVtFrame,
        n: u32,
        times: *const f32,
    ) -> Result<(), String> {
        let run = ai.ready(times, n)?;
        let ins = crate::vt::frames(input, 1, "input")?;
        let os = if n == 0 { Vec::new() } else { crate::vt::frames(outs, n, "outs")? };
        run.process_videotoolbox(&ins[0], &os).map_err(|e| e.to_string())
    }

    #[cfg(not(target_vendor = "apple"))]
    pub fn use_videotoolbox(_: &mut GpufxAiInterp) -> Result<(), String> {
        Err("VideoToolbox frames are only supported on macOS".into())
    }

    #[cfg(not(target_vendor = "apple"))]
    pub unsafe fn process_videotoolbox(
        _: &mut GpufxAiInterp,
        _: *const GpufxVtFrame,
        _: *const GpufxVtFrame,
        _: u32,
        _: *const f32,
    ) -> Result<(), String> {
        Err("VideoToolbox frames are only supported on macOS".into())
    }
}

// ---- super resolution (gpufx_ai_upscale_*) ----

/// `GPUFX_AI_PRECISION_*` of gpufx.h.
const PRECISION_AUTO: c_int = 0;
const PRECISION_F32: c_int = 1;

pub struct GpufxAiUpscale {
    path: String,
    scale: u32,
    options: UpscaleOptions,
    /// The model on its device, once given one.
    run: Option<UpscaleFrames>,
    device: CString,
}

impl GpufxAiUpscale {
    /// Loads the model on `ctx` (once per device).
    fn open_on(&mut self, ctx: Arc<GpuContext>, api: &str) -> Result<(), String> {
        if self.run.as_ref().is_some_and(|r| Arc::ptr_eq(r.context(), &ctx)) {
            return Ok(());
        }
        let run = UpscaleFrames::open(ctx.clone(), &self.path, self.scale, self.options).map_err(|e| format!("{}: {e}", self.path))?;
        let precision = if run.upscale().model().uses_f16() { "f16" } else { "f32" };
        let device = format!("{} ({api} device shared with the caller), {precision}", ctx.description());
        self.run = Some(run);
        self.device = CString::new(device).unwrap_or_default();
        Ok(())
    }

    fn ready(&mut self) -> Result<&mut UpscaleFrames, String> {
        self.run.as_mut().ok_or_else(|| "no device yet: call gpufx_ai_upscale_use_* first".into())
    }
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_upscale_open(model: *const c_char, scale: u32, tile: u32, precision: c_int) -> *mut GpufxAiUpscale {
    guard(std::ptr::null_mut(), || {
        let path = str_arg(model, "model")?;
        std::fs::metadata(path).map_err(|e| format!("{path}: {e}"))?;
        if !(1..=16).contains(&scale) {
            return Err(format!("scale {scale} is not in 1..16"));
        }
        let precision = match precision {
            PRECISION_AUTO => Precision::Auto,
            PRECISION_F32 => Precision::F32,
            p => return Err(format!("unknown precision {p}")),
        };
        let options = UpscaleOptions { tile: (tile > 0).then_some(tile), max_tensor_bytes: None, precision };
        let ai = GpufxAiUpscale { path: path.to_string(), scale, options, run: None, device: CString::default() };
        Ok(Box::into_raw(Box::new(ai)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_upscale_free(ai: *mut GpufxAiUpscale) {
    if !ai.is_null() {
        drop(Box::from_raw(ai));
    }
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_upscale_device(ai: *const GpufxAiUpscale) -> *const c_char {
    ai.as_ref().map_or(std::ptr::null(), |ai| ai.device.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_upscale_use_vulkan(ai: *mut GpufxAiUpscale, dev: *const GpufxVulkanDevice) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("upscale is NULL")?;
        let dev = dev.as_ref().ok_or("device is NULL")?;
        up_imp::use_vulkan(ai, dev)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_upscale_process_vulkan(
    ai: *mut GpufxAiUpscale,
    input: *mut GpufxVulkanFrame,
    out: *mut GpufxVulkanFrame,
) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("upscale is NULL")?;
        up_imp::process_vulkan(ai, input, out)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_upscale_use_d3d12(ai: *mut GpufxAiUpscale, dev: *const GpufxD3D12Device) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("upscale is NULL")?;
        let dev = dev.as_ref().ok_or("device is NULL")?;
        up_imp::use_d3d12(ai, dev)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_upscale_process_d3d12(
    ai: *mut GpufxAiUpscale,
    input: *mut GpufxD3D12Frame,
    out: *mut GpufxD3D12Frame,
) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("upscale is NULL")?;
        up_imp::process_d3d12(ai, input, out)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_upscale_use_d3d11(ai: *mut GpufxAiUpscale, dev: *const GpufxD3D11Device) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("upscale is NULL")?;
        let dev = dev.as_ref().ok_or("device is NULL")?;
        up_imp::use_d3d11(ai, dev)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_upscale_process_d3d11(
    ai: *mut GpufxAiUpscale,
    input: *const GpufxD3D11Frame,
    out: *const GpufxD3D11Frame,
) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("upscale is NULL")?;
        up_imp::process_d3d11(ai, input, out)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_upscale_use_videotoolbox(ai: *mut GpufxAiUpscale) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("upscale is NULL")?;
        up_imp::use_videotoolbox(ai)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_ai_upscale_process_videotoolbox(
    ai: *mut GpufxAiUpscale,
    input: *const GpufxVtFrame,
    out: *const GpufxVtFrame,
) -> c_int {
    guard(-1, || {
        let ai = ai.as_mut().ok_or("upscale is NULL")?;
        up_imp::process_videotoolbox(ai, input, out)?;
        Ok(0)
    })
}

/// The per-API halves of the upscale calls, as `imp` for interpolation.
mod up_imp {
    #[allow(unused_imports)]
    use super::*;

    #[cfg(any(windows, all(unix, not(target_vendor = "apple"))))]
    pub unsafe fn use_vulkan(ai: &mut GpufxAiUpscale, dev: &GpufxVulkanDevice) -> Result<(), String> {
        let ctx = crate::vk::device_context(dev)?;
        ai.open_on(ctx, "Vulkan")
    }

    #[cfg(any(windows, all(unix, not(target_vendor = "apple"))))]
    pub unsafe fn process_vulkan(ai: &mut GpufxAiUpscale, input: *mut GpufxVulkanFrame, out: *mut GpufxVulkanFrame) -> Result<(), String> {
        let run = ai.ready()?;
        let raw_in = input.as_mut().ok_or("input is NULL")?;
        let raw_out = out.as_mut().ok_or("out is NULL")?;
        let mut fin = crate::vk::frame(raw_in, "input")?;
        let mut fout = crate::vk::frame(raw_out, "out")?;
        run.process_vulkan(&mut fin, &mut fout).map_err(|e| e.to_string())?;
        crate::vk::write_back(std::slice::from_ref(&fin), std::slice::from_mut(raw_in));
        crate::vk::write_back(std::slice::from_ref(&fout), std::slice::from_mut(raw_out));
        Ok(())
    }

    #[cfg(not(any(windows, all(unix, not(target_vendor = "apple")))))]
    pub unsafe fn use_vulkan(_: &mut GpufxAiUpscale, _: &GpufxVulkanDevice) -> Result<(), String> {
        Err("this libgpufx is built without Vulkan frame support".into())
    }

    #[cfg(not(any(windows, all(unix, not(target_vendor = "apple")))))]
    pub unsafe fn process_vulkan(_: &mut GpufxAiUpscale, _: *mut GpufxVulkanFrame, _: *mut GpufxVulkanFrame) -> Result<(), String> {
        Err("this libgpufx is built without Vulkan frame support".into())
    }

    #[cfg(windows)]
    pub unsafe fn use_d3d12(ai: &mut GpufxAiUpscale, dev: &GpufxD3D12Device) -> Result<(), String> {
        let ctx = crate::dx::shared(dev.device as usize, || GpuContext::from_d3d12(dev.device))?;
        ai.open_on(ctx, "D3D12")
    }

    #[cfg(windows)]
    pub unsafe fn use_d3d11(ai: &mut GpufxAiUpscale, dev: &GpufxD3D11Device) -> Result<(), String> {
        let ctx = crate::dx::shared(dev.device as usize, || GpuContext::from_d3d11(dev.device, dev.device_context))?;
        ai.open_on(ctx, "D3D11")
    }

    #[cfg(windows)]
    pub unsafe fn process_d3d12(ai: &mut GpufxAiUpscale, input: *mut GpufxD3D12Frame, out: *mut GpufxD3D12Frame) -> Result<(), String> {
        let run = ai.ready()?;
        let raw_in = crate::dx::list(input, 1, "input")?;
        let raw_out = crate::dx::list(out, 1, "out")?;
        let mut ins = crate::dx::d3d12_frames(raw_in, "input")?;
        let mut os = crate::dx::d3d12_frames(raw_out, "out")?;
        run.process_d3d12(&mut ins[0], &mut os[0]).map_err(|e| e.to_string())?;
        for (f, r) in ins.iter().zip(raw_in.iter_mut()).chain(os.iter().zip(raw_out.iter_mut())) {
            r.fence_value = f.fence_value;
        }
        Ok(())
    }

    #[cfg(windows)]
    pub unsafe fn process_d3d11(ai: &mut GpufxAiUpscale, input: *const GpufxD3D11Frame, out: *const GpufxD3D11Frame) -> Result<(), String> {
        let run = ai.ready()?;
        let ins = crate::dx::d3d11_frames(crate::dx::list(input as *mut GpufxD3D11Frame, 1, "input")?, "input")?;
        let os = crate::dx::d3d11_frames(crate::dx::list(out as *mut GpufxD3D11Frame, 1, "out")?, "out")?;
        run.process_d3d11(&ins[0], &os[0]).map_err(|e| e.to_string())
    }

    #[cfg(not(windows))]
    pub unsafe fn use_d3d12(_: &mut GpufxAiUpscale, _: &GpufxD3D12Device) -> Result<(), String> {
        Err(super::imp::NO_DX.into())
    }

    #[cfg(not(windows))]
    pub unsafe fn use_d3d11(_: &mut GpufxAiUpscale, _: &GpufxD3D11Device) -> Result<(), String> {
        Err(super::imp::NO_DX.into())
    }

    #[cfg(not(windows))]
    pub unsafe fn process_d3d12(_: &mut GpufxAiUpscale, _: *mut GpufxD3D12Frame, _: *mut GpufxD3D12Frame) -> Result<(), String> {
        Err(super::imp::NO_DX.into())
    }

    #[cfg(not(windows))]
    pub unsafe fn process_d3d11(_: &mut GpufxAiUpscale, _: *const GpufxD3D11Frame, _: *const GpufxD3D11Frame) -> Result<(), String> {
        Err(super::imp::NO_DX.into())
    }

    #[cfg(target_vendor = "apple")]
    pub unsafe fn use_videotoolbox(ai: &mut GpufxAiUpscale) -> Result<(), String> {
        let ctx = crate::vt::context()?;
        ai.open_on(ctx, "VideoToolbox")
    }

    #[cfg(target_vendor = "apple")]
    pub unsafe fn process_videotoolbox(
        ai: &mut GpufxAiUpscale,
        input: *const GpufxVtFrame,
        out: *const GpufxVtFrame,
    ) -> Result<(), String> {
        let run = ai.ready()?;
        let ins = crate::vt::frames(input, 1, "input")?;
        let os = crate::vt::frames(out, 1, "out")?;
        run.process_videotoolbox(&ins[0], &os[0]).map_err(|e| e.to_string())
    }

    #[cfg(not(target_vendor = "apple"))]
    pub fn use_videotoolbox(_: &mut GpufxAiUpscale) -> Result<(), String> {
        Err("VideoToolbox frames are only supported on macOS".into())
    }

    #[cfg(not(target_vendor = "apple"))]
    pub unsafe fn process_videotoolbox(_: &mut GpufxAiUpscale, _: *const GpufxVtFrame, _: *const GpufxVtFrame) -> Result<(), String> {
        Err("VideoToolbox frames are only supported on macOS".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    fn last_error() -> String {
        unsafe { CStr::from_ptr(crate::gpufx_last_error()) }.to_string_lossy().into_owned()
    }

    /// The arguments are checked at open; the model itself only loads on a device.
    #[test]
    fn upscale_open_checks_its_arguments() {
        let missing = CString::new("no/such/model.zip").unwrap();
        assert!(unsafe { gpufx_ai_upscale_open(missing.as_ptr(), 2, 0, PRECISION_AUTO) }.is_null());
        assert!(last_error().contains("no/such/model.zip"), "{}", last_error());
        let here = CString::new(env!("CARGO_MANIFEST_DIR")).unwrap();
        assert!(unsafe { gpufx_ai_upscale_open(here.as_ptr(), 0, 0, PRECISION_AUTO) }.is_null());
        assert!(last_error().contains("scale 0"), "{}", last_error());
        assert!(unsafe { gpufx_ai_upscale_open(here.as_ptr(), 2, 0, 7) }.is_null());
        assert!(last_error().contains("precision 7"), "{}", last_error());
        assert!(unsafe { gpufx_ai_upscale_open(std::ptr::null(), 2, 0, PRECISION_F32) }.is_null());

        let ai = unsafe { gpufx_ai_upscale_open(here.as_ptr(), 4, 256, PRECISION_F32) };
        assert!(!ai.is_null(), "{}", last_error());
        unsafe {
            assert_eq!(CStr::from_ptr(gpufx_ai_upscale_device(ai)).to_bytes(), b"");
            assert_eq!(gpufx_ai_upscale_process_vulkan(ai, std::ptr::null_mut(), std::ptr::null_mut()), -1);
            assert!(last_error().contains("no device yet"), "{}", last_error());
            gpufx_ai_upscale_free(ai);
            gpufx_ai_upscale_free(std::ptr::null_mut());
        }
    }
}
