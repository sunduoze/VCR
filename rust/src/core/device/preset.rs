use crate::core::device::models::{ConnectionType, DeviceConfig, Protocol};

/// 虚拟设备固定 UUID
pub const VIRTUAL_TCP_SCPI_UUID: &str = "00000001-0000-0000-0000-000000000001";
pub const VIRTUAL_SERIAL_COM1_UUID: &str = "00000001-0000-0000-0000-000000000002";

/// 创建 TCP-SCPI-Demo 虚拟设备配置
pub fn tcp_scpi_demo() -> (String, DeviceConfig) {
    (
        VIRTUAL_TCP_SCPI_UUID.to_string(),
        DeviceConfig {
            name: "TCP-SCPI-Demo".into(),
            device_type: "Virtual Instrument".into(),
            connection_type: ConnectionType::Tcp,
            address: "127.0.0.1:5025".into(),
            protocol: Protocol::Scpi,
            is_virtual: true,
            server_info: Some("TCP Server: 127.0.0.1:5025".into()),
        },
    )
}

/// 创建虚拟串口 COM1 设备配置
pub fn serial_com1_demo() -> (String, DeviceConfig) {
    (
        VIRTUAL_SERIAL_COM1_UUID.to_string(),
        DeviceConfig {
            name: "Serial-SCPI-Demo".into(),
            device_type: "Virtual Instrument".into(),
            connection_type: ConnectionType::Serial,
            address: "COM1:9600".into(),
            protocol: Protocol::Scpi,
            is_virtual: true,
            server_info: Some("Virtual Serial: COM1 ↔ COM2 (Backend)".into()),
        },
    )
}

/// 所有虚拟设备预设
pub fn all_virtual_presets() -> Vec<(String, DeviceConfig)> {
    vec![tcp_scpi_demo(), serial_com1_demo()]
}

/// Demo 设备预设（非虚拟，用于演示 UI）
pub fn demo_presets() -> Vec<DeviceConfig> {
    vec![
        DeviceConfig {
            name: "温度采集仪 #1".into(),
            device_type: "TempSensor".into(),
            connection_type: ConnectionType::Serial,
            address: "COM3:9600".into(),
            protocol: Protocol::ModbusRtu,
            is_virtual: false,
            server_info: None,
        },
        DeviceConfig {
            name: "压力变送器 #2".into(),
            device_type: "PressureSensor".into(),
            connection_type: ConnectionType::Serial,
            address: "COM7:115200".into(),
            protocol: Protocol::ModbusRtu,
            is_virtual: false,
            server_info: None,
        },
        DeviceConfig {
            name: "数据记录仪 #3".into(),
            device_type: "DataLogger".into(),
            connection_type: ConnectionType::Tcp,
            address: "192.168.1.101:502".into(),
            protocol: Protocol::ModbusTcp,
            is_virtual: false,
            server_info: None,
        },
        DeviceConfig {
            name: "PLC 控制器 #4".into(),
            device_type: "PLC".into(),
            connection_type: ConnectionType::Tcp,
            address: "192.168.1.200:102".into(),
            protocol: Protocol::Private,
            is_virtual: false,
            server_info: None,
        },
        DeviceConfig {
            name: "无线传感器 #5".into(),
            device_type: "WirelessSensor".into(),
            connection_type: ConnectionType::Wifi,
            address: "192.168.1.88:8080".into(),
            protocol: Protocol::Raw,
            is_virtual: false,
            server_info: None,
        },
        DeviceConfig {
            name: "USB 示波器 #6".into(),
            device_type: "Oscilloscope".into(),
            connection_type: ConnectionType::Usb,
            address: "USB\\VID_0483&PID_5740".into(),
            protocol: Protocol::Scpi,
            is_virtual: false,
            server_info: None,
        },
        DeviceConfig {
            name: "BLE 心率计 #7".into(),
            device_type: "HeartRateMonitor".into(),
            connection_type: ConnectionType::Ble,
            address: "AA:BB:CC:DD:EE:FF".into(),
            protocol: Protocol::Private,
            is_virtual: false,
            server_info: None,
        },
    ]
}
