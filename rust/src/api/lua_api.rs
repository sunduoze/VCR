//! Lua 脚本引擎模块
//! 提供 LLCOM 风格的 Lua 脚本功能

use mlua::{Lua, Table, Result as LuaResult, Error as LuaError, Value, MultiValue, Function};
use std::sync::{Arc, Mutex, MutexGuard};
use std::collections::HashMap;
use lazy_static::lazy_static;
use super::debug_api::debug_send_bytes;
use crate::core::app_context::RT;
use super::lua_core_scripts::{LOG_LUA, SYS_LUA, HEAD_LUA};

/// 安全获取 Mutex 锁，遇到 PoisonError 时恢复而非 panic
/// Poisoned 仅表示"持锁期间曾发生 panic"，数据本身通常仍可用
fn lock_mutex<T>(mutex: &Mutex<T>) -> MutexGuard<T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            log::warn!("[Lua] Mutex was poisoned, recovering...");
            poisoned.into_inner()
        }
    }
}

lazy_static! {
    static ref CALLBACKS: Arc<Mutex<HashMap<String, Vec<Function>>>> = Arc::new(Mutex::new(HashMap::new()));
    static ref TIMER_TASKS: Arc<Mutex<HashMap<u32, tokio::task::JoinHandle<()>>>> = Arc::new(Mutex::new(HashMap::new()));
    /// apiInputBox 共享状态
    static ref INPUT_BOX_STATE: Arc<Mutex<InputBoxState>> = Arc::new(Mutex::new(InputBoxState::new()));
    /// apiInputBox 响应通道
    static ref INPUT_BOX_RESPONSES: Arc<Mutex<HashMap<u64, std::sync::mpsc::Sender<String>>>> = Arc::new(Mutex::new(HashMap::new()));
}

/// InputBox 状态机
struct InputBoxState {
    /// 等待中的请求
    pending: Option<InputBoxRequest>,
    /// 请求计数器（用于生成唯一 ID）
    next_id: u64,
}

struct InputBoxRequest {
    id: u64,
    prompt: String,
    default_value: String,
    title: String,
}

impl InputBoxState {
    fn new() -> Self {
        Self { pending: None, next_id: 1 }
    }
}

/// Lua 引擎（私有，不暴露给 Dart）
struct LuaEngine {
    lua: Lua,
    device_id: Arc<Mutex<String>>,
    /// Lua 日志缓冲区（供 Dart 端读取）
    log_buffer: Arc<Mutex<Vec<String>>>,
    /// Plot 数据点缓冲区（供 Dart 端读取）
    point_buffer: Arc<Mutex<Vec<(f64, usize)>>>,
}

impl LuaEngine {
    /// 创建新的 Lua 引擎（crate 内部可见）
    fn new() -> LuaResult<Self> {
        let lua = Lua::new();
        let engine = Self {
            lua,
            device_id: Arc::new(Mutex::new(String::new())),
            log_buffer: Arc::new(Mutex::new(Vec::new())),
            point_buffer: Arc::new(Mutex::new(Vec::new())),
        };
        engine.register_basic_api()?;
        engine.load_core_scripts()?;
        Ok(engine)
    }

    /// 设置当前设备 ID（crate 内部可见）
    fn set_device_id(&mut self, device_id: String) {
        let mut id = lock_mutex(&self.device_id);
        *id = device_id;
    }

