// Device API - 设备管理接口
// 提供设备增删改查、连接控制、串口扫描等功能

use crate::core::app_context::{DEBUG, REGISTRY, SESSIONS};
use crate::core::device::models::{
    all_protocols, ConnectionType, DataBits, DeviceConfig, DeviceInfo, FlowControl, Parity,
    PortInfo, Protocol, StopBits,
};
use crate::core::device::preset::{demo_presets, all_virtual_presets};
use crate::core::protocol::{CsvParser, parse_csv_line};
use crate::core::transport::serial;
use crate::api::debug_api::{start_receive_loop_if_needed, stop_receive_loop};
use std::path::PathBuf;
use serde::{Deserialize, Serialize};

// ============================================================================
// 协议与设备列表
// ============================================================================

/// 获取所有支持的协议
#[flutter_rust_bridge::frb(sync)]
pub fn get_supported_protocols() -> Vec<String> {
    all_protocols().into_iter().map(|p| p.label).collect()
}

/// 获取所有设备列表
#[flutter_rust_bridge::frb(sync)]
pub fn list_devices() -> Vec<DeviceInfo> {
    REGISTRY.all()
}

/// 获取单个设备信息
#[flutter_rust_bridge::frb(sync)]
pub fn get_device(device_id: String) -> Option<DeviceInfo> {
    REGISTRY.get(&device_id)
}

// ============================================================================
// 设备创建
// ============================================================================

/// 添加串口设备
/// address 格式: port:baudRate:dataBits:stopBits:parity:flowControl:receiveTimeoutMs:dtr:rts:bk
#[flutter_rust_bridge::frb(sync)]
pub fn add_serial_device(
    name: String,
    port: String,
    baud_rate: u32,
    protocol: Protocol,
    data_bits: DataBits,
    stop_bits: StopBits,
    parity: Parity,
    flow_control: FlowControl,
    receive_timeout_ms: u64,
    dtr_enabled: bool,
    rts_enabled: bool,
    break_enabled: bool,
) -> DeviceInfo {
    let db = data_bits;
    let sb = stop_bits;
    let par = parity;
    let fc = flow_control;
    let proto = protocol;
    
    // 构建地址字符串 (扩展格式包含 dtr:rts:bk)
    let address = format!(
        "{}:{}:{}:{}:{}:{}:{}:{}:{}:{}",
        port, baud_rate,
        match db { DataBits::Five => "5", DataBits::Six => "6", DataBits::Seven => "7", DataBits::Eight => "8" },
        match sb { StopBits::One => "1", StopBits::Two => "2" },
        match par { Parity::None => "N", Parity::Odd => "O", Parity::Even => "E" },
        match fc { FlowControl::None => "N", FlowControl::Hardware => "H", FlowControl::Software => "S" },
        receive_timeout_ms,
        if dtr_enabled { "1" } else { "0" },
        if rts_enabled { "1" } else { "0" },
        if break_enabled { "1" } else { "0" }
    );

    let config = DeviceConfig {
        name,
        device_type: "SerialDevice".into(),
        connection_type: ConnectionType::Serial,
        address,
        protocol: proto,
        is_virtual: false,
        server_info: None,
    };
    
    let id = REGISTRY.add(config);
    REGISTRY.get(&id).unwrap()
}

/// 添加 TCP 设备
#[flutter_rust_bridge::frb(sync)]
pub fn add_tcp_device(
    name: String,
    host: String,
    port: u16,
    protocol: Protocol,
) -> DeviceInfo {
    let proto = protocol;
    let address = format!("{}:{}", host, port);
    
    let config = DeviceConfig {
        name,
        device_type: "TcpDevice".into(),
        connection_type: ConnectionType::Tcp,
        address,
        protocol: proto,
        is_virtual: false,
        server_info: None,
    };
    
    let id = REGISTRY.add(config);
    REGISTRY.get(&id).unwrap()
}

// ============================================================================
// 设备更新与删除
// ============================================================================

/// 更新设备配置
#[flutter_rust_bridge::frb]
pub async fn update_device(
    device_id: String,
    name: String,
    address: String,
    protocol: Protocol,
) -> bool {
    let proto = protocol;
    
    // 如果设备已连接，先断开
    if SESSIONS.is_connected_sync(&device_id) {
        let _ = SESSIONS.disconnect(&device_id).await;
        DEBUG.mark_disconnected(&device_id);
        stop_receive_loop(&device_id);
    }
    
    REGISTRY.update(&device_id, name, address, proto)
}

/// 删除设备
#[flutter_rust_bridge::frb]
pub async fn remove_device(device_id: String) -> bool {
    // 如果设备已连接，先断开
    if SESSIONS.is_connected_sync(&device_id) {
        let _ = SESSIONS.disconnect(&device_id).await;
        DEBUG.mark_disconnected(&device_id);
        stop_receive_loop(&device_id);
    }
    
    REGISTRY.remove(&device_id)
}

// ============================================================================
// 串口扫描
// ============================================================================

