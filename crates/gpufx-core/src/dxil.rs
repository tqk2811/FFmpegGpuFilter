//! D3D12 half of the shader cache: wgpu 30 has no on-disk pipeline cache there and
//! compiles every pipeline from HLSL (FXC, or DXC when `dxcompiler.dll` is found). gpufx
//! instead writes the HLSL itself with naga, compiles it to DXIL with `dxcompiler.dll`,
//! keeps the DXIL and hands it back through `Features::PASSTHROUGH_SHADERS`.
//!
//! Passthrough shaders are not checked by wgpu, so the HLSL must use the registers of
//! the root signature wgpu-hal builds for the pipeline layout: [`hlsl_options`] repeats
//! `create_pipeline_layout` of wgpu-hal 30 (`dx12/device.rs`) for the single bind group
//! of gpufx pipelines. Anything it does not cover returns `None` and the pipeline is
//! compiled the normal way. Re-check it when wgpu is upgraded.

use std::sync::{Mutex, OnceLock};

use naga::back::hlsl;
use windows::core::{Interface, GUID, HRESULT, PCWSTR};
use windows::Win32::Graphics::Direct3D::Dxc;

/// Shader model of the DXIL: every D3D12 adapter wgpu exposes has 6.0.
pub(crate) const SHADER_MODEL: hlsl::ShaderModel = hlsl::ShaderModel::V6_0;

/// `dxcompiler.dll`, loaded once per process.
pub(crate) struct DxcCompiler {
    compiler: Mutex<Dxc::IDxcCompiler3>,
    /// Version and commit of the DLL, part of the cache key.
    pub(crate) version: String,
    // Declared last: the compiler is released before the DLL is unloaded.
    _lib: libloading::Library,
}

// SAFETY: the COM object is only used under the mutex; DXC objects are free-threaded.
unsafe impl Send for DxcCompiler {}
unsafe impl Sync for DxcCompiler {}

impl DxcCompiler {
    /// The compiler, `None` when `dxcompiler.dll` cannot be loaded from the DLL search
    /// path (the same lookup as wgpu's).
    pub(crate) fn get() -> Option<&'static DxcCompiler> {
        static DXC: OnceLock<Option<DxcCompiler>> = OnceLock::new();
        // SAFETY: loading the DLL runs its initialisation, as wgpu-hal does.
        DXC.get_or_init(|| unsafe { Self::load() }).as_ref()
    }

    unsafe fn load() -> Option<DxcCompiler> {
        type CreateInstance = unsafe extern "system" fn(*const GUID, *const GUID, *mut *mut std::ffi::c_void) -> HRESULT;
        let lib = unsafe { libloading::Library::new("dxcompiler.dll") }.ok()?;
        let compiler = unsafe {
            let create = lib.get::<CreateInstance>(b"DxcCreateInstance\0").ok()?;
            let mut raw = std::ptr::null_mut();
            create(&Dxc::CLSID_DxcCompiler, &Dxc::IDxcCompiler3::IID, &mut raw).ok().ok()?;
            if raw.is_null() {
                return None;
            }
            Dxc::IDxcCompiler3::from_raw(raw)
        };
        let (mut major, mut minor) = (1, 0);
        if let Ok(info) = compiler.cast::<Dxc::IDxcVersionInfo>() {
            let _ = unsafe { info.GetVersion(&mut major, &mut minor) };
        }
        let mut version = format!("{major}.{minor}");
        if let Ok(info) = compiler.cast::<Dxc::IDxcVersionInfo2>() {
            let (mut count, mut hash) = (0u32, std::ptr::null_mut::<i8>());
            if unsafe { info.GetCommitInfo(&mut count, &mut hash) }.is_ok() && !hash.is_null() {
                // The string is CoTaskMemAlloc'ed; it is read once per process and left.
                let hash = unsafe { std::ffi::CStr::from_ptr(hash) }.to_string_lossy();
                version.push_str(&format!("+{count}.{hash}"));
            }
        }
        Some(DxcCompiler { compiler: Mutex::new(compiler), version, _lib: lib })
    }

    /// DXIL of the compute entry point `entry` of `hlsl`, `None` on any error. `f16`: shader model 6.2 with
    /// `-enable-16bit-types`, so `half` is a 16-bit float (without it DXC computes `half` in 32 bits).
    pub(crate) fn compile(&self, hlsl: &str, entry: &str, f16: bool) -> Option<Vec<u8>> {
        let wide = |s: &str| s.encode_utf16().chain([0]).collect::<Vec<u16>>();
        let entry = wide(entry);
        let target = wide(&format!("cs_{}", if f16 { SHADER_MODEL_F16 } else { SHADER_MODEL }.to_str()));
        // As wgpu-hal's compile_dxc, without debug info.
        let args = [
            windows::core::w!("-E"),
            PCWSTR(entry.as_ptr()),
            windows::core::w!("-T"),
            PCWSTR(target.as_ptr()),
            windows::core::w!("-HV"),
            windows::core::w!("2018"),
            windows::core::w!("-no-warnings"),
            Dxc::DXC_ARG_ENABLE_STRICTNESS,
            windows::core::w!("-enable-16bit-types"),
        ];
        let args = if f16 { &args[..] } else { &args[..args.len() - 1] };
        let buffer = Dxc::DxcBuffer { Ptr: hlsl.as_ptr().cast(), Size: hlsl.len(), Encoding: Dxc::DXC_CP_UTF8.0 };
        let compiler = self.compiler.lock().ok()?;
        // SAFETY: every pointer outlives the call.
        unsafe {
            let result: Dxc::IDxcResult = compiler.Compile(&buffer, Some(args), None).ok()?;
            if result.GetStatus().ok()?.is_err() {
                return None;
            }
            let mut blob: Option<Dxc::IDxcBlob> = None;
            result.GetOutput(Dxc::DXC_OUT_OBJECT, &mut None, &mut blob).ok()?;
            let blob = blob?;
            let data = std::slice::from_raw_parts(blob.GetBufferPointer().cast::<u8>(), blob.GetBufferSize());
            (!data.is_empty()).then(|| data.to_vec())
        }
    }
}

