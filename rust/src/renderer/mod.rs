// renderer/mod.rs - WebGPU (wgpu) 渲染模块

pub mod gpu_renderer;

// 重新导出主要类型
pub use gpu_renderer::GpuRenderer;