    /// 注册基础 API
    fn register_basic_api(&self) -> LuaResult<()> {
        let globals = self.lua.globals();

        // 重写 print 函数，输出到 Rust 日志
        let print_fn = self.lua.create_function(move |_lua, args: MultiValue| {
            let mut msg = String::new();
            for (i, value) in args.iter().enumerate() {
                if i > 0 { msg.push('\t'); }
                match value {
                    Value::String(s) => {
                        let s = s.to_str()
                            .map(|s| s.to_string())
                            .unwrap_or_else(|_| "?".to_string());
                        msg.push_str(&s);
                    },
                    _ => msg.push_str(&value.to_string().unwrap_or("?".to_string())),
                }
            }
            log::info!("[Lua Print] {}", msg);
            Ok(())
        })?;
        globals.set("print", print_fn)?;

        // 简单的日志函数
        let log_table = self.lua.create_table()?;
        let info_fn = self.lua.create_function(move |_lua, (tag, msg): (String, String)| {
            log::info!("[Lua {}] {}", tag, msg);
            Ok(())
        })?;
        log_table.set("info", info_fn)?;
        // 添加其他日志级别
        let trace_fn = self.lua.create_function(move |_lua, (tag, msg): (String, String)| {
            log::trace!("[Lua {}] {}", tag, msg);
            Ok(())
        })?;
        log_table.set("trace", trace_fn)?;
        let debug_fn = self.lua.create_function(move |_lua, (tag, msg): (String, String)| {
            log::debug!("[Lua {}] {}", tag, msg);
            Ok(())
        })?;
        log_table.set("debug", debug_fn)?;
        let warn_fn = self.lua.create_function(move |_lua, (tag, msg): (String, String)| {
            log::warn!("[Lua {}] {}", tag, msg);
            Ok(())
        })?;
        log_table.set("warn", warn_fn)?;
        let error_fn = self.lua.create_function(move |_lua, (tag, msg): (String, String)| {
            log::error!("[Lua {}] {}", tag, msg);
            Ok(())
        })?;
        log_table.set("error", error_fn)?;
        let fatal_fn = self.lua.create_function(move |_lua, (tag, msg): (String, String)| {
            log::error!("[Lua FATAL {}] {}", tag, msg);
            // 可以选择 panic 或退出，这里只记录日志
            Ok(())
        })?;
        log_table.set("fatal", fatal_fn)?;
        globals.set("log", log_table)?;

        // 字符串扩展：toHex
        let string_table: Table = globals.get("string")?;
        let to_hex_fn = self.lua.create_function(move |_lua, s: String| {
            let hex: String = s.bytes().map(|b| format!("{:02X}", b)).collect();
            Ok(hex)
        })?;
        string_table.set("toHex", to_hex_fn)?;

        // 字符串扩展：fromHex
        let from_hex_fn = self.lua.create_function(move |_lua, hex: String| {
            let hex_clean: String = hex.chars().filter(|c| !c.is_whitespace()).collect();
            if hex_clean.len() % 2 != 0 {
                return Err(LuaError::RuntimeError("Invalid hex string".to_string()));
            }
            let bytes: Vec<u8> = (0..hex_clean.len())
                .step_by(2)
                .filter_map(|i| u8::from_str_radix(&hex_clean[i..i+2], 16).ok())
                .collect();
            Ok(String::from_utf8_lossy(&bytes).to_string())
        })?;
        string_table.set("fromHex", from_hex_fn)?;

        // 字符串扩展：utf8Len
        let utf8_len_fn = self.lua.create_function(move |_lua, s: String| {
            Ok(s.chars().count())
        })?;
        string_table.set("utf8Len", utf8_len_fn)?;

        // 字符串扩展：split
        let split_fn = self.lua.create_function(move |_lua, (s, sep): (String, String)| {
            let parts: Vec<String> = s.split(&sep).map(|p| p.to_string()).collect();
            Ok(parts)
        })?;
        string_table.set("split", split_fn)?;

        // 字符串扩展：urlEncode
        let url_encode_fn = self.lua.create_function(move |_lua, s: String| {
            // 简单的 URL 百分比编码
            let encoded: String = s.bytes()
                .map(|b| {
                    let c = b as char;
                    if c.is_ascii_alphanumeric() || c == '-' || c == '.' || c == '_' || c == '~' {
                        c.to_string()
                    } else {
                        format!("%{:02X}", b)
                    }
                })
                .collect();
            Ok(encoded)
        })?;
        string_table.set("urlEncode", url_encode_fn)?;

        // LLCOM 风格 API：apiSendUartData - 发送串口数据
        let device_id_clone = Arc::clone(&self.device_id);
        let api_send_uart = self.lua.create_function(move |_lua, data: String| {
            let device_id = lock_mutex(&device_id_clone);
            if device_id.is_empty() {
                return Err(LuaError::RuntimeError("No device selected".to_string()));
            }
            let bytes = data.into_bytes();
            match debug_send_bytes(device_id.clone(), bytes) {
                true => Ok(Value::Boolean(true)),
                false => Err(LuaError::RuntimeError("Failed to send data".to_string())),
            }
        })?;
        globals.set("apiSendUartData", api_send_uart)?;

        // LLCOM API: apiGetPath - 返回软件所在目录（正斜杠格式）
        let get_path_fn = self.lua.create_function(move |_lua, _: ()| {
            let path = std::env::current_exe()
                .ok()
                .and_then(|p| p.parent().map(|p| p.to_string_lossy().to_string()))
                .unwrap_or_else(|| ".".to_string())
                .replace('\\', "/"); // Windows 反斜杠转正斜杠
            Ok(path)
        })?;
        globals.set("apiGetPath", get_path_fn)?;

        // LLCOM API: apiSetCb
        let set_cb_fn = self.lua.create_function(move |_lua, (channel, callback): (String, Function)| {
            let mut callbacks = lock_mutex(&CALLBACKS);
            callbacks.entry(channel).or_insert_with(Vec::new).push(callback);
            Ok(())
        })?;
        globals.set("apiSetCb", set_cb_fn)?;

        // LLCOM API: apiUnsetCb
        let unset_cb_fn = self.lua.create_function(move |_lua, (channel, _callback): (String, Function)| {
            let mut callbacks = lock_mutex(&CALLBACKS);
            callbacks.remove(&channel);
            Ok(())
        })?;
        globals.set("apiUnsetCb", unset_cb_fn)?;

        // LLCOM API: apiStartTimer(timerId, ms) -> 1 on success
        let start_timer_fn = self.lua.create_function(move |_lua, (timer_id, ms): (u32, u64)| {
            let handle = RT.spawn(async move {
                tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
                // 定时器到期，调用 Lua 的 sys.tigger(timerId)
                fire_sys_timer(timer_id);
            });
            lock_mutex(&TIMER_TASKS).insert(timer_id, handle);
            Ok(1)
        })?;
        globals.set("apiStartTimer", start_timer_fn)?;

        // LLCOM API: apiStopTimer(timerId)
        let stop_timer_fn = self.lua.create_function(move |_lua, timer_id: u32| {
            if let Some(handle) = lock_mutex(&TIMER_TASKS).remove(&timer_id) {
                handle.abort();
            }
            Ok(())
        })?;
        globals.set("apiStopTimer", stop_timer_fn)?;

        // LLCOM API: apiPrintLog(str) - 存储日志供 Dart 端读取
        let log_buf = Arc::clone(&self.log_buffer);
        let print_log_fn = self.lua.create_function(move |_lua, msg: String| {
            let mut buf = lock_mutex(&log_buf);
            buf.push(msg);
            // 保持缓冲区不超过 200 条
            if buf.len() > 200 {
                let excess = buf.len() - 200;
                buf.drain(0..excess);
            }
            Ok(())
        })?;
        globals.set("apiPrintLog", print_log_fn)?;

        // LLCOM API: apiAddPoint(num, line) - 存储 Plot 数据点
        let point_buf = Arc::clone(&self.point_buffer);
        let add_point_fn = self.lua.create_function(move |_lua, (num, line): (f64, usize)| {
            let mut buf = lock_mutex(&point_buf);
            buf.push((num, line));
            // 保持缓冲区不超过 1000 条
            if buf.len() > 1000 {
                let excess = buf.len() - 1000;
                buf.drain(0..excess);
            }
            Ok(())
        })?;
        globals.set("apiAddPoint", add_point_fn)?;

        // LLCOM API: apiSend(channel, data[, table]) - 多通道发送
        let device_id_clone2 = Arc::clone(&self.device_id);
        let api_send_fn = self.lua.create_function(move |_lua, args: MultiValue| {
            let args_vec: Vec<Value> = args.into_iter().collect();
            if args_vec.len() < 2 {
                return Err(LuaError::RuntimeError("apiSend requires at least 2 arguments".to_string()));
            }
            let channel = match &args_vec[0] {
                Value::String(s) => s.to_str().map(|s| s.to_string()).unwrap_or_default(),
                _ => return Err(LuaError::RuntimeError("apiSend first arg must be string".to_string())),
            };
            let data = match &args_vec[1] {
                Value::String(s) => s.to_str().map(|s| s.to_string()).unwrap_or_default(),
                _ => return Err(LuaError::RuntimeError("apiSend second arg must be string".to_string())),
            };
            // 如果通道是"uart"，走串口发送
            if channel == "uart" {
                let device_id = lock_mutex(&device_id_clone2);
                if device_id.is_empty() {
                    return Err(LuaError::RuntimeError("No device selected".to_string()));
                }
                let bytes = data.into_bytes();
                match debug_send_bytes(device_id.clone(), bytes) {
                    true => Ok(Value::Boolean(true)),
                    false => Err(LuaError::RuntimeError("Failed to send data".to_string())),
                }
            } else {
                // 其他通道暂不处理
                Ok(Value::Boolean(true))
            }
        })?;
        globals.set("apiSend", api_send_fn)?;

        // LLCOM API: apiAscii2Utf8(str) - ASCII 转 UTF-8
        let ascii2utf8_fn = self.lua.create_function(move |_lua, s: String| {
            // 尝试将字符串从 latin-1/ASCII 重新解释为 UTF-8
            Ok(s)
        })?;
        globals.set("apiAscii2Utf8", ascii2utf8_fn)?;

        // LLCOM API: apiInputBox(prompt, default, title) -> string
        // 同步阻塞：Lua 调用后挂起，等待 Dart 端提供输入
        let input_box_fn = self.lua.create_function(move |_lua, args: MultiValue| {
            let args_vec: Vec<Value> = args.into_iter().collect();
            let prompt = match args_vec.get(0) {
                Some(Value::String(s)) => s.to_str().map(|s| s.to_string()).unwrap_or_default(),
                _ => String::new(),
            };
            let default = match args_vec.get(1) {
                Some(Value::String(s)) => s.to_str().map(|s| s.to_string()).unwrap_or_default(),
                _ => String::new(),
            };
            let title = match args_vec.get(2) {
                Some(Value::String(s)) => s.to_str().map(|s| s.to_string()).unwrap_or_default(),
                _ => "Input".to_string(),
            };

            // 创建请求
            let (id, rx) = {
                let mut state = lock_mutex(&INPUT_BOX_STATE);
                let id = state.next_id;
                state.next_id += 1;
                state.pending = Some(InputBoxRequest {
                    id,
                    prompt: prompt.clone(),
                    default_value: default.clone(),
                    title: title.clone(),
                });
                let (tx, rx) = std::sync::mpsc::channel::<String>();
                // 存储 sender 供 Dart 端响应
                lock_mutex(&INPUT_BOX_RESPONSES).insert(id, tx);
                (id, rx)
            };

            // 阻塞等待 Dart 端响应（超时 60 秒）
            match rx.recv_timeout(std::time::Duration::from_secs(60)) {
                Ok(result) => Ok(result),
                Err(_) => {
                    lock_mutex(&INPUT_BOX_RESPONSES).remove(&id);
                    Ok(default)
                }
            }
        })?;
        globals.set("apiInputBox", input_box_fn)?;

        // ==================== 硬件流控制 API ====================
        // apiSerialSetDTR(level) - 设置 DTR 信号
        let device_id_dtr = Arc::clone(&self.device_id);
        let set_dtr_fn = self.lua.create_function(move |_lua, level: bool| {
            let device_id = lock_mutex(&device_id_dtr);
            if device_id.is_empty() {
                return Err(LuaError::RuntimeError("No device selected".to_string()));
            }
            let result = crate::core::app_context::SESSIONS.set_dtr(&device_id, level);
            log::info!("[Lua] apiSerialSetDTR({}) => {}", level, result);
            Ok(result)
        })?;
        globals.set("apiSerialSetDTR", set_dtr_fn)?;

        // apiSerialSetRTS(level) - 设置 RTS 信号
        let device_id_rts = Arc::clone(&self.device_id);
        let set_rts_fn = self.lua.create_function(move |_lua, level: bool| {
            let device_id = lock_mutex(&device_id_rts);
            if device_id.is_empty() {
                return Err(LuaError::RuntimeError("No device selected".to_string()));
            }
            let result = crate::core::app_context::SESSIONS.set_rts(&device_id, level);
            log::info!("[Lua] apiSerialSetRTS({}) => {}", level, result);
            Ok(result)
        })?;
        globals.set("apiSerialSetRTS", set_rts_fn)?;

        // apiSerialGetCTS() - 读取 CTS 信号状态
        let device_id_cts = Arc::clone(&self.device_id);
        let get_cts_fn = self.lua.create_function(move |_lua, _: ()| {
            let device_id = lock_mutex(&device_id_cts);
            if device_id.is_empty() {
                return Err(LuaError::RuntimeError("No device selected".to_string()));
            }
            Ok(crate::core::app_context::SESSIONS.get_cts(&device_id))
        })?;
        globals.set("apiSerialGetCTS", get_cts_fn)?;

        // apiSerialGetDSR() - 读取 DSR 信号状态
        let device_id_dsr = Arc::clone(&self.device_id);
        let get_dsr_fn = self.lua.create_function(move |_lua, _: ()| {
            let device_id = lock_mutex(&device_id_dsr);
            if device_id.is_empty() {
                return Err(LuaError::RuntimeError("No device selected".to_string()));
            }
            Ok(crate::core::app_context::SESSIONS.get_dsr(&device_id))
        })?;
        globals.set("apiSerialGetDSR", get_dsr_fn)?;

        // LLCOM API: apiQuickSendList(id) - 快速发送列表（占位）
        let quick_send_fn = self.lua.create_function(move |_lua, _id: u32| {
            // 目前返回空字符串，待实现完整预设列表管理
            Ok(String::new())
        })?;
        globals.set("apiQuickSendList", quick_send_fn)?;

        // LLCOM API: apiUtf8ToHex(str) - UTF-8 字符串转十六进制
        let utf8_to_hex_fn = self.lua.create_function(move |_lua, s: String| {
            let hex: String = s.bytes().map(|b| format!("{:02X}", b)).collect();
            Ok(hex)
        })?;
        globals.set("apiUtf8ToHex", utf8_to_hex_fn)?;

        // 字符串扩展：toValue - 十六进制转数值
        let to_value_fn = self.lua.create_function(move |_lua, s: String| {
            let hex_clean: String = s.chars().filter(|c| !c.is_whitespace()).collect();
            match u64::from_str_radix(&hex_clean, 16) {
                Ok(v) => Ok(v as f64),
                Err(_) => Err(LuaError::RuntimeError(format!("Invalid hex: {}", s))),
            }
        })?;
        string_table.set("toValue", to_value_fn)?;

        // 字符串扩展：formatNumberThousands - 千分位格式化
        let format_num_fn = self.lua.create_function(move |_lua, n: f64| {
            let formatted = format!("{}", n as i64)
                .chars()
                .rev()
                .enumerate()
                .fold(String::new(), |mut acc, (i, c)| {
                    if i > 0 && i % 3 == 0 { acc.push(','); }
                    acc.push(c);
                    acc
                })
                .chars()
                .rev()
                .collect::<String>();
            Ok(formatted)
        })?;
        string_table.set("formatNumberThousands", format_num_fn)?;

        Ok(())
    }

