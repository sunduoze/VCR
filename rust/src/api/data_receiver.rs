// rust/src/core/data_receiver.rs
// 独立线程 + 双缓冲 数据接收器（方案3实现）

use std::thread;
use std::sync::Mutex;
use once_cell::sync::Lazy;

/// 接收器运行状态
static RUNNING: Lazy<Mutex<bool>> = Lazy::new(|| Mutex::new(false));

/// 启动独立线程接收数据
#[flutter_rust_bridge::frb(sync)]
pub fn start_data_receiver() {
    let mut running = RUNNING.lock().unwrap();
    if *running {
        return;  // 已经在运行
    }
    *running = true;
    
    thread::spawn(|| {
        let mut count = 0;
        loop {
            // 检查是否应该停止
            if !*RUNNING.lock().unwrap() {
                break;
            }
            
            // 模拟数据生成（实际应该从串口/Socket读取）
            for ch_idx in 0..4 {
                let ch_name = format!("ch{}", ch_idx);
                let mut data = Vec::new();
                for i in 0..1000 {
                    let t = (count * 1000 + i) as f64 / 1000.0;
                    data.push((2.0 * std::f64::consts::PI * 1000.0 * t).sin());
                }
                // 推送到 PlotDataManager
                crate::core::plot::data_buffer::PLOT_DATA
                    .push_batch_with_names(&"device1".to_string(), count as f64, Some(&ch_name), &data);
            }
            
            count += 1;
            
            // 20ms 间隔（50Hz）
            thread::sleep(std::time::Duration::from_millis(20));
        }
    });
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
