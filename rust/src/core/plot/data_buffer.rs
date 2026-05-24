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

    /// 动态调整缓冲区容量（保留最新的 min(old, new) 个点）
    pub fn resize(&mut self, new_capacity: usize) {
        if new_capacity == self.capacity {
            return;
        }
        log::info!("[PlotBuffer] ChannelBuffer.resize: {} -> {}", self.capacity, new_capacity);
        let mut new_data = vec![DataPoint { timestamp_ms: 0.0, value: 0.0 }; new_capacity];
        // 复制已有数据（保留最新的 min(old_len, new_capacity) 个点）
        let old_data = self.get_all();
        let copy_len = old_data.len().min(new_capacity);
        for i in 0..copy_len {
            new_data[i] = old_data[old_data.len() - copy_len + i];
        }
        self.data = new_data;
        self.capacity = new_capacity;
        self.len = copy_len;
        self.write_pos = copy_len % new_capacity;
    }
}

/// Plot 数据管理器（全局单例）
pub struct PlotDataManager {
    /// 设备数据：device_id -> (channel_name -> buffer)
    devices: RwLock<HashMap<String, HashMap<String, Arc<Mutex<ChannelBuffer>>>>>,
    /// 默认容量（可动态修改）
    default_capacity: RwLock<usize>,
    /// 订阅回调：device_id -> callbacks
    callbacks: RwLock<HashMap<String, Vec<Box<dyn Fn(&str, f64, &[f64]) + Send + Sync>>>>,
    /// 样本计数器（用于 X 轴从0开始递增）
    sample_counter: RwLock<u64>,
}

impl PlotDataManager {
    pub fn new() -> Self {
        Self {
            devices: RwLock::new(HashMap::new()),
            default_capacity: RwLock::new(10000),
            callbacks: RwLock::new(HashMap::new()),
            sample_counter: RwLock::new(0),
        }
    }

    /// 设置默认容量（动态调整缓冲区大小）
    pub fn set_default_capacity(&self, capacity: usize) {
        log::info!("[PlotBuffer] set_default_capacity: {} (START)", capacity);
        
        // 第一步：收集所有 buffer 引用（只读锁，短暂持有）
        let mut all_buffers = Vec::new();
        {
            let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
            for (device_id, channels) in devices.iter() {
                for (channel_name, buffer) in channels.iter() {
                    all_buffers.push((device_id.clone(), channel_name.clone(), Arc::clone(buffer)));
                }
            }
        } // devices 读锁在这里释放
        
        log::info!("[PlotBuffer] collected {} buffers", all_buffers.len());
        
        // 第二步：调整所有 buffer 的容量（不持有 devices 锁）
        for (device_id, channel_name, buffer) in all_buffers {
            let mut buf = lock_mutex(&buffer);
            buf.resize(capacity);
            log::debug!("[PlotBuffer] resized device={}, channel={}, new_capacity={}", 
                       device_id, channel_name, capacity);
        }
        
        // 第三步：更新 default_capacity
        let mut cap = self.default_capacity.write().unwrap_or_else(|e| e.into_inner());
        *cap = capacity;
        
        log::info!("[PlotBuffer] set_default_capacity: {} (END)", capacity);
    }

    /// 获取当前默认容量
    pub fn get_default_capacity(&self) -> usize {
        *self.default_capacity.read().unwrap_or_else(|e| e.into_inner())
    }

    /// 注册设备
    pub fn register_device(&self, device_id: &str, channels: &[&str]) {
        log::info!("[PlotBuffer] register_device: device={}, channels={:?}", device_id, channels);
        let mut devices = self.devices.write().unwrap_or_else(|e| e.into_inner());
        let mut device_channels = HashMap::new();
        for ch in channels {
            device_channels.insert(
                ch.to_string(),
                Arc::new(Mutex::new(ChannelBuffer::new(*self.default_capacity.read().unwrap_or_else(|e| e.into_inner())))),
            );
        }
        devices.insert(device_id.to_string(), device_channels);
    }