    /// 加载核心脚本（log 和 sys 和 head）
    fn load_core_scripts(&self) -> LuaResult<()> {
        log::info!("[Lua] Loading core scripts...");

        // 将 log.lua 注册到 package.preload，使 require("log") 可用
        let package_table: Table = self.lua.globals().get("package")?;
        let preload: Table = package_table.get("preload")?;
        log::info!("[Lua] package.preload table ready");

        let log_loader = self.lua.create_function(|lua, ()| {
            log::info!("[Lua] Executing LOG_LUA...");
            let log_value: Table = lua.load(LOG_LUA).eval()?;
            log::info!("[Lua] LOG_LUA executed successfully");
            Ok(log_value)
        })?;
        preload.set("log", log_loader)?;
        log::info!("[Lua] log module registered to preload");

        let sys_loader = self.lua.create_function(|lua, ()| {
            log::info!("[Lua] Executing SYS_LUA...");
            let sys_value: Table = lua.load(SYS_LUA).eval()?;
            log::info!("[Lua] SYS_LUA executed successfully");
            Ok(sys_value)
        })?;
        preload.set("sys", sys_loader)?;
        log::info!("[Lua] sys module registered to preload");

        // 执行 head.lua（它会 require log 和 sys）
        log::info!("[Lua] Executing HEAD_LUA...");
        self.lua.load(HEAD_LUA).exec()?;
        log::info!("[Lua] HEAD_LUA executed successfully");

        Ok(())
    }

