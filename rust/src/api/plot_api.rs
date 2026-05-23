// Plot API - 波形数据接口
// 提供设备数据注册、推送、查询功能

use crate::core::plot::PLOT_DATA;
use std::collections::HashMap;

/// 数据点（FRB 兼容）
#[derive(Debug, Clone)]
pub struct PlotPoint {
    pub timestamp_ms: f64,
    pub value: f64,
}

/// 注册 Plot 设备
/// channels: 通道名称列表，如 ["voltage", "current", "power"]
#[flutter_rust_bridge::frb(sync)]
pub fn plot_register_device(device_id: String, channels: Vec<String>) {
    log::info!("[Plot] plot_register_device: device={}, channels={:?}", device_id, channels);
    let ch_refs: Vec<&str> = channels.iter().map(|s| s.as_str()).collect();
    PLOT_DATA.register_device(&device_id, &ch_refs);
}

/// 注销 Plot 设备
#[flutter_rust_bridge::frb(sync)]
pub fn plot_unregister_device(device_id: String) {
    log::info!("[Plot] plot_unregister_device: device={}", device_id);
    PLOT_DATA.unregister_device(&device_id);
}

/// 添加单个数据点
#[flutter_rust_bridge::frb(sync)]
pub fn plot_push_data(device_id: String, channel: String, timestamp_ms: f64, value: f64) {
    log::trace!("[Plot] plot_push_data: device={}, ch={}, ts={:.3}, val={:.6}", device_id, channel, timestamp_ms, value);
    PLOT_DATA.push_data(&device_id, &channel, timestamp_ms, value);
}

/// 批量添加数据点（从协议解析）
#[flutter_rust_bridge::frb(sync)]
pub fn plot_push_batch(device_id: String, channels: Vec<String>, timestamp_ms: f64, values: Vec<f64>) {
    log::trace!("[Plot] plot_push_batch: device={}, ts={:.3}, chs={:?}, vals={:?}", device_id, timestamp_ms, channels, values);
    for (ch, value) in channels.iter().zip(values.iter()) {
        PLOT_DATA.push_data(&device_id, ch, timestamp_ms, *value);
    }
}

/// 从 CSV 协议数据添加
#[flutter_rust_bridge::frb(sync)]
pub fn plot_push_csv(device_id: String, prefix: Option<String>, timestamp_ms: f64, values: Vec<f64>) {
    log::trace!("[Plot] plot_push_csv: device={}, prefix={:?}, ts={:.3}, vals_count={}", device_id, prefix, timestamp_ms, values.len());
    PLOT_DATA.push_batch(&device_id, timestamp_ms, prefix.as_deref(), &values);
}

/// 获取通道数据
#[flutter_rust_bridge::frb(sync)]
pub fn plot_get_channel_data(device_id: String, channel: String) -> Vec<PlotPoint> {
    let result = PLOT_DATA.get_channel_data(&device_id, &channel);
    log::debug!("[Plot] plot_get_channel_data: device={}, ch={}, points={}", device_id, channel, result.len());
    result.into_iter().map(|p| PlotPoint { timestamp_ms: p.timestamp_ms, value: p.value }).collect()
}

/// 获取设备所有通道数据
#[flutter_rust_bridge::frb(sync)]
pub fn plot_get_all_channels(device_id: String) -> HashMap<String, Vec<PlotPoint>> {
    let result = PLOT_DATA.get_all_channels(&device_id);
    log::debug!("[Plot] plot_get_all_channels: device={}, channels={}", device_id, result.len());
    result.into_iter().map(|(k, v)| {
        (k, v.into_iter().map(|p| PlotPoint { timestamp_ms: p.timestamp_ms, value: p.value }).collect())
    }).collect()
}

/// 获取设备的通道列表
#[flutter_rust_bridge::frb(sync)]
pub fn plot_get_channels(device_id: String) -> Vec<String> {
    let result = PLOT_DATA.get_channels(&device_id);
    log::debug!("[Plot] plot_get_channels: device={}, channels={:?}", device_id, result);
    result
}

/// 清空设备数据
#[flutter_rust_bridge::frb(sync)]
pub fn plot_clear_device(device_id: String) {
    log::info!("[Plot] plot_clear_device: device={}", device_id);
    PLOT_DATA.clear_device(&device_id);
}

/// 获取当前样本计数器值
#[flutter_rust_bridge::frb(sync)]
pub fn plot_get_counter() -> u64 {
    let val = PLOT_DATA.get_counter();
    log::trace!("[Plot] plot_get_counter: {}", val);
    val
}

/// 重置样本计数器
#[flutter_rust_bridge::frb(sync)]
pub fn plot_clear_counter() {
    log::info!("[Plot] plot_clear_counter");
    PLOT_DATA.clear_counter();
}

/// 从计数器值添加 CSV 数据（X轴使用计数器而非时间戳）
#[flutter_rust_bridge::frb(sync)]
pub fn plot_push_csv_counter(device_id: String, prefix: Option<String>, values: Vec<f64>) {
    let counter = PLOT_DATA.next_counter() as f64;
    log::trace!("[Plot] plot_push_csv_counter: device={}, prefix={:?}, counter={:.0}, vals_count={}", device_id, prefix, counter, values.len());
    PLOT_DATA.push_batch(&device_id, counter, prefix.as_deref(), &values);
}

/// 获取当前时间戳（毫秒）
#[flutter_rust_bridge::frb(sync)]
pub fn plot_get_timestamp_ms() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let duration = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    duration.as_secs_f64() * 1000.0
}

/// 获取通道视口数据：裁剪 + 降采样
#[flutter_rust_bridge::frb(sync)]
pub fn plot_get_channel_viewport_data(
    device_id: String,
    channel: String,
    x_min: f64,
    x_max: f64,
    max_points: u32,
) -> Vec<PlotPoint> {
    let result = PLOT_DATA.get_channel_viewport_data(&device_id, &channel, x_min, x_max, max_points as usize);
    log::debug!("[Plot] plot_get_channel_viewport_data: device={}, ch={}, x=[{:.1},{:.1}], max_pts={}, result={}", device_id, channel, x_min, x_max, max_points, result.len());
    result.into_iter().map(|p| PlotPoint { timestamp_ms: p.timestamp_ms, value: p.value }).collect()
}
// ============================================================================
// 获取通道最新数据（轻量级 API，用于 currentValue 显示）
// ============================================================================

/// 获取通道的最新数据点
/// 
/// # 参数
/// - `device_id`: 设备 ID
/// - `channel`: 通道名称
/// 
/// # 返回
/// 最新数据点（如果没有数据，返回空列表）
#[flutter_rust_bridge::frb(sync)]
pub fn plot_get_channel_latest_data(
    device_id: String,
    channel: String,
) -> Vec<PlotPoint> {
    let result = PLOT_DATA.get_latest_data(&device_id, &channel);
    
    if let Some(point) = result {
        vec![PlotPoint {
            timestamp_ms: point.timestamp_ms,
            value: point.value,
        }]
    } else {
        vec![]
    }
}


// ============================================================================
