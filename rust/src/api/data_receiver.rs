// rust/src/core/data_receiver.rs
// 独立线程 + 双缓冲 数据接收器（方案3实现）

use once_cell::sync::Lazy;
use std::sync::Mutex;
use std::thread;

/// 接收器运行状态
static RUNNING: Lazy<Mutex<bool>> = Lazy::new(|| Mutex::new(false));

/// 启动独立线程接收数据
#[flutter_rust_bridge::frb(sync)]
pub fn start_data_receiver() {
    // TEMP: no-op for memory diagnosis
    return;
}

/// 停止数据接收器
#[flutter_rust_bridge::frb(sync)]
pub fn stop_data_receiver() {
    let mut running = RUNNING.lock().unwrap();
    *running = false;
}

/// 检查数据接收器是否在运行
#[flutter_rust_bridge::frb(sync)]
pub fn is_data_receiver_running() -> bool {
    *RUNNING.lock().unwrap()
}