    /// 执行 Lua 脚本（crate 内部可见）
    fn execute_script(&self, script: &str) -> LuaResult<()> {
        self.lua.load(script).exec()
    }

    /// 评估 Lua 表达式（crate 内部可见）
    fn eval(&self, code: &str) -> LuaResult<Value> {
        self.lua.load(code).eval()
    }

    /// 触发指定通道的所有回调（crate 内部可见）
    fn trigger_callbacks(&self, channel: &str, data: &[u8]) {
        let callbacks = lock_mutex(&CALLBACKS);
        if let Some(funcs) = callbacks.get(channel) {
            let data_hex = data.iter().map(|b| format!("{:02X}", b)).collect::<String>();
            log::info!("[Lua] RX [{channel}] {len} bytes: {hex}", len = data.len(), hex = data_hex);
            // 将字节数据转为 Lua 字符串
            let data_str = match self.lua.create_string(data) {
                Ok(s) => s,
                Err(e) => {
                    log::error!("[Lua] Failed to create string for callback: {}", e);
                    return;
                }
            };
            for (i, func) in funcs.iter().enumerate() {
                if let Err(e) = func.call::<()>(data_str.clone()) {
                    log::error!("[Lua] Callback #{i} [{channel}] error: {}", e);
                } else {
                    log::info!("[Lua] Callback #{i} [{channel}] OK");
                }
            }
        } else {
            log::warn!("[Lua] No callbacks registered for channel: {}", channel);
        }
    }
}