/// The naga HLSL options matching the root signature wgpu-hal 30 makes for a pipeline
/// layout of the one bind group `entries` and no immediates. `None` for bindings it
/// does not repeat (dynamic offsets, arrays, external textures).
pub(crate) fn hlsl_options(entries: &[wgpu::BindGroupLayoutEntry]) -> Option<hlsl::Options> {
    let mut entries = entries.to_vec();
    // wgpu-core sorts the entries of a layout by binding.
    entries.sort_by_key(|e| e.binding);
    let mut options = hlsl::Options {
        shader_model: SHADER_MODEL,
        fake_missing_bindings: false,
        sampler_heap_target: hlsl::SamplerHeapBindTargets {
            standard_samplers: hlsl::BindTarget { space: 0, register: 0, ..Default::default() },
            comparison_samplers: hlsl::BindTarget { space: 0, register: 2048, ..Default::default() },
        },
        ..Default::default()
    };
    let (mut cbv, mut srv, mut uav) = (hlsl::BindTarget::default(), hlsl::BindTarget::default(), hlsl::BindTarget::default());
    for e in &entries {
        if e.count.is_some() {
            return None;
        }
        let target = match e.ty {
            wgpu::BindingType::Sampler(_) => continue,
            wgpu::BindingType::Buffer { has_dynamic_offset: true, .. } => return None,
            wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, .. } => &mut cbv,
            wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Storage { read_only: true }, .. }
            | wgpu::BindingType::Texture { .. } => &mut srv,
            wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Storage { read_only: false }, .. }
            | wgpu::BindingType::StorageTexture { .. } => &mut uav,
            _ => return None,
        };
        options.binding_map.insert(naga::ResourceBinding { group: 0, binding: e.binding }, *target);
        target.register += 1;
    }
    let mut samplers = 0;
    for e in entries.iter().filter(|e| matches!(e.ty, wgpu::BindingType::Sampler(_))) {
        options.binding_map.insert(
            naga::ResourceBinding { group: 0, binding: e.binding },
            // naga does not use the space of samplers: the register indexes the bind
            // group's sampler index buffer.
            hlsl::BindTarget { space: 255, register: samplers, ..Default::default() },
        );
        samplers += 1;
    }
    if samplers != 0 {
        options.sampler_buffer_binding_map.insert(hlsl::SamplerIndexBufferKey { group: 0 }, srv);
    }
    // wgpu-core always asks for FIRST_VERTEX_INSTANCE | NUM_WORK_GROUPS: the special
    // constants take the next CBV register.
    options.special_constants_binding = Some(cbv);
    Some(options)
}

