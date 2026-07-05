use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

/// 安全获取 Mutex 锁，遇到 PoisonError 时恢复而非 panic
fn lock_mutex<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            log::warn!("[DebugSession] Mutex was poisoned, recovering...");
            poisoned.into_inner()
        }
    }
}

/// 调试日志条目
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DebugLogEntry {
    pub timestamp: i64,
    pub direction: String,
    pub data: Vec<u8>,
    pub display: String,
    pub index: u64, // 全局递增索引，支持增量查询 (P1)
}

/// 调试会话内部状态
struct DebugSessionInner {
    log: VecDeque<DebugLogEntry>,
    connected: bool,
    max_size: usize, // 最大缓冲区大小（字节）
    entry_index: u64, // 全局递增的条目索引，支持增量查询
    total_data_size: usize, // 运行中累计，避免 O(N) sum() 每次 push
}

impl Default for DebugSessionInner {
    fn default() -> Self {
        Self {
            log: VecDeque::new(),
            connected: false,
            max_size: 200 * 1024, // 默认 200KB
            entry_index: 0,
            total_data_size: 0,
        }
    }
}

/// 调试会话管理器（纯日志记录，不含连接逻辑）
pub struct DebugSessionManager {
    sessions: Mutex<std::collections::HashMap<String, DebugSessionInner>>,
}

impl DebugSessionManager {
    pub fn new() -> Self {
        Self {
            sessions: Mutex::new(std::collections::HashMap::new()),
        }
    }

    pub fn mark_connected(&self, device_id: &str) {
        let mut sessions = lock_mutex(&self.sessions);
        let entry = sessions.entry(device_id.to_string()).or_default();
        entry.connected = true;
        let idx = entry.entry_index;
        entry.entry_index += 1;
        entry.log.push_back(DebugLogEntry {
            timestamp: now_ms(),
            direction: "SYS".into(),
            data: vec![],
            display: "[System] Connected".into(),
            index: idx,
        });
    }

    pub fn mark_disconnected(&self, device_id: &str) {
        let mut sessions = lock_mutex(&self.sessions);
        if let Some(s) = sessions.get_mut(device_id) {
            s.connected = false;
            let idx = s.entry_index;
            s.entry_index += 1;
            s.log.push_back(DebugLogEntry {
                timestamp: now_ms(),
                direction: "SYS".into(),
                data: vec![],
                display: "[System] Disconnected".into(),
                index: idx,
            });
        }
    }

    pub fn log_tx(&self, device_id: &str, data: &[u8]) {
        self.push_entry(device_id, "TX", data, bytes_to_ascii(data));
    }

    /// Log RX data, splitting by line endings for millisecond-level timestamp precision
    /// Each line (\r\n, \r, or \n delimited) gets its own entry with its own timestamp
    pub fn log_rx(&self, device_id: &str, data: &[u8]) {
        // Check if data contains line endings
        let has_line_endings = data.iter().any(|&b| b == b'\r' || b == b'\n');

        if has_line_endings {
            // Split by \r\n, \r, or \n and create separate entries with individual timestamps
            let lines = split_by_line_endings(data);
            for (line_data, line_display) in lines {
                if !line_data.is_empty() || !line_display.is_empty() {
                    self.push_entry(device_id, "RX", &line_data, line_display);
                }
            }
        } else {
            // No line endings - single entry
            self.push_entry(device_id, "RX", data, bytes_to_ascii(data));
        }
    }

    pub fn log_error(&self, device_id: &str, msg: &str) {
        self.push_entry(device_id, "ERR", &[], format!("[System] {}", msg));
    }