// 全局 Lua 引擎实例
lazy_static! {
    static ref LUA_ENGINE: Arc<Mutex<Option<LuaEngine>>> = Arc::new(Mutex::new(None));
}

/// 安全获取 LUA_ENGINE 锁，遇到 PoisonError 时重建引擎
fn get_lua_engine() -> MutexGuard<'static, Option<LuaEngine>> {
    match LUA_ENGINE.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            log::warn!("[Lua] LUA_ENGINE was poisoned, re-creating engine...");
            let mut guard = poisoned.into_inner();
            // Poisoned 引擎状态不可靠，重建一个新引擎
            match LuaEngine::new() {
                Ok(e) => {
                    *guard = Some(e);
                    log::info!("[Lua] Engine re-created successfully");
                }
                Err(err) => {
                    log::error!("[Lua] Failed to re-create engine: {}", err);
                }
            }
            guard
        }
    }
}

/// 初始化 Lua 引擎
pub fn init_lua_engine() -> Result<(), String> {
    let mut engine = get_lua_engine();
    if engine.is_none() {
        match LuaEngine::new() {
            Ok(e) => {
                *engine = Some(e);
                Ok(())
            }
            Err(e) => Err(format!("Failed to create Lua engine: {}", e)),
        }
    } else {
        Ok(())
    }
}

