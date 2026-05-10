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
    let ch_refs: Vec<&str> = channels.iter().map(|s| s.as_str()).collect();
    PLOT_DATA.register_device(&device_id, &ch_refs);
}

/// 注销 Plot 设备
#[flutter_rust_bridge::frb(sync)]
pub fn plot_unregister_device(device_id: String) {
    PLOT_DATA.unregister_device(&device_id);
}

/// 添加单个数据点
#[flutter_rust_bridge::frb(sync)]
pub fn plot_push_data(device_id: String, channel: String, timestamp_ms: f64, value: f64) {
    PLOT_DATA.push_data(&device_id, &channel, timestamp_ms, value);
}

/// 批量添加数据点（从协议解析）
/// channels: 通道名称列表
/// values: 对应通道的值
#[flutter_rust_bridge::frb(sync)]
pub fn plot_push_batch(device_id: String, channels: Vec<String>, timestamp_ms: f64, values: Vec<f64>) {
    for (ch, value) in channels.iter().zip(values.iter()) {
        PLOT_DATA.push_data(&device_id, ch, timestamp_ms, *value);
    }
}

/// 从 CSV 协议数据添加
#[flutter_rust_bridge::frb(sync)]
pub fn plot_push_csv(device_id: String, prefix: Option<String>, timestamp_ms: f64, values: Vec<f64>) {
    PLOT_DATA.push_batch(&device_id, timestamp_ms, prefix.as_deref(), &values);
}

/// 获取通道数据
#[flutter_rust_bridge::frb(sync)]
pub fn plot_get_channel_data(device_id: String, channel: String) -> Vec<PlotPoint> {
    PLOT_DATA
        .get_channel_data(&device_id, &channel)
        .into_iter()
        .map(|p| PlotPoint {
            timestamp_ms: p.timestamp_ms,
            value: p.value,
        })
        .collect()
}

/// 获取设备所有通道数据
#[flutter_rust_bridge::frb(sync)]
pub fn plot_get_all_channels(device_id: String) -> HashMap<String, Vec<PlotPoint>> {
    PLOT_DATA
        .get_all_channels(&device_id)
        .into_iter()
        .map(|(k, v)| {
            (
                k,
                v.into_iter()
                    .map(|p| PlotPoint {
                        timestamp_ms: p.timestamp_ms,
                        value: p.value,
                    })
                    .collect(),
            )
        })
        .collect()
}

/// 获取设备的通道列表
#[flutter_rust_bridge::frb(sync)]
pub fn plot_get_channels(device_id: String) -> Vec<String> {
    PLOT_DATA.get_channels(&device_id)
}

/// 清空设备数据
#[flutter_rust_bridge::frb(sync)]
pub fn plot_clear_device(device_id: String) {
    PLOT_DATA.clear_device(&device_id);
}

/// 获取当前样本计数器值
#[flutter_rust_bridge::frb(sync)]
pub fn plot_get_counter() -> u64 {
    PLOT_DATA.get_counter()
}

/// 重置样本计数器
#[flutter_rust_bridge::frb(sync)]
pub fn plot_clear_counter() {
    PLOT_DATA.clear_counter();
}

/// 从计数器值添加 CSV 数据（X轴使用计数器而非时间戳）
#[flutter_rust_bridge::frb(sync)]
pub fn plot_push_csv_counter(device_id: String, prefix: Option<String>, values: Vec<f64>) {
    let counter = PLOT_DATA.next_counter() as f64;
    PLOT_DATA.push_batch(&device_id, counter, prefix.as_deref(), &values);
}

/// 获取当前时间戳（毫秒）
#[flutter_rust_bridge::frb(sync)]
pub fn plot_get_timestamp_ms() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    duration.as_secs_f64() * 1000.0
}
