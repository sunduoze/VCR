// gpu_api.rs - GPU 渲染器 FFI 函数

use crate::renderer::gpu_renderer::GpuRenderer;
use once_cell::sync::Lazy;
use std::sync::Mutex;

/// 全局 GPU 渲染器实例（线程安全）
static GPU_RENDERER: Lazy<Mutex<Option<GpuRenderer>>> = Lazy::new(|| Mutex::new(None));

/// 初始化 GPU 渲染器
/// 返回 0 表示成功，返回 -1 表示失败
#[flutter_rust_bridge::frb(sync)]
pub fn gpu_init() -> i32 {
    // 初始化日志（如果尚未初始化）
    let _ = env_logger::try_init();

    log::info!("[GPU] ========= GPU Init Starting =========");

    match GpuRenderer::new() {
        Ok(renderer) => {
            let mut global_renderer = GPU_RENDERER.lock().unwrap();
            *global_renderer = Some(renderer);
            log::info!("[GPU] GPU renderer initialized successfully");

            0
        }
        Err(e) => {
            let error_msg = format!("[GPU] Failed to initialize GPU renderer: {}", e);

            log::error!("{}", error_msg);
            -1
        }
    }
}

/// 渲染波形到纹理（GPU 加速），并返回 RGBA 数据
/// 参数：
/// - width: 纹理宽度
/// - height: 纹理高度
/// - points: 波形数据点数组（x, y 交替，归一化到 [0, 1]）
/// - point_count: 点数
/// - r, g, b, a: RGBA 颜色（0-255）
/// 返回：RGBA 字节数组（长度 = width * height * 4），失败返回空数组
#[flutter_rust_bridge::frb(sync)]
pub fn gpu_render_waveform(
    width: u32,
    height: u32,
    points: Vec<f32>,
    point_count: u32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) -> Vec<u8> {
    let mut global_renderer = GPU_RENDERER.lock().unwrap();

    if let Some(renderer) = global_renderer.as_mut() {
        // 创建纹理
        match renderer.create_texture(width, height) {
            Ok(texture) => {
                // 渲染波形
                let color = [
                    r as f32 / 255.0,
                    g as f32 / 255.0,
                    b as f32 / 255.0,
                    a as f32 / 255.0,
                ];
                match renderer.render_waveform_to_texture(
                    &texture,
                    width,
                    height,
                    &points,
                    point_count,
                    color,
                ) {
                    Ok(()) => {
                        // 读取纹理数据到 CPU 内存
                        match renderer.read_texture_to_cpu(&texture, width, height) {
                            Ok(data) => {
                                log::info!(
                                    "[GPU] Waveform rendered successfully: {} bytes",
                                    data.len()
                                );
                                data
                            }
                            Err(e) => {
                                log::error!("[GPU] Failed to read texture: {}", e);
                                Vec::new()
                            }
                        }
                    }
                    Err(e) => {
                        log::error!("[GPU] Failed to render waveform: {}", e);
                        Vec::new()
                    }
                }
            }
            Err(e) => {
                log::error!("[GPU] Failed to create texture: {}", e);
                Vec::new()
            }
        }
    } else {
        log::error!("[GPU] GPU renderer not initialized");
        Vec::new()
    }
}

/// 释放 GPU 渲染器
#[flutter_rust_bridge::frb(sync)]
pub fn gpu_cleanup() {
    let mut global_renderer = GPU_RENDERER.lock().unwrap();
    *global_renderer = None;
    log::info!("[GPU] GPU renderer cleaned up");
}