/// FFI 接口：执行 Lua 脚本
#[flutter_rust_bridge::frb(sync)]
pub fn lua_execute_script(script: String) -> bool {
    if let Err(e) = init_lua_engine() {
        log::error!("Failed to init Lua engine: {}", e);
        return false;
    }
    let engine = get_lua_engine();
    if let Some(ref e) = *engine {
        match e.execute_script(&script) {
            Ok(_) => true,
            Err(err) => {
                log::error!("Lua script error: {}", err);
                false
            }
        }
    } else {
        false
    }
}

/// FFI 接口：评估 Lua 表达式
#[flutter_rust_bridge::frb(sync)]
pub fn lua_eval(expression: String) -> String {
    if let Err(e) = init_lua_engine() {
        return format!("Failed to init Lua engine: {}", e);
    }
    let engine = get_lua_engine();
    if let Some(ref e) = *engine {
        match e.eval(&expression) {
            Ok(value) => value.to_string().unwrap_or_else(|_| "nil".to_string()),
            Err(err) => format!("Error: {}", err),
        }
    } else {
        "Lua engine not initialized".to_string()
    }
}

/// FFI 接口：设置 Lua 引擎当前设备 ID
#[flutter_rust_bridge::frb(sync)]
pub fn lua_set_device_id(device_id: String) -> bool {
    let mut engine = get_lua_engine();
    if let Some(ref mut e) = *engine {
        e.set_device_id(device_id);
        true
    } else {
        false
    }
}

/// 触发指定通道的 Lua 回调（公共接口，供其他模块调用）
/// 通过 tiggerCB(-1, channel, data) 触发通道回调
pub fn trigger_callback(channel: &str, data: &[u8]) {
    let engine = get_lua_engine();
    if let Some(ref e) = *engine {
        let globals = e.lua.globals();
        if let Ok(tigger_fn) = globals.get::<Function>("tiggerCB") {
            // tiggerCB(id, type, data): id=-1 表示通道回调
            let data_str = match String::from_utf8(data.to_vec()) {
                Ok(s) => s,
                Err(_) => data.iter().map(|b| format!("{:02X}", b)).collect::<Vec<_>>().join(""),
            };
            let args = MultiValue::from_vec(vec![
                Value::Integer(-1),
                Value::String(e.lua.create_string(channel).unwrap_or_else(|_| e.lua.create_string("").unwrap())),
                Value::String(e.lua.create_string(&data_str).unwrap_or_else(|_| e.lua.create_string("").unwrap())),
            ]);
            if let Err(err) = tigger_fn.call::<()>(args) {
                log::error!("[Lua] tiggerCB channel callback error: {}", err);
            }
        } else {
            // 回退到直接调用 Rust 侧回调
            e.trigger_callbacks(channel, data);
        }
    }
}

/// FFI 接口：读取 Lua 日志缓冲区
#[flutter_rust_bridge::frb(sync)]
pub fn lua_get_logs() -> Vec<String> {
    let engine = get_lua_engine();
    if let Some(ref e) = *engine {
        lock_mutex(&e.log_buffer).clone()
    } else {
        Vec::new()
    }
}

/// FFI 接口：清空 Lua 日志缓冲区
#[flutter_rust_bridge::frb(sync)]
pub fn lua_clear_logs() {
    let engine = get_lua_engine();
    if let Some(ref e) = *engine {
        lock_mutex(&e.log_buffer).clear();
    }
}

