use crate::core::app_context::{block_on, DEBUG, init_logger, REGISTRY, RT, SESSIONS};
use crate::core::session::debug_session::DebugLogEntry;
use crate::core::transport::TransportError;
use crate::core::protocol::parse_csv_line;
use crate::core::plot::PLOT_DATA;
use super::lua_api::trigger_callback;
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex, MutexGuard};

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
// Logger 初始化
// ============================================================================

/// Initialize the Rust logger to output to the debug console window.
/// Called once at app startup.
#[flutter_rust_bridge::frb(sync)]
pub fn debug_init_logger() {
    init_logger();
    log::info!("[VCR] Logger initialized — debug console active");
}

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

#[flutter_rust_bridge::frb(sync)]
pub fn debug_get_log_with_limit(device_id: String, max_size: i32) -> Vec<DebugLogEntry> {
    DEBUG.get_log_with_limit(&device_id, max_size as usize)
}

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
    SESSIONS.is_connected_sync(&device_id)
}

#[flutter_rust_bridge::frb(sync)]
pub fn debug_get_active_sessions() -> Vec<String> {
    DEBUG.active_sessions()
}

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
// 后台接收循环（Lua/CSV/Plot 步骤 panic 安全隔离）
// ============================================================================

/// 启动后台接收循环（供 device_api 的 connectDevice 也调用）
pub fn start_receive_loop_if_needed(device_id: &str) {
    let has_task = lock_mutex(&RECEIVE_TASKS)
        .contains_key(device_id);
    if !has_task {
        println!("🧪 [DEBUG] 启动接收循环: {}", device_id);
        spawn_receive_loop(device_id.to_string());
    } else {
        println!("🧪 [DEBUG] 接收循环已存在: {}", device_id);
    }
}

fn spawn_receive_loop(device_id: String) {
    stop_receive_loop(&device_id);

    let id = device_id.clone();
    
    // ✅ 添加外层 panic 防护：确保异步任务中的 panic 不会导致整个程序崩溃
    let handle = RT.spawn(async move {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            // 注意：catch_unwind 不能捕获 async 块中的 panic
            // 所以我们使用另一种策略：在循环内部添加错误处理
        }));
        
        // 使用 loop + 错误处理，而不是 catch_unwind
        loop {
            // Phase 1: receive (tokio I/O — no panic risk here)
            let data: Result<Vec<u8>, TransportError> = match SESSIONS.receive(&id).await {
                Ok(data) if !data.is_empty() => {
                    println!("🧪 [DEBUG] 收到数据: {} 字节", data.len());
                    Ok(data)
                },
                Ok(_) => {
                    println!("🧪 [DEBUG] 收到空数据，继续等待...");
                    continue;    // empty timeout — retry
                },
                Err(TransportError::Timeout) => {
                    println!("🧪 [DEBUG] 接收超时，继续等待...");
                    continue;
                },
                Err(e) => {
                    let _ = std::panic::catch_unwind(|| {
                        DEBUG.log_error(&id, &format!("Device disconnected: {:?}", e));
                    });
                    println!("🧪 [DEBUG] 设备断开连接: {:?}", e);
                    break;
                }
            };

            let data = match data {
                Ok(d) => d,
                Err(_) => break,
            };

            // Log RX always (no panic risk)
            DEBUG.log_rx(&id, &data);

            // Phase 2: Lua callback — wrapped in catch_unwind
            // Lua execution can panic on bad script / stack overflow / etc.
            let cb_ok = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                trigger_callback("uart", &data);
            })).is_ok();
            if !cb_ok {
                let _ = std::panic::catch_unwind(|| {
                    DEBUG.log_error(&id, "Lua callback panicked (ignored)");
                });
            }

            // Phase 3: CSV parse + Plot push — wrapped in catch_unwind
            // Parse ALL complete lines (not just the first one)
            if let Ok(text) = String::from_utf8(data.clone()) {
                let parse_ok = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    // Split by all line endings: \n, \r\n, \n\r, \r
                    let lines: Vec<&str> = text.split(|c| c == '\n' || c == '\r')
                        .map(|l| l.trim())
                        .filter(|l| !l.is_empty())
                        .collect();
                    
                    for line in lines {
                        let result = parse_csv_line(line);
                        if result.success && !result.channels.is_empty() {
                    // Use counter-based X axis (from 0, incrementing)
                            let counter = PLOT_DATA.next_counter() as f64;
                            // Channel naming: first value → prefix (or "ch0"), others → ch1, ch2...
                            let prefix = result.metadata.get("prefix").map(|s| s.as_str());
                            PLOT_DATA.push_batch_with_names(&id, counter, prefix, &result.channels);
                        }
                    }
                })).is_ok();
                if !parse_ok {
                    let _ = std::panic::catch_unwind(|| {
                        DEBUG.log_error(&id, "CSV/Plot parse panicked (ignored)");
                    });
                }
            }
        }
    });

    lock_mutex(&RECEIVE_TASKS).insert(device_id, handle);
}

pub fn stop_receive_loop(device_id: &str) {
    if let Some(handle) = lock_mutex(&RECEIVE_TASKS).remove(device_id) {
        handle.abort();
    }
}