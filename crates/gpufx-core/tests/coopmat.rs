//! Tensor cores through WGSL cooperative matrices (`enable wgpu_cooperative_matrix;`): a
//! 64x64x64 matmul, f16 inputs and f32 accumulation, against the CPU. Skipped without a
//! device or when it lacks EXPERIMENTAL_COOPERATIVE_MATRIX (DX12, Metal, older GPUs).

mod common;

use gpufx_core::GpuContext;
use wgpu::util::DeviceExt;

const N: u32 = 64;

/// One subgroup (32 lanes) per 16x16 tile of C. Globals are not named A/B/C (naga takes them
/// for the matrix roles) and the store offset is a `let` (naga's SPIR-V writer needs it).
const SHADER: &str = r#"
enable f16;
enable wgpu_cooperative_matrix;
@group(0) @binding(0) var<storage, read> ma: array<f16>;
@group(0) @binding(1) var<storage, read> mb: array<f16>;
@group(0) @binding(2) var<storage, read_write> mc: array<f32>;
const n = 64u;
@compute @workgroup_size(32)
fn main(@builtin(workgroup_id) wid: vec3<u32>) {
  let row0 = wid.y * 16u;
  let col0 = wid.x * 16u;
  var acc = coop_mat16x16<f32, C>();
  for (var k0 = 0u; k0 < n; k0 += 16u) {
    let a = coopLoadT<coop_mat16x16<f16, A>>(&ma[row0 * n + k0], n);
    let b = coopLoadT<coop_mat16x16<f16, B>>(&mb[k0 * n + col0], n);
    acc = coopMultiplyAdd(a, b, acc);
  }
  let r = acc;
  let o = row0 * n + col0;
  coopStoreT(r, &mc[o], n);
}
"#;

/// The f16 bits of `x`, a value f16 holds exactly (small multiples of 1/8 here).
fn f16_bits(x: f32) -> u16 {
    if x == 0.0 {
        return 0;
    }
    let b = x.to_bits();
    let sign = ((b >> 16) & 0x8000) as u16;
    let exp = ((b >> 23) & 0xff) as i32 - 127 + 15;
    sign | ((exp as u16) << 10) | ((b >> 13) & 0x3ff) as u16
}

#[test]
fn coop_matmul_matches_cpu() {
    let ctx = match GpuContext::new(common::backend()) {
        Ok(ctx) => ctx,
        Err(e) => return eprintln!("skipping: {e}"),
    };
    let device = ctx.device();
    if !device.features().contains(wgpu::Features::EXPERIMENTAL_COOPERATIVE_MATRIX) {
        return eprintln!("skipping: {} has no cooperative matrix", ctx.description());
    }
    let n = N as usize;
    let a: Vec<f32> = (0..n * n).map(|i| ((i * 7 + 3) % 17) as f32 / 8.0 - 1.0).collect();
    let b: Vec<f32> = (0..n * n).map(|i| ((i * 5 + 1) % 13) as f32 / 8.0 - 0.75).collect();
    let mut want = vec![0f32; n * n];
    for r in 0..n {
        for c in 0..n {
            want[r * n + c] = (0..n).map(|k| a[r * n + k] * b[k * n + c]).sum();
        }
    }
    let to_f16 = |v: &[f32]| v.iter().flat_map(|&x| f16_bits(x).to_le_bytes()).collect::<Vec<u8>>();
    let storage = |data: &[u8]| {
        device.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: None, contents: data, usage: wgpu::BufferUsages::STORAGE })
    };
    let (buf_a, buf_b) = (storage(&to_f16(&a)), storage(&to_f16(&b)));
    let size = (n * n * 4) as u64;
    let buf_c = device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size,
        usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
        mapped_at_creation: false,
    });
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size,
        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let module = device
        .create_shader_module(wgpu::ShaderModuleDescriptor { label: Some("coopmat"), source: wgpu::ShaderSource::Wgsl(SHADER.into()) });
    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some("coopmat"),
        layout: None,
        module: &module,
        entry_point: Some("main"),
        compilation_options: Default::default(),
        cache: None,
    });
    let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: None,
        layout: &pipeline.get_bind_group_layout(0),
        entries: &[
            wgpu::BindGroupEntry { binding: 0, resource: buf_a.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 1, resource: buf_b.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 2, resource: buf_c.as_entire_binding() },
        ],
    });
    let mut enc = device.create_command_encoder(&Default::default());
    {
        let mut pass = enc.begin_compute_pass(&Default::default());
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &bind, &[]);
        pass.dispatch_workgroups(N / 16, N / 16, 1);
    }
    enc.copy_buffer_to_buffer(&buf_c, 0, &readback, 0, size);
    ctx.queue().submit([enc.finish()]);
    readback.slice(..).map_async(wgpu::MapMode::Read, |r| r.expect("map"));
    device.poll(wgpu::PollType::wait_indefinitely()).expect("poll");
    let got: Vec<f32> =
        readback.slice(..).get_mapped_range().expect("mapped").as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect();
    // Products of multiples of 1/8 summed in f32: exact.
    for (i, (g, w)) in got.iter().zip(&want).enumerate() {
        assert!((g - w).abs() < 1e-3, "C[{}][{}] = {g}, want {w}", i / n, i % n);
    }
}