    /// 获取日志（应用缓冲区大小限制）
    pub fn get_log(&self, device_id: &str) -> Vec<DebugLogEntry> {
        self.sessions
            .lock()
            .unwrap()
            .get(device_id)
            .map(|s| s.log.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// 获取日志并裁剪到指定大小。
    /// P0: mem::take 指针交换 — 持锁 <1µs，trim 在锁外完成。
    /// 接收线程 log_rx/push_entry 不再被此函数阻塞。
    pub fn get_log_with_limit(&self, device_id: &str, max_size: usize) -> Vec<DebugLogEntry> {
        // Phase 1: extract log under lock (pointer swap, O(1) real work)
        let mut log: Vec<DebugLogEntry>;
        {
            let mut sessions = lock_mutex(&self.sessions);
            if let Some(s) = sessions.get_mut(device_id) {
                s.max_size = max_size;
                log = std::mem::take(&mut s.log).into_iter().collect(); // VecDeque → Vec
                s.total_data_size = 0; // recalculated in Phase 3
            } else {
                return Vec::new();
            }
        } // lock released — receiver can push to empty VecDeque

        // Phase 2: trim to max_size (lock-free)
        let total_size: usize = log.iter().map(|e| e.data.len()).sum();
        if total_size > max_size {
            let mut current_size = total_size;
            let mut remove_count = 0;
            for entry in &log {
                if current_size <= max_size {
                    break;
                }
                current_size -= entry.data.len();
                remove_count += 1;
            }
            if remove_count > 0 {
                log.drain(0..remove_count);
            }
        }

        // Phase 3: merge back — append any new entries the receiver added during Phase 2
        {
            let mut sessions = lock_mutex(&self.sessions);
            if let Some(s) = sessions.get_mut(device_id) {
                let new_entries = std::mem::take(&mut s.log); // entries added during Phase 2
                log.extend(new_entries); // trimmed log + new entries
                s.total_data_size = log.iter().map(|e| e.data.len()).sum();
                s.log = log.iter().cloned().collect(); // Vec → VecDeque
            }
        }

        log
    }

    /// P1: 返回索引 > since_index 的日志条目（增量查询）。
    /// 相比 get_log_with_limit，FRB 序列化量从 200KB → 通常 <2KB。
    pub fn get_log_since(&self, device_id: &str, since_index: u64) -> Vec<DebugLogEntry> {
        let sessions = lock_mutex(&self.sessions);
        if let Some(s) = sessions.get(device_id) {
            s.log
                .iter()
                .filter(|e| e.index > since_index)
                .cloned()
                .collect()
        } else {
            Vec::new()
        }
    }

    /// 设置缓冲区大小
    pub fn set_max_size(&self, device_id: &str, max_size: usize) {
        let mut sessions = lock_mutex(&self.sessions);
        if let Some(s) = sessions.get_mut(device_id) {
            s.max_size = max_size;
        }
    }

    pub fn clear_log(&self, device_id: &str) -> bool {
        if let Some(s) = lock_mutex(&self.sessions).get_mut(device_id) {
            s.log.clear();
            s.entry_index = 0; // 重置索引，增量查询从 0 重新开始
            s.total_data_size = 0;
            true
        } else {
            false
        }
    }

    pub fn is_connected(&self, device_id: &str) -> bool {
        self.sessions
            .lock()
            .unwrap()
            .get(device_id)
            .map(|s| s.connected)
            .unwrap_or(false)
    }

    pub fn active_sessions(&self) -> Vec<String> {
        self.sessions
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, s)| s.connected)
            .map(|(id, _)| id.clone())
            .collect()
    }

    fn push_entry(&self, device_id: &str, direction: &str, data: &[u8], display: String) {
        let data_len = data.len();
        let mut sessions = lock_mutex(&self.sessions);
        let entry = sessions.entry(device_id.to_string()).or_default();

        let idx = entry.entry_index;
        entry.entry_index += 1;

        // 添加新条目
        entry.log.push_back(DebugLogEntry {
            timestamp: now_ms(),
            direction: direction.to_string(),
            data: data.to_vec(),
            display,
            index: idx,
        });
        entry.total_data_size += data_len;

        // O(1) trim from front (VecDeque pop_front is cheap)
        while entry.total_data_size > entry.max_size && !entry.log.is_empty() {
            if let Some(removed) = entry.log.pop_front() {
                entry.total_data_size -= removed.data.len();
            }
        }
    }
}

impl Default for DebugSessionManager {
    fn default() -> Self {
        Self::new()
    }
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

fn bytes_to_ascii(data: &[u8]) -> String {
    data.iter()
        .map(|b| {
            if b.is_ascii_graphic() || *b == b' ' || *b == b'\t' || *b == b'\n' || *b == b'\r' {
                *b as char
            } else {
                '.'
            }
        })
        .collect()
}

/// Split data by line endings (\r\n, \r, \n), returning (raw_bytes, display_string) for each line.
/// Line ending characters are kept as part of the line data — not stripped — so they appear
/// in the console output (visible in HEX mode, or as control chars in text mode).
fn split_by_line_endings(data: &[u8]) -> Vec<(Vec<u8>, String)> {
    let mut result = Vec::new();
    let mut start = 0;
    let mut i = 0;

    while i < data.len() {
        let end: usize;
        if i + 1 < data.len() && data[i] == b'\r' && data[i + 1] == b'\n' {
            end = i + 2; // \r\n pair — keep both
        } else if data[i] == b'\r' || data[i] == b'\n' {
            end = i + 1; // single \r or \n — keep it
        } else {
            i += 1;
            continue;
        }
        // Extract line INCLUDING the line ending character(s)
        let line_data = &data[start..end];
        let line_display = bytes_to_ascii(line_data);
        result.push((line_data.to_vec(), line_display));
        start = end;
        i = end;
    }

    // Handle remaining data after last line ending (if any)
    if start < data.len() {
        let line_data = &data[start..];
        let line_display = bytes_to_ascii(line_data);
        result.push((line_data.to_vec(), line_display));
    }

    result
}
