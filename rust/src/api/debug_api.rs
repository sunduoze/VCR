use crate::core::app_context::{block_on, DEBUG, REGISTRY, RT, SESSIONS};
use crate::core::session::debug_session::DebugLogEntry;
use crate::core::transport::TransportError;
use crate::core::protocol::parse_csv_line;
use crate::core::plot::PLOT_DATA;
use super::lua_api::trigger_callback;
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

/// 安全获取 Mutex 锁，遇到 PoisonError 时恢复而非 panic
fn lock_mutex<T>(mutex: &Mutex<T>) -> MutexGuard<T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            log::warn!("[Debug] Mutex was poisoned, recovering...");
            poisoned.into_inner()
        }
    }
}

/// 后台接收任务的 join handle，用于断开时取消
static RECEIVE_TASKS: LazyLock<Mutex<HashMap<String, tokio::task::JoinHandle<()>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

// ============================================================================
// 数据收发
// ============================================================================

#[flutter_rust_bridge::frb(sync)]
pub fn debug_send_bytes(device_id: String, data: Vec<u8>) -> bool {
    DEBUG.log_tx(&device_id, &data);
    match block_on(SESSIONS.send(&device_id, &data)) {
        Ok(_) => true,
        Err(e) => {
            DEBUG.log_error(&device_id, &format!("Send error: {:?}", e));
            false
        }
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn debug_send_string(device_id: String, text: String, line_ending: String) -> bool {
    let full_text = match line_ending.as_str() {
        "CR" => format!("{}\r", text),
        "LF" => format!("{}\n", text),
        "CRLF" => format!("{}\r\n", text),
        "" | "NONE" | "None" => text,
        _ => format!("{}\n", text),
    };
    debug_send_bytes(device_id, full_text.into_bytes())
}

#[flutter_rust_bridge::frb(sync)]
pub fn debug_send_hex(device_id: String, hex_string: String) -> bool {
    let hex_str: String = hex_string.replace(' ', "");
    if hex_str.len() % 2 != 0 {
        return false;
    }
    let data: Vec<u8> = (0..hex_str.len())
        .step_by(2)
        .filter_map(|i| u8::from_str_radix(&hex_str[i..i + 2], 16).ok())
        .collect();
    debug_send_bytes(device_id, data)
}

/// 手动接收（备用，主要靠后台 receive loop 自动记录）
#[flutter_rust_bridge::frb(sync)]
pub fn debug_receive(device_id: String) -> Option<Vec<u8>> {
    match block_on(SESSIONS.receive(&device_id)) {
        Ok(data) if !data.is_empty() => {
            DEBUG.log_rx(&device_id, &data);
            Some(data)
        }
        _ => None,
    }
}

// ============================================================================
// 日志管理
// ============================================================================

#[flutter_rust_bridge::frb(sync)]
pub fn debug_get_log(device_id: String) -> Vec<DebugLogEntry> {
    DEBUG.get_log(&device_id)
}

/// 获取日志（带缓冲区大小限制）
#[flutter_rust_bridge::frb(sync)]
pub fn debug_get_log_with_limit(device_id: String, max_size: i32) -> Vec<DebugLogEntry> {
    DEBUG.get_log_with_limit(&device_id, max_size as usize)
}

/// 设置缓冲区大小
#[flutter_rust_bridge::frb(sync)]
pub fn debug_set_buffer_size(device_id: String, max_size: i32) {
    DEBUG.set_max_size(&device_id, max_size as usize);
}

#[flutter_rust_bridge::frb(sync)]
pub fn debug_clear_log(device_id: String) -> bool {
    DEBUG.clear_log(&device_id)
}

#[flutter_rust_bridge::frb(sync)]
pub fn debug_is_connected(device_id: String) -> bool {
    // 使用同步版本避免 block_on 死锁
    SESSIONS.is_connected_sync(&device_id)
}

#[flutter_rust_bridge::frb(sync)]
pub fn debug_get_active_sessions() -> Vec<String> {
    DEBUG.active_sessions()
}

/// 返回已连接设备的 (id, name) 列表，供 Lua UI 使用
#[flutter_rust_bridge::frb(sync)]
pub fn debug_get_active_device_names() -> Vec<(String, String)> {
    DEBUG
        .active_sessions()
        .into_iter()
        .map(|id| {
            let name = REGISTRY
                .get(&id)
                .map(|d| d.name)
                .unwrap_or_else(|| id.clone());
            (id, name)
        })
        .collect()
}

// ============================================================================
// 后台接收循环
// ============================================================================

/// 启动后台接收循环（供 device_api 的 connectDevice 也调用）
pub fn start_receive_loop_if_needed(device_id: &str) {
    let has_task = RECEIVE_TASKS
        .lock()
        .unwrap()
        .contains_key(device_id);
    if !has_task {
        spawn_receive_loop(device_id.to_string());
    }
}

fn spawn_receive_loop(device_id: String) {
    stop_receive_loop(&device_id);

    let id = device_id.clone();
    let handle = RT.spawn(async move {
        loop {
            match SESSIONS.receive(&id).await {
                Ok(data) if !data.is_empty() => {
                    DEBUG.log_rx(&id, &data);
                    
                    // 触发 Lua 回调（"uart" 通道）
                    trigger_callback("uart", &data);
                    
                    // 尝试解析 CSV 协议并推送到 Plot
                    if let Ok(text) = String::from_utf8(data.clone()) {
                        let result = parse_csv_line(&text);
                        if result.success && !result.values.is_empty() {
                            let timestamp_ms = SystemTime::now()
                                .duration_since(UNIX_EPOCH)
                                .map(|d| d.as_secs_f64() * 1000.0)
                                .unwrap_or(0.0);
                            PLOT_DATA.push_batch(
                                &id,
                                timestamp_ms,
                                result.prefix.as_deref(),
                                &result.values,
                            );
                        }
                    }
                }
                Ok(_) => {
                    // 空数据（超时），直接下一轮
                }
                Err(TransportError::Timeout) => {
                    // 超时是正常情况，直接下一轮
                }
                Err(_e) => {
                    DEBUG.log_error(&id, "Receive loop: device disconnected");
                    break;
                }
            }
        }
    });

    RECEIVE_TASKS
        .lock()
        .unwrap()
        .insert(device_id, handle);
}

pub fn stop_receive_loop(device_id: &str) {
    if let Some(handle) = lock_mutex(&RECEIVE_TASKS).remove(device_id) {
        handle.abort();
    }
}
