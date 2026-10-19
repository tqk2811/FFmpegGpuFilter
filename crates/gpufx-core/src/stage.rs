//! What the paths of the GPU frame APIs (Vulkan, D3D12/D3D11, VideoToolbox) run on the frames they import.
//!
//! Each path wraps the caller's frames as [`GpuFrame`]s, records a stage into one command encoder and submits it
//! with the synchronisation the API needs. The stage is an [`crate::EffectGraph`], or another GPU job on
//! the same frames (frame interpolation, [`crate::nn::InterpFrames`]): both reuse the same imports.

use std::sync::Arc;

use crate::frame::GpuFrame;
use crate::runtime::{FrameInfo, GpuContext};
use crate::Error;

/// Wrappers and copies of the frames a stage was given, kept from frame to frame.
#[derive(Default)]
pub(crate) struct Interop {
    /// Copies and the last submission of D3D12/D3D11 frames (see `d3d12.rs`).
    #[cfg(windows)]
    pub dx: crate::d3d12::GraphState,
    /// Wrappers of the images of recent Vulkan frames (see `vulkan.rs`).
    #[cfg(any(windows, all(unix, not(target_vendor = "apple"))))]
    pub vk: crate::vulkan::ImportCache,
    /// Wrappers of the IOSurface planes of recent VideoToolbox frames (see `videotoolbox.rs`).
    #[cfg(target_vendor = "apple")]
    pub vt: crate::videotoolbox::ImportCache,
}

/// GPU work recorded on imported frames.
#[cfg_attr(not(any(windows, unix)), allow(dead_code))]
pub(crate) trait GpuStage {
    /// The device the stage runs on.
    fn context(&self) -> &Arc<GpuContext>;
    fn interop(&mut self) -> &mut Interop;
    /// Records the stage: reads `inputs`, writes every plane of `outs`. Nothing is submitted.
    fn encode_gpu(
        &mut self,
        inputs: &[GpuFrame],
        outs: &[GpuFrame],
        info: Option<&FrameInfo>,
        enc: &mut wgpu::CommandEncoder,
    ) -> Result<(), Error>;
    /// Called right after the encoder was submitted (or dropped).
    fn release_frame(&mut self) {}
    /// The inputs may be read in place when they allow it (see [`crate::EffectGraph::allow_direct_gpu`]).
    fn allow_direct_gpu(&mut self) {}
    /// Adds `d` to a CPU span of the profile, when profiling.
    fn profile_cpu(&mut self, _span: crate::profile::Cpu, _d: std::time::Duration) {}
}
