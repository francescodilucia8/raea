//! The process's one shared GPU device (One renderer: one device, one frame graph): Bevy's renderer (raea-render's engine),
//! the kernels of the direct render (raea-render's gpuview) and the stage's present (present.rs) all run on it, so a
//! texture one of them draws is one the others can read. Made once, on first use, as Bevy's renderer asks for its own
//! device (its Functionality priority: every feature the adapter has, less mappable primary buffers on a
//! discrete GPU). RAEA_SHARED_DEVICE=0: callers make their
//! own devices instead (`enabled`).

use std::sync::OnceLock;

/// what a page's Vello scene uses of each bump buffer, counted on the CPU (RAEA_VELLO_BUMP_USE)
pub mod bump;
/// whether the GPU still runs our work, and a black frame checked before it's kept
pub mod check;
/// windows a texture on the shared device is presented on (live play)
pub mod present;
mod telemetry;

pub use telemetry::*;

/// What the shared device is: the instance and adapter it came from, the device and its queue.
pub type Handles = (wgpu::Instance, wgpu::Adapter, wgpu::Device, wgpu::Queue);

/// Whether callers share the device (on unless RAEA_SHARED_DEVICE=0).
pub fn enabled() -> bool {
    std::env::var("RAEA_SHARED_DEVICE").as_deref() != Ok("0")
}

/// The shared device, made on first call; every later call gets the same one (or the same error).
pub fn device() -> Result<Handles, String> {
    static SHARED: OnceLock<Result<Handles, String>> = OnceLock::new();
    SHARED.get_or_init(make).clone()
}

/// Intel's PCI vendor id, as DXGI and Vulkan report it.
const INTEL: u32 = 0x8086;

/// Whether the shared device runs on DX12 alone: on Windows, when WGPU_BACKEND isn't set and the GPU DX12 picks
/// (`dx12`: its vendor and kind) is Intel's own hardware (WARP, Windows' software DirectX, is a Cpu). raea 0.1.7 crashed
/// on an Intel integrated GPU under Vulkan on a Windows 10 PC, and ran with WGPU_BACKEND=dx12; asked for every backend,
/// wgpu takes Vulkan's adapter for the same GPU. NVIDIA and AMD, a PC with no GPU, a Mac or Linux, and a WGPU_BACKEND
/// someone set (Windows' check sets vulkan, for lavapipe) keep wgpu's own pick.
pub fn dx12_first(windows: bool, env: Option<wgpu::Backends>, dx12: Option<(u32, wgpu::DeviceType)>) -> bool {
    windows && env.is_none() && matches!(dx12, Some((INTEL, kind)) if kind != wgpu::DeviceType::Cpu)
}

/// The backends every wgpu instance of raea's asks for (the shared device's, Bevy's own when it isn't there, systems/k's
/// kernels): WGPU_BACKEND when it's set; else, on Windows, DX12 alone when DX12's pick is an Intel GPU (dx12_first);
/// else every backend, wgpu's own default. Found once a process: on Windows it asks DX12 for its adapter first.
pub fn backends() -> wgpu::Backends {
    static B: std::sync::OnceLock<wgpu::Backends> = std::sync::OnceLock::new();
    *B.get_or_init(|| {
        let env = wgpu::Backends::from_env();
        if let Some(b) = env {
            return b;
        }
        let dx12 = cfg!(windows).then(|| {
            let i = wgpu::Instance::new(wgpu::InstanceDescriptor { backends: wgpu::Backends::DX12, ..wgpu::InstanceDescriptor::new_without_display_handle() });
            pollster::block_on(i.request_adapter(&wgpu::RequestAdapterOptions { power_preference: wgpu::PowerPreference::HighPerformance, ..Default::default() }))
                .ok()
                .map(|a| (a.get_info().vendor, a.get_info().device_type))
        });
        if dx12_first(cfg!(windows), env, dx12.flatten()) { wgpu::Backends::DX12 } else { wgpu::Backends::all() }
    })
}