/// FFI 接口：检查是否有 InputBox 请求
#[flutter_rust_bridge::frb(sync)]
pub fn lua_poll_input_box() -> Option<String> {
    let state = lock_mutex(&INPUT_BOX_STATE);
    if let Some(ref req) = state.pending {
        // 返回 JSON: {"id":1,"prompt":"...","default":"...","title":"..."}
        fn escape(s: &str) -> String {
            s.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n").replace('\r', "\\r")
        }
        Some(format!(
            r#"{{"id":{},"prompt":"{}","default":"{}","title":"{}"}}"#,
            req.id,
            escape(&req.prompt),
            escape(&req.default_value),
            escape(&req.title),
        ))
    } else {
        None
    }
}

/// FFI 接口：响应 InputBox 请求
#[flutter_rust_bridge::frb(sync)]
pub fn lua_respond_input_box(id: u64, value: String) -> bool {
    // 清除 pending
    {
        let mut state = lock_mutex(&INPUT_BOX_STATE);
        if let Some(ref req) = state.pending {
            if req.id == id {
                state.pending = None;
            }
        }
    }
    // 发送响应
    let mut responses = lock_mutex(&INPUT_BOX_RESPONSES);
    if let Some(tx) = responses.remove(&id) {
        tx.send(value).is_ok()
    } else {
        false
    }
}

/// 脚本目录路径（exe 同路径下的 scripts 目录）
fn get_scripts_dir() -> std::path::PathBuf {
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_path_buf()))
        .unwrap_or_else(|| std::path::PathBuf::from("."));
    exe_dir.join("scripts")
}

/// FFI 接口：获取脚本列表
#[flutter_rust_bridge::frb(sync)]
pub fn lua_get_scripts_list() -> Vec<String> {
    let dir = get_scripts_dir();
    if !dir.exists() {
        if let Err(e) = std::fs::create_dir_all(&dir) {
            log::warn!("Failed to create scripts dir: {}", e);
            return Vec::new();
        }
    }
    // 读取 .lua 文件
    let mut scripts = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map_or(false, |ext| ext == "lua") {
                if let Some(name) = path.file_stem() {
                    scripts.push(name.to_string_lossy().to_string());
                }
            }
        }
    }
    scripts.sort();
    scripts
}

/// FFI 接口：加载脚本内容
#[flutter_rust_bridge::frb(sync)]
pub fn lua_load_script(name: String) -> String {
    let dir = get_scripts_dir();
    let path = dir.join(format!("{}.lua", name));
    std::fs::read_to_string(&path).unwrap_or_else(|e| {
        log::error!("Failed to load script {}: {}", name, e);
        String::new()
    })
}

/// FFI 接口：保存脚本内容
#[flutter_rust_bridge::frb(sync)]
pub fn lua_save_script(name: String, content: String) -> bool {
    let dir = get_scripts_dir();
    if !dir.exists() {
        if let Err(e) = std::fs::create_dir_all(&dir) {
            log::error!("Failed to create scripts dir: {}", e);
            return false;
        }
    }
    let path = dir.join(format!("{}.lua", name));
    std::fs::write(&path, content).is_ok()
}

/// FFI 接口：删除脚本
#[flutter_rust_bridge::frb(sync)]
pub fn lua_delete_script(name: String) -> bool {
    let dir = get_scripts_dir();
    let path = dir.join(format!("{}.lua", name));
    if path.exists() {
        std::fs::remove_file(&path).is_ok()
    } else {
        true
    }
}

/// FFI 接口：打开脚本目录
#[flutter_rust_bridge::frb(sync)]
pub fn lua_open_scripts_folder() -> bool {
    let dir = get_scripts_dir();
    if !dir.exists() {
        if let Err(e) = std::fs::create_dir_all(&dir) {
            log::error!("Failed to create scripts dir: {}", e);
            return false;
        }
    }
    // 使用系统命令打开文件夹
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .arg(dir)
            .spawn()
            .is_ok()
    }
    #[cfg(not(target_os = "windows"))]
    {
        std::process::Command::new("xdg-open")
            .arg(&dir)
            .spawn()
            .is_ok()
    }
}

