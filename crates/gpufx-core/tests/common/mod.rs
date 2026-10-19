//! Helpers shared by the integration tests.

use gpufx_core::Backend;

/// The backend the GPU tests open: `GPUFX_TEST_BACKEND` (`vulkan`, `dx12`, ...) when set, so
/// the suite can be run once per backend; `Auto` otherwise.
pub fn backend() -> Backend {
    match std::env::var("GPUFX_TEST_BACKEND") {
        Ok(s) => s.parse().unwrap_or_else(|e| panic!("GPUFX_TEST_BACKEND: {e}")),
        Err(_) => Backend::Auto,
    }
}

/// Whether `ctx` runs on WARP, Windows' software D3D12 adapter (hosted CI runners have no
/// GPU). It runs shaders on the CPU, far slower than lavapipe: the heaviest checks skip on it.
#[allow(dead_code)]
pub fn is_warp(ctx: &gpufx_core::GpuContext) -> bool {
    ctx.description().starts_with("Microsoft Basic Render Driver")
}

/// The chain of `effects` (`e0|e1|...`, a graph of one statement without labels), each
/// opened as given: label and effect.
#[allow(dead_code)]
pub fn chain(effects: Vec<(String, gpufx_core::Effect)>) -> Result<gpufx_core::EffectGraph, gpufx_core::Error> {
    let text = (0..effects.len()).map(|k| format!("e{k}")).collect::<Vec<_>>().join("|");
    let mut effects = effects.into_iter();
    gpufx_core::EffectGraph::parse(&text, |_| Ok(effects.next().expect("one effect per item")))
}
