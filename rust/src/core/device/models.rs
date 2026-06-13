use serde::{Deserialize, Serialize};

/// 连接类型
#[derive(Clone, Debug, Serialize, Deserialize, Copy, PartialEq)]
pub enum ConnectionType {
    Serial,
    Tcp,
    Usb,
    Ble,
    Wifi,
}

/// 设备状态
#[derive(Clone, Debug, Serialize, Deserialize, Copy, PartialEq)]
pub enum DeviceStatus {
    Disconnected,
    Connecting,
    Connected,
    Error,
}

/// 通信协议
#[derive(Clone, Debug, Serialize, Deserialize, Copy, PartialEq)]
pub enum Protocol {
    Raw,
    ModbusRtu,
    ModbusTcp,
    Scpi,
    Csv,
    Private,
}

/// 设备配置（创建设备时使用，不变）
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeviceConfig {
    pub name: String,
    pub device_type: String,
    pub connection_type: ConnectionType,
    pub address: String,
    pub protocol: Protocol,
    pub is_virtual: bool,
    pub server_info: Option<String>,
}

/// 设备运行时信息（可变状态）
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeviceRuntime {
    pub status: DeviceStatus,
    pub last_seen: Option<String>,
    pub error_message: Option<String>,
}

/// 设备完整信息 = 配置 + 运行时状态（对外暴露的统一模型）
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeviceInfo {
    pub id: String,
    // 配置部分
    pub name: String,
    pub device_type: String,
    pub connection_type: ConnectionType,
    pub address: String,
    pub protocol: Protocol,
    pub is_virtual: bool,
    pub server_info: Option<String>,
    // 运行时部分
    pub status: DeviceStatus,
    pub last_seen: Option<String>,
    pub error_message: Option<String>,
}

impl DeviceInfo {
    /// 从配置创建（运行时状态初始化为 Disconnected）
    pub fn from_config(id: String, config: DeviceConfig) -> Self {
        Self {
            id,
            name: config.name,
            device_type: config.device_type,
            connection_type: config.connection_type,
            address: config.address,
            protocol: config.protocol,
            is_virtual: config.is_virtual,
            server_info: config.server_info,
            status: DeviceStatus::Disconnected,
            last_seen: None,
            error_message: None,
        }
    }
}

/// 串口信息（用于 UI 显示）
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PortInfo {
    pub name: String,
    pub port_type: String,
    pub description: String,
    pub is_virtual: bool,
}

/// 数据位
#[derive(Clone, Debug, Serialize, Deserialize, Copy, PartialEq)]
pub enum DataBits {
    Five,
    Six,
    Seven,
    Eight,
}

/// 停止位
#[derive(Clone, Debug, Serialize, Deserialize, Copy, PartialEq)]
pub enum StopBits {
    One,
    Two,
}

/// 校验位
#[derive(Clone, Debug, Serialize, Deserialize, Copy, PartialEq)]
pub enum Parity {
    None,
    Odd,
    Even,
}

/// 流控
#[derive(Clone, Debug, Serialize, Deserialize, Copy, PartialEq)]
pub enum FlowControl {
    None,
    Hardware,
    Software,
}

/// 串口完整配置信息（用于 FRB 桥接）
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SerialConfigInfo {
    pub data_bits: DataBits,
    pub stop_bits: StopBits,
    pub parity: Parity,
    pub flow_control: FlowControl,
}

/// 协议信息（用于 UI 显示）
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProtocolInfo {
    pub value: Protocol,
    pub label: String,
    pub description: String,
}

/// 所有支持的协议
pub fn all_protocols() -> Vec<ProtocolInfo> {
    vec![
        ProtocolInfo {
            value: Protocol::Raw,
            label: "Raw / 无协议".into(),
            description: "原始数据流，无协议封装".into(),
        },
        ProtocolInfo {
            value: Protocol::ModbusRtu,
            label: "Modbus RTU".into(),
            description: "串口Modbus RTU协议".into(),
        },
        ProtocolInfo {
            value: Protocol::ModbusTcp,
            label: "Modbus TCP".into(),
            description: "网络Modbus TCP协议".into(),
        },
        ProtocolInfo {
            value: Protocol::Scpi,
            label: "SCPI".into(),
            description: "标准仪器命令协议".into(),
        },
        ProtocolInfo {
            value: Protocol::Csv,
            label: "CSV / 自定义协议".into(),
            description: "CSV格式数据解析，支持自定义前缀".into(),
        },
        ProtocolInfo {
            value: Protocol::Private,
            label: "私有协议".into(),
            description: "自定义私有协议".into(),
        },
    ]
}