/// 定时器到期时调用 Lua 的 tiggerCB(timerId)
fn fire_sys_timer(timer_id: u32) {
    let engine = get_lua_engine();
    if let Some(ref e) = *engine {
        let globals = e.lua.globals();
        if let Ok(tigger_fn) = globals.get::<Function>("tiggerCB") {
            // tiggerCB(id, type, data): id>=0 表示定时器
            let args = MultiValue::from_vec(vec![
                Value::Integer(timer_id as i64),
                Value::String(e.lua.create_string("").unwrap_or_else(|_| e.lua.create_string("").unwrap())),
                Value::Nil,
            ]);
            if let Err(err) = tigger_fn.call::<()>(args) {
                log::error!("[Lua] tiggerCB timer error: {}", err);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lua_engine_creation() {
        let engine = LuaEngine::new().unwrap();
        // 能成功创建就通过
    }

    #[test]
    fn test_execute_script() {
        let engine = LuaEngine::new().unwrap();
        let result = engine.execute_script("print('Hello from Lua!')");
        assert!(result.is_ok(), "Lua script execution failed: {:?}", result);
    }

    #[test]
    fn test_eval_expression() {
        let engine = LuaEngine::new().unwrap();
        let value = engine.eval("1 + 2").unwrap();
        let s = value.to_string().unwrap();
        assert!(s.contains("3"), "Expected 3, got {}", s);
    }

    #[test]
    fn test_string_to_hex() {
        let engine = LuaEngine::new().unwrap();
        let value = engine.eval("string.toHex('abc')").unwrap();
        let s = value.to_string().unwrap();
        assert!(s.contains("616263"), "Expected 616263, got {}", s);
    }

    #[test]
    fn test_string_from_hex() {
        let engine = LuaEngine::new().unwrap();
        let value = engine.eval("string.fromHex('616263')").unwrap();
        let s = value.to_string().unwrap();
        assert!(s.contains("abc"), "Expected abc, got {}", s);
    }

    #[test]
    fn test_string_split() {
        let engine = LuaEngine::new().unwrap();
        // split 返回 Lua table，用 # 获取长度
        let value = engine.eval("#string.split('a,b,c', ',')").unwrap();
        let s = value.to_string().unwrap();
        assert!(s.contains("3"), "Expected 3 elements, got {}", s);
    }

    #[test]
    fn test_string_url_encode() {
        let engine = LuaEngine::new().unwrap();
        let value = engine.eval("string.urlEncode('hello world')").unwrap();
        let s = value.to_string().unwrap();
        assert!(s.contains("hello%20world"), "Expected encoded, got {}", s);
    }

    #[test]
    fn test_string_to_value() {
        let engine = LuaEngine::new().unwrap();
        let value = engine.eval("string.toValue('FF')").unwrap();
        let s = value.to_string().unwrap();
        assert!(s.contains("255"), "Expected 255, got {}", s);
    }

    #[test]
    fn test_string_utf8_len() {
        let engine = LuaEngine::new().unwrap();
        let value = engine.eval("string.utf8Len('你好')").unwrap();
        let s = value.to_string().unwrap();
        assert!(s.contains("2"), "Expected 2, got {}", s);
    }

    #[test]
    fn test_format_number_thousands() {
        let engine = LuaEngine::new().unwrap();
        let value = engine.eval("string.formatNumberThousands(1234567)").unwrap();
        let s = value.to_string().unwrap();
        assert!(s.contains("1,234,567"), "Expected 1,234,567, got {}", s);
    }

    #[test]
    fn test_log_module_loaded() {
        let engine = LuaEngine::new().unwrap();
        // log 模块应该已自动加载
        let value = engine.eval("log.info").unwrap();
        assert!(matches!(value, Value::Function(_)), "log.info should be a function");
    }

    #[test]
    fn test_sys_module_loaded() {
        let engine = LuaEngine::new().unwrap();
        // sys 模块应该已自动加载
        let value = engine.eval("sys.timerStart").unwrap();
        assert!(matches!(value, Value::Function(_)), "sys.timerStart should be a function");
    }

    #[test]
    fn test_tiggercb_defined() {
        let engine = LuaEngine::new().unwrap();
        // tiggerCB 全局函数应该已定义
        let value = engine.eval("tiggerCB").unwrap();
        assert!(matches!(value, Value::Function(_)), "tiggerCB should be a function");
    }

    #[test]
    fn test_flow_control_api_exists() {
        let engine = LuaEngine::new().unwrap();
        // 流控制 API 应该已注册
        let dtr: Value = engine.eval("apiSerialSetDTR").unwrap();
        assert!(matches!(dtr, Value::Function(_)), "apiSerialSetDTR should be a function");
        let rts: Value = engine.eval("apiSerialSetRTS").unwrap();
        assert!(matches!(rts, Value::Function(_)), "apiSerialSetRTS should be a function");
        let cts: Value = engine.eval("apiSerialGetCTS").unwrap();
        assert!(matches!(cts, Value::Function(_)), "apiSerialGetCTS should be a function");
        let dsr: Value = engine.eval("apiSerialGetDSR").unwrap();
        assert!(matches!(dsr, Value::Function(_)), "apiSerialGetDSR should be a function");
    }
}
