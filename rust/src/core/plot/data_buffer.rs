// Plot Data Buffer - 环形缓冲区存储通道数据
// 用于 Plot Screen 实时波形显示

use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock, MutexGuard};

/// 安全获取 Mutex 锁，遇到 PoisonError 时恢复而非 panic
fn lock_mutex<T>(mutex: &Mutex<T>) -> MutexGuard<T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            log::warn!("[PlotBuffer] Mutex was poisoned, recovering...");
            poisoned.into_inner()
        }
    }
}

/// 单个数据点
#[derive(Debug, Clone, Copy)]
pub struct DataPoint {
    /// 时间戳（毫秒）
    pub timestamp_ms: f64,
    /// 通道值
    pub value: f64,
}

/// 通道数据缓冲区（环形）
#[derive(Debug)]
pub struct ChannelBuffer {
    /// 数据区
    data: Vec<DataPoint>,
    /// 写入位置
    write_pos: usize,
    /// 容量
    capacity: usize,
    /// 当前数据量
    len: usize,
}

impl ChannelBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            data: vec![DataPoint { timestamp_ms: 0.0, value: 0.0 }; capacity],
            write_pos: 0,
            capacity,
            len: 0,
        }
    }

    /// 添加数据点
    pub fn push(&mut self, timestamp_ms: f64, value: f64) {
        self.data[self.write_pos] = DataPoint { timestamp_ms, value };
        self.write_pos = (self.write_pos + 1) % self.capacity;
        if self.len < self.capacity {
            self.len += 1;
        }
    }

    /// 获取所有数据点（按时间排序）
    pub fn get_all(&self) -> Vec<DataPoint> {
        if self.len < self.capacity {
            // 未满，直接返回
            self.data[..self.len].to_vec()
        } else {
            // 已满，需要重新排序
            let mut result = Vec::with_capacity(self.capacity);
            for i in 0..self.capacity {
                result.push(self.data[(self.write_pos + i) % self.capacity]);
            }
            result
        }
    }

    /// 清空
    pub fn clear(&mut self) {
        self.write_pos = 0;
        self.len = 0;
    }

    /// 当前数据量
    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }
}

/// Plot 数据管理器（全局单例）
pub struct PlotDataManager {
    /// 设备数据：device_id -> (channel_name -> buffer)
    devices: RwLock<HashMap<String, HashMap<String, Arc<Mutex<ChannelBuffer>>>>>,
    /// 默认容量
    default_capacity: usize,
    /// 订阅回调：device_id -> callbacks
    callbacks: RwLock<HashMap<String, Vec<Box<dyn Fn(&str, f64, &[f64]) + Send + Sync>>>>,
}

impl PlotDataManager {
    pub fn new() -> Self {
        Self {
            devices: RwLock::new(HashMap::new()),
            default_capacity: 10000,
            callbacks: RwLock::new(HashMap::new()),
        }
    }

    /// 注册设备
    pub fn register_device(&self, device_id: &str, channels: &[&str]) {
        let mut devices = self.devices.write().unwrap_or_else(|e| e.into_inner());
        let mut device_channels = HashMap::new();
        for ch in channels {
            device_channels.insert(
                ch.to_string(),
                Arc::new(Mutex::new(ChannelBuffer::new(self.default_capacity))),
            );
        }
        devices.insert(device_id.to_string(), device_channels);
    }

    /// 注销设备
    pub fn unregister_device(&self, device_id: &str) {
        let mut devices = self.devices.write().unwrap_or_else(|e| e.into_inner());
        devices.remove(device_id);
    }

    /// 添加数据点（自动创建通道，如果不存在）
    pub fn push_data(&self, device_id: &str, channel: &str, timestamp_ms: f64, value: f64) {
        // Auto-create channel buffer if device/channel doesn't exist yet
        let needs_create = {
            let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
            match devices.get(device_id) {
                Some(dc) => !dc.contains_key(channel),
                None => true,
            }
        };
        if needs_create {
            let mut devices = self.devices.write().unwrap_or_else(|e| e.into_inner());
            devices
                .entry(device_id.to_string())
                .or_insert_with(HashMap::new);
            if let Some(dc) = devices.get_mut(device_id) {
                dc.insert(
                    channel.to_string(),
                    Arc::new(Mutex::new(ChannelBuffer::new(self.default_capacity))),
                );
            }
        }

        let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
        if let Some(device_channels) = devices.get(device_id) {
            if let Some(buffer) = device_channels.get(channel) {
                lock_mutex(&buffer).push(timestamp_ms, value);
            }
        }
    }

