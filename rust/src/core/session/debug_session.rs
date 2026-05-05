use serde::{Deserialize, Serialize};
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

/// 安全获取 Mutex 锁，遇到 PoisonError 时恢复而非 panic
fn lock_mutex<T>(mutex: &Mutex<T>) -> MutexGuard<T> {
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
}

/// 调试会话内部状态
struct DebugSessionInner {
    log: Vec<DebugLogEntry>,
    connected: bool,
    max_size: usize, // 最大缓冲区大小（字节）
}

impl Default for DebugSessionInner {
    fn default() -> Self {
        Self {
            log: Vec::new(),
            connected: false,
            max_size: 200 * 1024, // 默认 200KB
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
        let entry = sessions
            .entry(device_id.to_string())
            .or_insert_with(DebugSessionInner::default);
        entry.connected = true;
        entry.log.push(DebugLogEntry {
            timestamp: now_ms(),
            direction: "SYS".into(),
            data: vec![],
            display: "[System] Connected".into(),
        });
    }

    pub fn mark_disconnected(&self, device_id: &str) {
        let mut sessions = lock_mutex(&self.sessions);
        if let Some(s) = sessions.get_mut(device_id) {
            s.connected = false;
            s.log.push(DebugLogEntry {
                timestamp: now_ms(),
                direction: "SYS".into(),
                data: vec![],
                display: "[System] Disconnected".into(),
            });
        }
    }

    pub fn log_tx(&self, device_id: &str, data: &[u8]) {
        self.push_entry(device_id, "TX", data, bytes_to_ascii(data));
    }

    pub fn log_rx(&self, device_id: &str, data: &[u8]) {
        self.push_entry(device_id, "RX", data, bytes_to_ascii(data));
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
            .map(|s| s.log.clone())
            .unwrap_or_default()
    }

    /// 获取日志并裁剪到指定大小
    pub fn get_log_with_limit(&self, device_id: &str, max_size: usize) -> Vec<DebugLogEntry> {
        let mut sessions = lock_mutex(&self.sessions);
        if let Some(s) = sessions.get_mut(device_id) {
            // 更新 max_size
            s.max_size = max_size;

            // 计算当前总大小
            let total_size: usize = s.log.iter().map(|e| e.data.len()).sum();

            if total_size > max_size {
                // 需要裁剪：从前面删除旧条目直到总大小 <= max_size
                let mut current_size = total_size;
                let mut remove_count = 0;

                for entry in &s.log {
                    if current_size <= max_size {
                        break;
                    }
                    current_size -= entry.data.len();
                    remove_count += 1;
                }

                if remove_count > 0 {
                    s.log.drain(0..remove_count);
                }
            }

            s.log.clone()
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
        let mut sessions = lock_mutex(&self.sessions);
        let entry = sessions
            .entry(device_id.to_string())
            .or_insert_with(DebugSessionInner::default);

        // 添加新条目
        entry.log.push(DebugLogEntry {
            timestamp: now_ms(),
            direction: direction.to_string(),
            data: data.to_vec(),
            display,
        });

        // 检查是否超过缓冲区限制
        let total_size: usize = entry.log.iter().map(|e| e.data.len()).sum();
        if total_size > entry.max_size {
            // 从前面删除旧条目
            let mut current_size = total_size;
            while current_size > entry.max_size && !entry.log.is_empty() {
                let removed = entry.log.remove(0);
                current_size -= removed.data.len();
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