    /// 注销设备
    pub fn unregister_device(&self, device_id: &str) {
        log::info!("[PlotBuffer] unregister_device: device={}", device_id);
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
            log::info!("[PlotBuffer] auto-create channel: device={}, ch={}", device_id, channel);
            let mut devices = self.devices.write().unwrap_or_else(|e| e.into_inner());
            devices
                .entry(device_id.to_string())
                .or_insert_with(HashMap::new);
            if let Some(dc) = devices.get_mut(device_id) {
                dc.insert(
                    channel.to_string(),
                    Arc::new(Mutex::new(ChannelBuffer::new(*self.default_capacity.read().unwrap_or_else(|e| e.into_inner())))),
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
        // Collect channel names first (push_batch: prefix_i format)
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
            let cap = *self.default_capacity.read().unwrap_or_else(|e| e.into_inner());
            for (ch_name, _) in &channel_names {
                dc.entry(ch_name.clone())
                    .or_insert_with(|| Arc::new(Mutex::new(ChannelBuffer::new(cap))));
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

        // Single lock: create device + channels if needed (push_batch_with_names)
        {
            let mut devices = self.devices.write().unwrap_or_else(|e| e.into_inner());
            let dc = devices
                .entry(device_id.to_string())
                .or_insert_with(HashMap::new);
            let cap = *self.default_capacity.read().unwrap_or_else(|e| e.into_inner());
            for (ch_name, _) in &channel_names {
                dc.entry(ch_name.clone())
                    .or_insert_with(|| Arc::new(Mutex::new(ChannelBuffer::new(cap))));
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

    /// 获取通道数据（全量）
    pub fn get_channel_data(&self, device_id: &str, channel: &str) -> Vec<DataPoint> {
        let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
        if let Some(device_channels) = devices.get(device_id) {
            if let Some(buffer) = device_channels.get(channel) {
                let data = lock_mutex(&buffer).get_all();
                log::debug!("[PlotBuffer] get_channel_data: device={}, ch={}, len={}", device_id, channel, data.len());
                return data;
            }
        }
        log::warn!("[PlotBuffer] get_channel_data: device={}, ch={} -> NOT FOUND", device_id, channel);
        vec![]
    }
/// 获取通道最新数据点（O(1) 查询）
    /// 
    /// # 参数
    /// - `device_id`: 设备 ID
    /// - `channel`: 通道名称
    /// 
    /// # 返回
    /// 最新数据点（如果通道不存在或没有数据，返回 None）
    /// 获取通道最新数据点（O(1) 查询）
    /// 
    /// # 参数
    /// - `device_id`: 设备 ID
    /// - `channel`: 通道名称
    /// 
    /// # 返回
    /// 最新数据点（如果通道不存在或没有数据，返回 None）
    pub fn get_latest_data(&self, device_id: &str, channel: &str) -> Option<DataPoint> {
        let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
        
        devices.get(device_id)
            .and_then(|channels| {
                channels.get(channel)
                    .map(|buffer| {
                        let data = buffer.lock().unwrap();
                        data.data.last().cloned()
                    })
            })
            .flatten()
    }

    /// 获取通道数据：视口裁剪 + min/max 降采样
    /// 返回在 [x_min, x_max] 范围内的数据，最多 max_points 个点。
    /// 使用 min/max 降采样：每个桶保留极值点，确保波形轮廓完整。
    /// 首尾数据点始终保留，防止边界空白。
    pub fn get_channel_viewport_data(
        &self,
        device_id: &str,
        channel: &str,
        x_min: f64,
        x_max: f64,
        max_points: usize,
    ) -> Vec<DataPoint> {
        if max_points == 0 {
            return vec![];
        }

        let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
        let all_data = if let Some(device_channels) = devices.get(device_id) {
            if let Some(buffer) = device_channels.get(channel) {
                let data = lock_mutex(&buffer).get_all();
                log::debug!("[PlotBuffer] get_channel_viewport_data: device={}, ch={}, total={}, x=[{:.1},{:.1}], max={}",
                    device_id, channel, data.len(), x_min, x_max, max_points);
                data
            } else {
                log::warn!("[PlotBuffer] get_channel_viewport_data: channel '{}' not found for device '{}'", channel, device_id);
                return vec![];
            }
        } else {
            log::warn!("[PlotBuffer] get_channel_viewport_data: device '{}' not found", device_id);
            return vec![];
        };

        if all_data.is_empty() {
            return vec![];
        }

        // Step 1: Binary search for viewport range
        let margin = (x_max - x_min) * 0.01;
        let search_min = x_min - margin;
        let search_max = x_max + margin;

        // Find start index (first point >= search_min)
        let start_idx = match all_data.binary_search_by(|p| p.timestamp_ms.partial_cmp(&search_min).unwrap()) {
            Ok(i) => i.saturating_sub(1),
            Err(i) => i.saturating_sub(1),
        };

        // Find end index (last point <= search_max)
        let end_idx = match all_data.binary_search_by(|p| p.timestamp_ms.partial_cmp(&search_max).unwrap()) {
            Ok(i) => (i + 1).min(all_data.len()),
            Err(i) => i,
        };

        let viewport_data = &all_data[start_idx..end_idx];
        if viewport_data.is_empty() {
            return vec![];
        }

        // Step 2: Decimate if needed
        if viewport_data.len() <= max_points {
            return viewport_data.to_vec();
        }

        // Min/max decimation with first/last point preservation
        let bucket_size = viewport_data.len() as f64 / max_points as f64;
        let mut result = Vec::with_capacity(max_points * 2 + 2);

        for i in 0..max_points {
            let start = (i as f64 * bucket_size) as usize;
            let end = ((i as f64 + 1.0) * bucket_size).ceil() as usize;
            let end = end.min(viewport_data.len());

            if start >= viewport_data.len() {
                break;
            }

            let mut min_pt = viewport_data[start];
            let mut max_pt = viewport_data[start];

            for j in (start + 1)..end {
                if viewport_data[j].value < min_pt.value {
                    min_pt = viewport_data[j];
                }
                if viewport_data[j].value > max_pt.value {
                    max_pt = viewport_data[j];
                }
            }

            // Add both min and max in time order for line continuity
            if min_pt.timestamp_ms <= max_pt.timestamp_ms {
                result.push(min_pt);
                if min_pt.timestamp_ms != max_pt.timestamp_ms {
                    result.push(max_pt);
                }
            } else {
                result.push(max_pt);
                result.push(min_pt);
            }
        }

        // Ensure first and last points are included
        let first = viewport_data.first().unwrap();
        let last = viewport_data.last().unwrap();
        if result.first().map_or(true, |p| p.timestamp_ms != first.timestamp_ms) {
            result.insert(0, *first);
        }
        if result.last().map_or(true, |p| p.timestamp_ms != last.timestamp_ms) {
            result.push(*last);
        }

        result
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

    /// 获取当前样本计数器值
    pub fn get_counter(&self) -> u64 {
        *self.sample_counter.read().unwrap_or_else(|e| e.into_inner())
    }

    /// 重置样本计数器
    pub fn clear_counter(&self) {
        let mut counter = self.sample_counter.write().unwrap_or_else(|e| e.into_inner());
        *counter = 0;
    }

    /// 获取并递增计数器（返回新值）
    pub fn next_counter(&self) -> u64 {
        let mut counter = self.sample_counter.write().unwrap_or_else(|e| e.into_inner());
        let new_val = *counter + 1;
        *counter = new_val;
        new_val
    }
}

// 全局单例
lazy_static::lazy_static! {
    pub static ref PLOT_DATA: PlotDataManager = PlotDataManager::new();
}