    /// 批量添加数据（从协议解析结果，自动创建通道）
    pub fn push_batch(&self, device_id: &str, timestamp_ms: f64, prefix: Option<&str>, values: &[f64]) {
        // Collect channel names first
        let channel_names: Vec<(String, f64)> = values
            .iter()
            .enumerate()
            .map(|(i, value)| {
                let ch_name = match prefix {
                    Some(p) => format!("{}_{}", p, i),
                    None => format!("ch{}", i),
                };
                (ch_name, *value)
            })
            .collect();

        // Single lock: create device + channels if needed
        {
            let mut devices = self.devices.write().unwrap_or_else(|e| e.into_inner());
            let dc = devices
                .entry(device_id.to_string())
                .or_insert_with(HashMap::new);
            for (ch_name, _) in &channel_names {
                dc.entry(ch_name.clone())
                    .or_insert_with(|| Arc::new(Mutex::new(ChannelBuffer::new(self.default_capacity))));
            }
        }

        // Push data (device/channels now guaranteed to exist)
        {
            let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
            if let Some(dc) = devices.get(device_id) {
                for (ch_name, value) in &channel_names {
                    if let Some(buf) = dc.get(ch_name) {
                        lock_mutex(&buf).push(timestamp_ms, *value);
                    }
                }
            }
        }

        // 触发回调
        let callbacks = self.callbacks.read().unwrap_or_else(|e| e.into_inner());
        if let Some(cbs) = callbacks.get(device_id) {
            for cb in cbs {
                cb(device_id, timestamp_ms, values);
            }
        }
    }

    /// 批量添加数据（使用友好的通道名称）
    /// 第一列: prefix (或 "ch0")
    /// 后续列: "ch1", "ch2", ...
    pub fn push_batch_with_names(&self, device_id: &str, timestamp_ms: f64, prefix: Option<&str>, values: &[f64]) {
        // Collect channel names: first value → prefix, others → ch1, ch2...
        let channel_names: Vec<(String, f64)> = values
            .iter()
            .enumerate()
            .map(|(i, value)| {
                let ch_name = if i == 0 {
                    // First value: use prefix (or "ch0")
                    prefix.map(|p| p.to_string()).unwrap_or_else(|| "ch0".to_string())
                } else {
                    // Subsequent values: ch1, ch2...
                    format!("ch{}", i)
                };
                (ch_name, *value)
            })
            .collect();

        // Single lock: create device + channels if needed
        {
            let mut devices = self.devices.write().unwrap_or_else(|e| e.into_inner());
            let dc = devices
                .entry(device_id.to_string())
                .or_insert_with(HashMap::new);
            for (ch_name, _) in &channel_names {
                dc.entry(ch_name.clone())
                    .or_insert_with(|| Arc::new(Mutex::new(ChannelBuffer::new(self.default_capacity))));
            }
        }

        // Push data (device/channels now guaranteed to exist)
        {
            let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
            if let Some(dc) = devices.get(device_id) {
                for (ch_name, value) in &channel_names {
                    if let Some(buf) = dc.get(ch_name) {
                        lock_mutex(&buf).push(timestamp_ms, *value);
                    }
                }
            }
        }

        // 触发回调
        let callbacks = self.callbacks.read().unwrap_or_else(|e| e.into_inner());
        if let Some(cbs) = callbacks.get(device_id) {
            for cb in cbs {
                cb(device_id, timestamp_ms, values);
            }
        }
    }

    /// 获取设备通道数据
    pub fn get_channel_data(&self, device_id: &str, channel: &str) -> Vec<DataPoint> {
        let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
        if let Some(device_channels) = devices.get(device_id) {
            if let Some(buffer) = device_channels.get(channel) {
                return lock_mutex(&buffer).get_all();
            }
        }
        vec![]
    }

    /// 获取设备所有通道数据
    pub fn get_all_channels(&self, device_id: &str) -> HashMap<String, Vec<DataPoint>> {
        let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
        let mut result = HashMap::new();
        if let Some(device_channels) = devices.get(device_id) {
            for (ch, buffer) in device_channels {
                result.insert(ch.clone(), lock_mutex(&buffer).get_all());
            }
        }
        result
    }

    /// 获取设备的通道列表
    pub fn get_channels(&self, device_id: &str) -> Vec<String> {
        let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
        if let Some(device_channels) = devices.get(device_id) {
            return device_channels.keys().cloned().collect();
        }
        vec![]
    }

    /// 清空设备数据
    pub fn clear_device(&self, device_id: &str) {
        let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
        if let Some(device_channels) = devices.get(device_id) {
            for buffer in device_channels.values() {
                lock_mutex(&buffer).clear();
            }
        }
    }
}

// 全局单例
lazy_static::lazy_static! {
    pub static ref PLOT_DATA: PlotDataManager = PlotDataManager::new();
}
