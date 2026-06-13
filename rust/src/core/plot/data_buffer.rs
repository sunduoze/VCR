// Plot Data Buffer - 双缓冲版本
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

/// 通道数据缓冲区（双缓冲环形）
#[derive(Debug)]
pub struct ChannelBuffer {
    /// 后端缓冲区（数据写入）
    back_data: Vec<DataPoint>,
    /// 后端写入位置
    back_write_pos: usize,
    /// 后端容量
    back_capacity: usize,
    /// 后端当前数据量
    back_len: usize,
    /// 前端缓冲区（UI 读取，从后端复制）
    front_data: Vec<DataPoint>,
    /// 前端数据量
    front_len: usize,
    /// Swap 锁（防止 swap 和 push 并发）
    swap_lock: Mutex<()>,
}

impl ChannelBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            back_data: vec![DataPoint { timestamp_ms: 0.0, value: 0.0 }; capacity],
            back_write_pos: 0,
            back_capacity: capacity,
            back_len: 0,
            front_data: vec![DataPoint { timestamp_ms: 0.0, value: 0.0 }; capacity],
            front_len: 0,
            swap_lock: Mutex::new(()),
        }
    }

    /// 添加数据点（写入后端缓冲区）
    pub fn push(&mut self, timestamp_ms: f64, value: f64) {
        self.back_data[self.back_write_pos] = DataPoint { timestamp_ms, value };
        self.back_write_pos = (self.back_write_pos + 1) % self.back_capacity;
        if self.back_len < self.back_capacity {
            self.back_len += 1;
        }
    }

    /// 获取所有数据点（从后端，按时间排序）
    /// 注意：这是内部方法，用于 swap 前复制数据
    fn get_back_all(&self) -> Vec<DataPoint> {
        if self.back_len < self.back_capacity {
            self.back_data[..self.back_len].to_vec()
        } else {
            let mut result = Vec::with_capacity(self.back_capacity);
            for i in 0..self.back_capacity {
                result.push(self.back_data[(self.back_write_pos + i) % self.back_capacity]);
            }
            result
        }
    }

    /// Swap 前后缓冲区（UI 线程调用）
    /// 将后端数据复制到前端（仅 delta），UI 读取前端数据（无需锁）
    /// 每次 swap 后重置后端缓冲区，确保前端只包含自上次 swap 以来的新增数据
    pub fn swap(&mut self) {
        // 获取锁，防止 push 并发
        let _guard = match self.swap_lock.lock() {
            Ok(g) => g,
            Err(poisoned) => {
                log::warn!("[PlotBuffer] swap_lock poisoned, recovering...");
                poisoned.into_inner()
            }
        };
        
        // 复制后端数据到前端（delta：自上次 swap 以来新增的数据）
        let new_front = self.get_back_all();
        self.front_len = new_front.len();
        
        // 如果前端容量不够，扩展
        if self.front_data.len() < self.front_len {
            self.front_data.resize(self.front_len, DataPoint { timestamp_ms: 0.0, value: 0.0 });
        }
        
        // 复制数据
        for (i, pt) in new_front.into_iter().enumerate() {
            self.front_data[i] = pt;
        }
        
        // 重置后端缓冲区：后续 push 只写入自本次 swap 以来的新数据
        self.back_write_pos = 0;
        self.back_len = 0;
    }

    /// 获取前端缓冲区数据（O(1) 读取，无锁）
    /// 注意：必须在 swap 之后调用
    pub fn get_all(&self) -> Vec<DataPoint> {
        if self.front_len == 0 {
            return vec![];
        }
        self.front_data[..self.front_len].to_vec()
    }

    /// 获取前端缓冲区长度（无锁）
    pub fn len(&self) -> usize {
        self.front_len
    }

    pub fn is_empty(&self) -> bool {
        self.front_len == 0
    }

    /// 获取后端缓冲区长度（用于调试）
    pub fn back_len_debug(&self) -> usize {
        self.back_len
    }

    /// 清空
    pub fn clear(&mut self) {
        self.back_write_pos = 0;
        self.back_len = 0;
        self.front_len = 0;
    }

    /// 动态调整后端缓冲区容量
    pub fn resize(&mut self, new_capacity: usize) {
        if new_capacity == self.back_capacity {
            return;
        }
        log::info!("[PlotBuffer] ChannelBuffer.resize: {} -> {}", self.back_capacity, new_capacity);
        
        // 保留后端最新数据
        let old_back = self.get_back_all();
        let mut new_back = vec![DataPoint { timestamp_ms: 0.0, value: 0.0 }; new_capacity];
        let copy_len = old_back.len().min(new_capacity);
        for i in 0..copy_len {
            new_back[i] = old_back[old_back.len() - copy_len + i];
        }
        
        self.back_data = new_back;
        self.back_capacity = new_capacity;
        self.back_len = copy_len;
        self.back_write_pos = copy_len % new_capacity;
        
        // 清空前端（下次 swap 会重新填充）
        self.front_len = 0;
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

    /// Swap 所有设备的通道缓冲区
    /// 调用频率：每 100ms 一次
    pub fn swap_all_buffers(&self) {
        let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
        for (device_id, channels) in devices.iter() {
            for (channel_name, buffer) in channels.iter() {
                let mut buf = lock_mutex(buffer);
                buf.swap();
                log::trace!("[PlotBuffer] swapped device={}, ch={}", device_id, channel_name);
            }
        }
    }

    /// 获取通道数据（全量，从前端缓冲区）
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
    /// 获取通道最新数据（自上次 swap 以来所有新增的点，从前端缓冲区读取）
    pub fn get_latest_data(&self, device_id: &str, channel: &str) -> Vec<DataPoint> {
        let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
        
        if let Some(device_channels) = devices.get(device_id) {
            if let Some(buffer) = device_channels.get(channel) {
                let data = lock_mutex(buffer);
                if data.front_len == 0 {
                    return vec![];
                }
                // 返回前端缓冲区所有数据（自上次 swap 以来的 delta）
                return data.front_data[..data.front_len].to_vec();
            }
        }
        vec![]
    }

    /// 获取通道数据：视口裁剪 + min/max 降采样
    /// 数据从前端缓冲区读取（无需额外锁）
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

        // 从前端缓冲区读取数据
        let all_data = {
            let devices = self.devices.read().unwrap_or_else(|e| e.into_inner());
            if let Some(device_channels) = devices.get(device_id) {
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
            }
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