/// Shader model 6.2 with native 16-bit types: what a module using `f16` needs (wgpu's `SHADER_F16` on D3D12).
const SHADER_MODEL_F16: hlsl::ShaderModel = hlsl::ShaderModel::V6_2;

/// Whether `module`, valid with every capability, uses 16-bit floats: it is not valid without them (an f16
/// value may have no entry in the type arena, e.g. a `let`).
fn uses_f16(module: &naga::Module) -> bool {
    let caps = naga::valid::Capabilities::all() - naga::valid::Capabilities::SHADER_FLOAT16;
    naga::valid::Validator::new(naga::valid::ValidationFlags::all(), caps).validate(module).is_err()
}

/// HLSL of the compute entry point `entry` of `module` for a layout of `entries`, the
/// entry point name to compile, and whether it needs 16-bit types (see [`DxcCompiler::compile`]).
pub(crate) fn hlsl(module: &naga::Module, entries: &[wgpu::BindGroupLayoutEntry], entry: &str) -> Option<(String, String, bool)> {
    if !module.overrides.is_empty() {
        return None;
    }
    let mut options = hlsl_options(entries)?;
    let info = naga::valid::Validator::new(naga::valid::ValidationFlags::all(), naga::valid::Capabilities::all()).validate(module).ok()?;
    let f16 = uses_f16(module);
    if f16 {
        options.shader_model = SHADER_MODEL_F16;
    }
    let pipeline = hlsl::PipelineOptions { entry_point: Some((naga::ShaderStage::Compute, entry.to_string())) };
    let mut source = String::new();
    let mut reflection = hlsl::Writer::new(&mut source, &options, &pipeline).write(module, &info, None).ok()?;
    let name = reflection.entry_point_names.pop()?.ok()?;
    Some((source, name, f16))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn module(src: &str) -> naga::Module {
        naga::front::wgsl::parse_str(src).unwrap()
    }

    const ENTRIES: [wgpu::BindGroupLayoutEntry; 1] = [wgpu::BindGroupLayoutEntry {
        binding: 0,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Storage { read_only: false },
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }];

    /// A module using f16 compiles for shader model 6.2 with 16-bit types: without `-enable-16bit-types` DXC
    /// takes `half` as a 32-bit float, and the f16 convolutions of gpufx-nn ran in f32 through the DXIL cache.
    #[test]
    fn f16_modules_compile_with_16bit_types() {
        let f16 = "enable f16;\n@group(0) @binding(0) var<storage, read_write> d: array<f32>;\n\
                   @compute @workgroup_size(1) fn main() { let h = f16(d[0]) * 3.0h; d[0] = f32(h); }";
        let f32 = "@group(0) @binding(0) var<storage, read_write> d: array<f32>;\n\
                   @compute @workgroup_size(1) fn main() { d[0] = d[0] * 3.0; }";
        let (src, _, uses) = hlsl(&module(f16), &ENTRIES, "main").unwrap();
        assert!(uses && src.contains("half"), "{src}");
        assert!(!hlsl(&module(f32), &ENTRIES, "main").unwrap().2);
        let Some(dxc) = DxcCompiler::get() else { return };
        let (src, name, _) = hlsl(&module(f16), &ENTRIES, "main").unwrap();
        let with = dxc.compile(&src, &name, true).expect("f16 compiles with 16-bit types");
        let without = dxc.compile(&src, &name, false).expect("min precision half");
        assert_ne!(with, without, "16-bit types change the DXIL");
    }
}
