//! Frame interpolation with a gpufx-nn `frame_interp` package on the frames of the GPU frame APIs (since
//! version 13). See `gpufx_ai_interp_*` in `include/gpufx.h`.

use std::ffi::{c_char, c_int, CString};
use std::sync::Arc;

use gpufx_core::nn::InterpFrames;
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
    const NO_DX: &str = "D3D12 and D3D11 frames are only supported on Windows";

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