/// 串口扫描（带缓存，纯 Rust serialport crate 实现）
#[flutter_rust_bridge::frb(sync)]
pub fn scan_serial_ports() -> Vec<PortInfo> {
    serial::scan_serial_ports()
        .into_iter()
        .map(|(name, description, is_virtual)| PortInfo {
            name,
            port_type: if is_virtual { "Virtual".into() } else { "Physical".into() },
            description,
            is_virtual,
        })
        .collect()
}

// ============================================================================
// 连接控制（添加详细日志，输出到 stderr 方便捕获）
// ============================================================================

/// 连接设备 (专家调试版本：添加详细日志到 stderr)
#[flutter_rust_bridge::frb]
pub async fn connect_device(device_id: String) -> bool {
    // 专家调试：记录每一步到 stderr（方便捕获）
    eprintln!("🧪 [DEBUG] connect_device() 开始");
    eprintln!("   - device_id: {}", device_id);
    
    // 1. 连接设备
    eprintln!("🧪 [DEBUG] 步骤 1: 调用 SESSIONS.connect()");
    let connect_result = SESSIONS.connect(&device_id).await;
    eprintln!("🧪 [DEBUG] 步骤 1 完成，结果: {:?}", connect_result.is_ok());
    
    match connect_result {
        Ok(_) => {
            eprintln!("🧪 [DEBUG] 步骤 2: 标记设备为已连接");
            DEBUG.mark_connected(&device_id);
            
            eprintln!("🧪 [DEBUG] 步骤 3: 启动接收循环");
            start_receive_loop_if_needed(&device_id);
            eprintln!("🧪 [DEBUG] 步骤 3 完成");
            
            // 连接成功后应用保存的硬件流控制设置 (从设备地址中解析)
            eprintln!("🧪 [DEBUG] 步骤 4: 应用硬件流控制设置");
            if let Some(device) = REGISTRY.get(&device_id) {
                let address = device.address.clone();
                let parts: Vec<&str> = address.split(':').collect();
                
                if parts.len() >= 10 {
                    eprintln!("🧪 [DEBUG] 步骤 4a: 解析硬件流控制设置");
                    eprintln!("   - DTR: {}", parts[7]);
                    eprintln!("   - RTS: {}", parts[8]);
                    eprintln!("   - BREAK: {}", parts[9]);
                    
                    if parts[7] == "1" { 
                        eprintln!("🧪 [DEBUG] 步骤 4b: 设置 DTR");
                        let _ = SESSIONS.set_dtr(&device_id, true); 
                    }
                    if parts[8] == "1" { 
                        eprintln!("🧪 [DEBUG] 步骤 4c: 设置 RTS");
                        let _ = SESSIONS.set_rts(&device_id, true); 
                    }
                    if parts[9] == "1" { 
                        eprintln!("🧪 [DEBUG] 步骤 4d: 设置 BREAK");
                        let _ = SESSIONS.set_break(&device_id); 
                    }
                }
            }
            eprintln!("🧪 [DEBUG] 步骤 4 完成");
            
            eprintln!("🧪 [DEBUG] connect_device() 成功完成");
            true
        }
        Err(e) => {
            eprintln!("🧪 [DEBUG] connect_device() 失败: {:?}", e);
            DEBUG.log_error(&device_id, &format!("Connect error: {:?}", e));
            false
        }
    }
}

/// 断开设备
#[flutter_rust_bridge::frb]
pub async fn disconnect_device(device_id: String) -> bool {
    match SESSIONS.disconnect(&device_id).await {
        Ok(_) => {
            DEBUG.mark_disconnected(&device_id);
            stop_receive_loop(&device_id);
            true
        }
        Err(e) => {
            DEBUG.log_error(&device_id, &format!("Disconnect error: {:?}", e));
            false
        }
    }
}

/// 查询设备是否已连接
#[flutter_rust_bridge::frb(sync)]
pub fn is_device_connected(device_id: String) -> bool {
    SESSIONS.is_connected_sync(&device_id)
}

// ============================================================================
// 串口硬件流控制（DTR/RTS/Break）
// ============================================================================

/// 设置 DTR 信号
#[flutter_rust_bridge::frb(sync)]
pub fn serial_set_dtr(device_id: String, level: bool) -> bool {
    SESSIONS.set_dtr(&device_id, level)
}

/// 设置 RTS 信号
#[flutter_rust_bridge::frb(sync)]
pub fn serial_set_rts(device_id: String, level: bool) -> bool {
    SESSIONS.set_rts(&device_id, level)
}

/// 设置 Break 信号（开始发送 Break）
#[flutter_rust_bridge::frb(sync)]
pub fn serial_set_break(device_id: String) -> bool {
    SESSIONS.set_break(&device_id)
}

/// 清除 Break 信号（停止发送 Break）
#[flutter_rust_bridge::frb(sync)]
pub fn serial_clear_break(device_id: String) -> bool {
    SESSIONS.clear_break(&device_id)
}

// ============================================================================
// 演示设备
// ============================================================================

/// 加载演示设备（用于 UI 展示）
#[flutter_rust_bridge::frb(sync)]
pub fn load_demo_devices() {
    for config in demo_presets() {
        REGISTRY.add(config);
    }
}