fn make() -> Result<Handles, String> {
    // wgpu's indirect-draw validation off in release (it stays in debug builds; RAEA_WGPU_INDIRECT_VALIDATION=1 puts it
    // back): it checks each indirect draw's arguments in compute passes before drawing, and the indirect draws are
    // Bevy's own, written by its mesh preprocessing on this device. On arena3d it was ~7 extra passes and their blits a
    // frame, ~0.07 ms of GPU (lightspeed F2); pixels are the same.
    // wgpu's own variables are read (WGPU_BACKEND, WGPU_DX12_COMPILER, WGPU_VALIDATION, ...; nothing changes when unset,
    // but for an Intel GPU on Windows, which goes on DX12: dx12_first):
    // Windows' check renders on Mesa's lavapipe with WGPU_BACKEND=vulkan, because WARP crashes compiling one of Bevy's
    // compute shaders on GitHub's GPU-less runner (d3d10warp ComputeShaderTransformer, PT20)
    let mut desc = wgpu::InstanceDescriptor::new_without_display_handle_from_env();
    desc.backends = backends();
    if !cfg!(debug_assertions) && std::env::var("RAEA_WGPU_INDIRECT_VALIDATION").as_deref() != Ok("1") {
        desc.flags.remove(wgpu::InstanceFlags::VALIDATION_INDIRECT_CALL);
    }
    let instance = wgpu::Instance::new(desc);
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions { power_preference: wgpu::PowerPreference::HighPerformance, ..Default::default() }))
        .map_err(|e| format!("no GPU adapter: {e}"))?;
    if std::env::var_os("RAEA_WGPU_ADAPTER_LOG").is_some() {
        let info = adapter.get_info();
        eprintln!("raea GPU adapter: {} ({:?}, {:?})", info.name, info.backend, info.device_type);
    }
    let mut features = adapter.features();
    if adapter.get_info().device_type == wgpu::DeviceType::DiscreteGpu {
        features.remove(wgpu::Features::MAPPABLE_PRIMARY_BUFFERS);
    }
    let limits = adapter.limits();
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("raea shared"),
        required_features: features,
        required_limits: limits,
        // as Bevy's own request does (bevy_render renderer::initialize_renderer)
        experimental_features: unsafe { wgpu::ExperimentalFeatures::enabled() },
        // RAEA_WGPU_TRACE=DIR: every call on the device written to DIR/trace.ron, for tools/readbacks.sh to count
        // the copies the CPU reads back (docs/blitz-bevy.feature B1d)
        trace: std::env::var_os("RAEA_WGPU_TRACE").map_or(wgpu::Trace::Off, |d| {
            let _ = std::fs::create_dir_all(&d);
            wgpu::Trace::Directory(d.into())
        }),
        ..Default::default()
    }))
    .map_err(|e| format!("GPU device: {e}"))?;
    // GPU errors nothing caught, and the device lost, in the run's trace, put to the subsystem whose labels they name
    // (quads, Bevy rendering on this device, raea-render, video; the driver when none): telemetry
    telemetry::watch(&device, "quads");
    Ok((instance, adapter, device, queue))
}

#[cfg(test)]
mod tests {
    use super::*;
    use wgpu::{Backends, DeviceType};

    // an Intel GPU on Windows goes on DX12 unless WGPU_BACKEND says otherwise; every other GPU and system keeps wgpu's pick
    #[test]
    fn intel_on_windows_runs_on_dx12() {
        assert!(dx12_first(true, None, Some((INTEL, DeviceType::IntegratedGpu))), "Intel's integrated GPU");
        assert!(dx12_first(true, None, Some((INTEL, DeviceType::DiscreteGpu))), "Intel Arc");
        assert!(!dx12_first(true, Some(Backends::VULKAN), Some((INTEL, DeviceType::IntegratedGpu))), "WGPU_BACKEND=vulkan is kept");
        assert!(!dx12_first(true, Some(Backends::DX12), Some((INTEL, DeviceType::IntegratedGpu))), "WGPU_BACKEND set: wgpu's own read of it");
        assert!(!dx12_first(true, None, Some((0x10de, DeviceType::DiscreteGpu))), "NVIDIA keeps wgpu's pick");
        assert!(!dx12_first(true, None, Some((0x1002, DeviceType::IntegratedGpu))), "AMD keeps wgpu's pick");
        assert!(!dx12_first(true, None, Some((0x1414, DeviceType::Cpu))), "WARP alone: wgpu's pick (lavapipe, when it's there)");
        assert!(!dx12_first(true, None, None), "no DX12 adapter");
        assert!(!dx12_first(false, None, Some((INTEL, DeviceType::IntegratedGpu))), "an Intel Mac or Linux");
    }
}