/// 加载虚拟设备（TCP-SCPI-Demo, Serial-SCPI-Demo）
#[flutter_rust_bridge::frb(sync)]
pub fn load_virtual_devices() {
    for (id, config) in all_virtual_presets() {
        // 只添加不存在的设备
        if REGISTRY.get(&id).is_none() {
            REGISTRY.add_with_id(id, config);
        }
    }
}

/// 清除演示设备
#[flutter_rust_bridge::frb]
pub async fn clear_demo_devices() {
    // 断开并删除所有非虚拟设备
    let devices = REGISTRY.all();
    for d in devices {
        if !d.is_virtual {
            if SESSIONS.is_connected_sync(&d.id) {
                let _ = SESSIONS.disconnect(&d.id).await;
                DEBUG.mark_disconnected(&d.id);
                stop_receive_loop(&d.id);
            }
            REGISTRY.remove(&d.id);
        }
    }
}

// ============================================================================
// 设备持久化
// ============================================================================

/// 保存设备到 JSON 文件
#[flutter_rust_bridge::frb(sync)]
pub fn save_devices() {
    let path = get_persistence_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    
    let devices: Vec<_> = REGISTRY.all()
        .into_iter()
        .filter(|d| !d.is_virtual)
        .map(|d| PersistedDevice {
            name: d.name.clone(),
            connection_type: format!("{:?}", d.connection_type),
            address: d.address.clone(),
            protocol: format!("{:?}", d.protocol),
            flow_control: None,
            dtr_enabled: None,
            rts_enabled: None,
        })
        .collect();
    
    if let Ok(json) = serde_json::to_string_pretty(&devices) {
        let _ = std::fs::write(&path, json);
    }
}

/// 从 JSON 文件加载设备，返回加载的设备数量
#[flutter_rust_bridge::frb(sync)]
pub fn load_persisted_devices() -> i32 {
    let path = get_persistence_path();
    if !path.exists() {
        return 0;
    }
    
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return 0,
    };
    
    let devices: Vec<PersistedDevice> = match serde_json::from_str(&content) {
        Ok(d) => d,
        Err(_) => return 0,
    };
    
    let mut count = 0;
    for pd in devices {
        let proto = parse_protocol(&pd.protocol);
        let conn_type = parse_connection_type(&pd.connection_type);
        
        let config = DeviceConfig {
            name: pd.name,
            device_type: match conn_type {
                ConnectionType::Serial => "SerialDevice".into(),
                ConnectionType::Tcp => "TcpDevice".into(),
                _ => "UnknownDevice".into(),
            },
            connection_type: conn_type,
            address: pd.address,
            protocol: proto,
            is_virtual: false,
            server_info: None,
        };
        
        REGISTRY.add(config);
        count += 1;
    }
    
    count
}

/// 获取持久化文件路径（%APPDATA%\instrument_upper_computer\devices.json）
fn get_persistence_path() -> PathBuf {
    let base = dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("VCR").join("devices.json")
}

// ============================================================================
// CSV 协议解析
// ============================================================================

/// 解析 CSV 协议数据行，返回通道值数组
/// 返回 JSON 字符串以便 FRB 支持
#[flutter_rust_bridge::frb(sync)]
pub fn parse_csv_data(line: String) -> Option<String> {
    let result = parse_csv_line(&line);
    if result.success {
        serde_json::to_string(&result).ok()
    } else {
        None
    }
}

/// 批量解析 CSV 数据（多行），返回每行的通道值数组
#[flutter_rust_bridge::frb(sync)]
pub fn parse_csv_batch(data: String) -> Vec<Vec<f64>> {
    let mut parser = CsvParser::new();
    parser.parse_bytes(data.as_bytes())
}

// ============================================================================
// 辅助函数
// ============================================================================

fn parse_protocol(s: &str) -> Protocol {
    match s.to_lowercase().as_str() {
        "raw" => Protocol::Raw,
        "modbusrtu" | "modbus rtu" => Protocol::ModbusRtu,
        "modbustcp" | "modbus tcp" => Protocol::ModbusTcp,
        "scpi" => Protocol::Scpi,
        "csv" => Protocol::Csv,
        "private" => Protocol::Private,
        _ => Protocol::Raw,
    }
}

fn parse_connection_type(s: &str) -> ConnectionType {
    match s.to_lowercase().as_str() {
        "serial" => ConnectionType::Serial,
        "tcp" => ConnectionType::Tcp,
        "usb" => ConnectionType::Usb,
        "ble" => ConnectionType::Ble,
        "wifi" => ConnectionType::Wifi,
        _ => ConnectionType::Serial,
    }
}

/// 用于持久化的设备结构
#[derive(Serialize, Deserialize)]
struct PersistedDevice {
    name: String,
    connection_type: String,
    address: String,
    protocol: String,
    flow_control: Option<String>,    // "N", "H", "S"
    dtr_enabled: Option<bool>,       // DTR 信号状态
    rts_enabled: Option<bool>,       // RTS 信号状态
}
