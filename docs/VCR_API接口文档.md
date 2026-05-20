# VCR (Virtual Instrument Control Application) API 接口文档

**版本**: 1.0  
**日期**: 2026-05-18  
**作者**: API文档生成器

---

## 目录

1. [文档概述](#1-文档概述)
2. [Rust 核心 API](#2-rust-核心-api)
   - 2.1 设备管理 API (device_api)
   - 2.2 调试控制台 API (debug_api)
   - 2.3 Lua 脚本 API (lua_api)
   - 2.4 绘图 API (plot_api)
   - 2.5 虚拟设备 API (virtual_api)
3. [Dart/Flutter API](#3-dartflutter-api)
   - 3.1 设备管理 API (device_api.dart)
   - 3.2 调试控制台 API (debug_api.dart)
   - 3.3 Lua 脚本 API (lua_api.dart)
   - 3.4 绘图 API (plot_api.dart)
4. [API 使用示例](#4-api-使用示例)
5. [错误处理](#5-错误处理)
6. [附录](#6-附录)

---

## 1. 文档概述

本文档描述 VCR 项目的完整 API 接口，包括：
- **Rust 核心 API**: 底层业务逻辑接口（使用 `flutter_rust_bridge` 导出）
- **Dart/Flutter API**: Flutter 端调用的接口封装

所有 API 都通过 `flutter_rust_bridge` 自动生成 Dart 绑定，类型安全且支持异步调用。

### 1.1 API 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Flutter/Dart 应用                       │
│  (调用 Dart API → 自动生成 FFI 绑定)                       │
└────────────────────┬────────────────────────────────────────┘
                     │ FFI (Foreign Function Interface)
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                   Rust 核心库                               │
│  (业务逻辑、协议处理、设备控制)                              │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│               硬件设备 / 虚拟设备                            │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 命名约定

- **Rust 函数**: `snake_case` (例如: `list_devices`)
- **Dart 函数**: `camelCase` (例如: `listDevices`)
- **异步函数**: Dart 端返回 `Future<T>`
- **同步函数**: Dart 端直接返回 `T`

---

## 2. Rust 核心 API

### 2.1 设备管理 API (device_api)

**文件位置**: `rust/src/api/device_api.rs`

#### 2.1.1 获取支持的协议

```rust
/// 获取所有支持的协议标签
#[flutter_rust_bridge::frb(sync)]
pub fn get_supported_protocols() -> Vec<String>
```

**返回值**:
- `Vec<String>`: 协议标签列表，例如 `["Raw / 无协议", "Modbus RTU", "SCPI", ...]`

**示例**:
```rust
let protocols = get_supported_protocols();
println!("{:?}", protocols);
// ["Raw / 无协议", "Modbus RTU", "Modbus TCP", "SCPI", "CSV / 自定义协议", "私有协议"]
```

---

#### 2.1.2 获取设备列表

```rust
/// 获取所有已注册的设备信息
#[flutter_rust_bridge::frb(sync)]
pub fn list_devices() -> Vec<DeviceInfo>
```

**返回值**:
- `Vec<DeviceInfo>`: 设备信息列表

**DeviceInfo 结构**:
```rust
pub struct DeviceInfo {
    pub id: String,                      // 设备唯一 ID
    pub name: String,                    // 设备名称
    pub device_type: String,            // 设备类型
    pub connection_type: ConnectionType, // 连接类型 (Serial/Tcp/Usb/Ble/Wifi)
    pub address: String,                // 连接地址
    pub protocol: Protocol,             // 协议类型
    pub is_virtual: bool,               // 是否虚拟设备
    pub server_info: Option<String>,    // 服务器信息（TCP 设备）
    pub status: DeviceStatus,           // 设备状态
    pub last_seen: Option<String>,      // 最后在线时间
    pub error_message: Option<String>,  // 错误信息
}
```

**示例**:
```rust
let devices = list_devices();
for device in devices {
    println!("Device: {} ({})", device.name, device.id);
}
```

---

#### 2.1.3 添加串口设备

```rust
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
) -> DeviceInfo
```

**参数说明**:
| 参数 | 类型 | 说明 | 示例 |
|------|------|------|------|
| name | String | 设备名称 | "Oscilloscope" |
| port | String | 串口号 | "COM1" / "/dev/ttyUSB0" |
| baud_rate | u32 | 波特率 | 9600, 115200 |
| protocol | Protocol | 协议类型 | Protocol::Scpi |
| data_bits | DataBits | 数据位 | DataBits::Eight |
| stop_bits | StopBits | 停止位 | StopBits::One |
| parity | Parity | 校验位 | Parity::None |
| flow_control | FlowControl | 流控 | FlowControl::None |
| receive_timeout_ms | u64 | 接收超时 (ms) | 1000 |
| dtr_enabled | bool | DTR 使能 | true |
| rts_enabled | bool | RTS 使能 | true |
| break_enabled | bool | BREAK 使能 | false |

**返回值**:
- `DeviceInfo`: 新创建的设备信息

**示例**:
```rust
let device = add_serial_device(
    "My Device".to_string(),
    "COM1".to_string(),
    9600,
    Protocol::Scpi,
    DataBits::Eight,
    StopBits::One,
    Parity::None,
    FlowControl::None,
    1000,
    false,
    false,
    false,
);
println!("Device created: {}", device.id);
```

---

#### 2.1.4 添加 TCP 设备

```rust
/// 添加 TCP 网络设备
#[flutter_rust_bridge::frb(sync)]
pub fn add_tcp_device(
    name: String,
    host: String,
    port: u16,
    protocol: Protocol,
) -> DeviceInfo
```

**参数说明**:
| 参数 | 类型 | 说明 | 示例 |
|------|------|------|------|
| name | String | 设备名称 | "TCP Device" |
| host | String | 主机地址 | "192.168.1.100" |
| port | u16 | 端口号 | 5025 |
| protocol | Protocol | 协议类型 | Protocol::Scpi |

**示例**:
```rust
let device = add_tcp_device(
    "TCP Scope".to_string(),
    "192.168.1.100".to_string(),
    5025,
    Protocol::Scpi,
);
```

---

#### 2.1.5 更新设备配置

```rust
/// 更新设备配置（需要先断开连接）
#[flutter_rust_bridge::frb]
pub async fn update_device(
    device_id: String,
    name: String,
    address: String,
    protocol: Protocol,
) -> bool
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| device_id | String | 设备 ID |
| name | String | 新设备名称 |
| address | String | 新地址 |
| protocol | Protocol | 新协议 |

**返回值**:
- `bool`: 是否更新成功

**注意**: 如果设备已连接，会先自动断开。

---

#### 2.1.6 删除设备

```rust
/// 删除设备（会先断开连接）
#[flutter_rust_bridge::frb]
pub async fn remove_device(device_id: String) -> bool
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| device_id | String | 设备 ID |

**返回值**:
- `bool`: 是否删除成功

---

#### 2.1.7 扫描串口

```rust
/// 扫描可用串口（带缓存）
#[flutter_rust_bridge::frb(sync)]
pub fn scan_serial_ports() -> Vec<PortInfo>
```

**返回值**:
- `Vec<PortInfo>`: 可用串口列表

**PortInfo 结构**:
```rust
pub struct PortInfo {
    pub name: String,        // 串口名称 ("COM1")
    pub port_type: String,    // 端口类型 ("USB", "Bluetooth", etc.)
    pub description: String,  // 描述信息
    pub is_virtual: bool,    // 是否虚拟串口
}
```

**示例**:
```rust
let ports = scan_serial_ports();
for port in ports {
    println!("Port: {} - {}", port.name, port.description);
}
```

---

#### 2.1.8 连接设备

```rust
/// 连接设备
#[flutter_rust_bridge::frb]
pub async fn connect_device(device_id: String) -> bool
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| device_id | String | 设备 ID |

**返回值**:
- `bool`: 是否连接成功

**异步说明**: 此函数为异步函数，内部会：
1. 根据设备配置创建传输层（Serial/TCP）
2. 根据协议类型创建协议处理器
3. 启动后台接收循环

---

#### 2.1.9 断开设备

```rust
/// 断开设备连接
#[flutter_rust_bridge::frb]
pub async fn disconnect_device(device_id: String) -> bool
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| device_id | String | 设备 ID |

**返回值**:
- `bool`: 是否断开成功

---

#### 2.1.10 查询设备连接状态

```rust
/// 查询设备是否已连接
#[flutter_rust_bridge::frb(sync)]
pub fn is_device_connected(device_id: String) -> bool
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| device_id | String | 设备 ID |

**返回值**:
- `bool`: 是否已连接

---

### 2.2 调试控制台 API (debug_api)

**文件位置**: `rust/src/api/debug_api.rs`

#### 2.2.1 初始化日志

```rust
/// 初始化 Rust 日志系统（输出到调试控制台）
#[flutter_rust_bridge::frb(sync)]
pub fn debug_init_logger()
```

**说明**: 在应用启动时调用一次，初始化后 Rust 侧的 `log::info!()` 等宏会输出到调试控制台。

---

#### 2.2.2 发送字节数据

```rust
/// 发送原始字节数据到设备
#[flutter_rust_bridge::frb(sync)]
pub fn debug_send_bytes(device_id: String, data: Vec<u8>) -> bool
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| device_id | String | 设备 ID |
| data | Vec<u8> | 要发送的字节数据 |

**返回值**:
- `bool`: 是否发送成功

---

#### 2.2.3 发送字符串

```rust
/// 发送字符串到设备（自动添加行结束符）
#[flutter_rust_bridge::frb(sync)]
pub fn debug_send_string(
    device_id: String,
    text: String,
    line_ending: String,
) -> bool
```

**参数说明**:
| 参数 | 类型 | 说明 | 示例 |
|------|------|------|------|
| device_id | String | 设备 ID | - |
| text | String | 要发送的文本 | "*IDN?" |
| line_ending | String | 行结束符 | "CR", "LF", "CRLF", "NONE" |

**行结束符映射**:
- `"CR"`: `\r`
- `"LF"`: `\n`
- `"CRLF"`: `\r\n`
- `"NONE"` or `""`: 不添加

**示例**:
```rust
debug_send_string("device_001".to_string(), "*IDN?".to_string(), "LF".to_string());
```

---

#### 2.2.4 发送十六进制数据

```rust
/// 发送十六进制字符串（自动转换为字节）
#[flutter_rust_bridge::frb(sync)]
pub fn debug_send_hex(device_id: String, hex_string: String) -> bool
```

**参数说明**:
| 参数 | 类型 | 说明 | 示例 |
|------|------|------|------|
| device_id | String | 设备 ID | - |
| hex_string | String | 十六进制字符串 | "2A49444E3F" ("*IDN?") |

**示例**:
```rust
// 发送 "*IDN?" 的十六进制表示
debug_send_hex("device_001".to_string(), "2A49444E3F".to_string());
```

---

#### 2.2.5 接收数据

```rust
/// 接收设备返回的数据
#[flutter_rust_bridge::frb(sync)]
pub fn debug_receive(device_id: String) -> Option<Vec<u8>>
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| device_id | String | 设备 ID |

**返回值**:
- `Option<Vec<u8>>`: 接收到的字节数据（若无数据返回 `None`）

---

#### 2.2.6 获取调试日志

```rust
/// 获取设备的调试日志
#[flutter_rust_bridge::frb(sync)]
pub fn debug_get_log(device_id: String) -> Vec<DebugLogEntry>
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| device_id | String | 设备 ID |

**返回值**:
- `Vec<DebugLogEntry>`: 日志条目列表

**DebugLogEntry 结构**:
```rust
pub struct DebugLogEntry {
    pub timestamp: String,      // 时间戳
    pub direction: DataDirection, // Sent / Received
    pub data: String,           // 数据（十六进制或字符串）
    pub is_hex: bool,           // 是否为十六进制显示
}
```

---

#### 2.2.7 清空调试日志

```rust
/// 清空设备的调试日志
#[flutter_rust_bridge::frb(sync)]
pub fn debug_clear_log(device_id: String) -> bool
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| device_id | String | 设备 ID |

**返回值**:
- `bool`: 是否清空成功

---

### 2.3 Lua 脚本 API (lua_api)

**文件位置**: `rust/src/api/lua_api.rs`

#### 2.3.1 初始化 Lua 引擎

```rust
/// 初始化 Lua 脚本引擎（应用启动时调用一次）
#[flutter_rust_bridge::frb]
pub async fn init_lua_engine() -> bool
```

**返回值**:
- `bool`: 是否初始化成功

**说明**: 初始化后会加载核心脚本 (`sys.lua`, `log.lua` 等)。

---

#### 2.3.2 执行 Lua 脚本

```rust
/// 执行 Lua 脚本
#[flutter_rust_bridge::frb(sync)]
pub fn lua_execute_script(script: String) -> bool
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| script | String | Lua 脚本代码 |

**返回值**:
- `bool`: 是否执行成功

**示例**:
```rust
let script = r#"
    vcr.connect("device_001")
    vcr.send("device_001", "*IDN?")
    local response = vcr.receive("device_001")
    print("Response:", response)
    vcr.disconnect("device_001")
"#;

lua_execute_script(script.to_string());
```

---

#### 2.3.3 评估 Lua 表达式

```rust
/// 评估 Lua 表达式并返回结果
#[flutter_rust_bridge::frb(sync)]
pub fn lua_eval(expression: String) -> String
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| expression | String | Lua 表达式 |

**返回值**:
- `String`: 表达式的结果（字符串形式）

**示例**:
```rust
let result = lua_eval("2 + 3 * 4".to_string());
println!("Result: {}", result); // "14"
```

---

#### 2.3.4 设置当前设备 ID

```rust
/// 设置 Lua 引擎的当前设备 ID（供脚本中使用）
#[flutter_rust_bridge::frb(sync)]
pub fn lua_set_device_id(device_id: String) -> bool
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| device_id | String | 设备 ID |

**返回值**:
- `bool`: 是否设置成功

---

#### 2.3.5 获取 Lua 日志

```rust
/// 读取 Lua 日志缓冲区（同时清空，避免重复消费）
#[flutter_rust_bridge::frb(sync)]
pub fn lua_get_logs() -> Vec<String>
```

**返回值**:
- `Vec<String>`: 日志行列表

**说明**: 每次调用后缓冲区会被清空。

---

#### 2.3.6 脚本管理

```rust
/// 获取脚本列表
#[flutter_rust_bridge::frb(sync)]
pub fn lua_get_scripts_list() -> Vec<String>

/// 加载脚本内容
#[flutter_rust_bridge::frb(sync)]
pub fn lua_load_script(name: String) -> String

/// 保存脚本
#[flutter_rust_bridge::frb(sync)]
pub fn lua_save_script(name: String, content: String) -> bool

/// 删除脚本
#[flutter_rust_bridge::frb(sync)]
pub fn lua_delete_script(name: String) -> bool

/// 打开脚本目录
#[flutter_rust_bridge::frb(sync)]
pub fn lua_open_scripts_folder() -> bool
```

---

### 2.4 绘图 API (plot_api)

**文件位置**: `rust/src/api/plot_api.rs`

#### 2.4.1 注册绘图设备

```rust
/// 注册绘图设备（指定通道名称）
#[flutter_rust_bridge::frb(sync)]
pub fn plot_register_device(device_id: String, channels: Vec<String>)
```

**参数说明**:
| 参数 | 类型 | 说明 | 示例 |
|------|------|------|------|
| device_id | String | 设备 ID | "device_001" |
| channels | Vec<String> | 通道名称列表 | ["voltage", "current"] |

**示例**:
```rust
plot_register_device(
    "device_001".to_string(),
    vec!["voltage".to_string(), "current".to_string()],
);
```

---

#### 2.4.2 添加数据点

```rust
/// 添加单个数据点
#[flutter_rust_bridge::frb(sync)]
pub fn plot_push_data(
    device_id: String,
    channel: String,
    timestamp_ms: f64,
    value: f64,
)
```

**参数说明**:
| 参数 | 类型 | 说明 | 示例 |
|------|------|------|------|
| device_id | String | 设备 ID | "device_001" |
| channel | String | 通道名称 | "voltage" |
| timestamp_ms | f64 | 时间戳 (ms) | 1621345678901.5 |
| value | f64 | 数据值 | 3.3 |

---

#### 2.4.3 批量添加数据点

```rust
/// 批量添加数据点（多通道）
#[flutter_rust_bridge::frb(sync)]
pub fn plot_push_batch(
    device_id: String,
    channels: Vec<String>,
    timestamp_ms: f64,
    values: Vec<f64>,
)
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| device_id | String | 设备 ID |
| channels | Vec<String> | 通道名称列表 |
| timestamp_ms | f64 | 时间戳 (ms) |
| values | Vec<f64> | 数据值列表（与通道一一对应） |

**示例**:
```rust
plot_push_batch(
    "device_001".to_string(),
    vec!["voltage".to_string(), "current".to_string()],
    1621345678901.5,
    vec![3.3, 0.5],
);
```

---

#### 2.4.4 获取通道数据

```rust
/// 获取指定通道的数据
#[flutter_rust_bridge::frb(sync)]
pub fn plot_get_channel_data(
    device_id: String,
    channel: String,
) -> Vec<PlotPoint>
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| device_id | String | 设备 ID |
| channel | String | 通道名称 |

**返回值**:
- `Vec<PlotPoint>`: 数据点列表

**PlotPoint 结构**:
```rust
pub struct PlotPoint {
    pub timestamp_ms: f64,  // 时间戳 (ms)
    pub value: f64,         // 数据值
}
```

---

#### 2.4.5 清空设备数据

```rust
/// 清空设备的所有绘图数据
#[flutter_rust_bridge::frb(sync)]
pub fn plot_clear_device(device_id: String)
```

**参数说明**:
| 参数 | 类型 | 说明 |
|------|------|------|
| device_id | String | 设备 ID |

---

### 2.5 虚拟设备 API (virtual_api)

**文件位置**: `rust/src/api/virtual_api.rs`

#### 2.5.1 启动虚拟基础设施

```rust
/// 启动虚拟基础设施（TCP-SCPI 服务器 + 虚拟串口）
#[flutter_rust_bridge::frb(sync)]
pub fn start_virtual_infrastructure() -> VirtualInfraStatus
```

**返回值**:
- `VirtualInfraStatus`: 虚拟设施状态

**VirtualInfraStatus 结构**:
```rust
pub struct VirtualInfraStatus {
    pub tcp_server_running: bool,    // TCP 服务器是否运行中
    pub virtual_serial_running: bool, // 虚拟串口是否运行中
    pub tcp_port: u16,               // TCP 服务器端口
    pub virtual_com_pairs: Vec<String>, // 虚拟串口对
}
```

---

#### 2.5.2 停止虚拟基础设施

```rust
/// 停止虚拟基础设施
#[flutter_rust_bridge::frb(sync)]
pub fn stop_virtual_infrastructure() -> bool
```

**返回值**:
- `bool`: 是否成功停止

---

#### 2.5.3 获取虚拟设施状态

```rust
/// 获取虚拟设施的当前状态
#[flutter_rust_bridge::frb(sync)]
pub fn get_virtual_infra_status() -> VirtualInfraStatus
```

**返回值**:
- `VirtualInfraStatus`: 当前状态

---

## 3. Dart/Flutter API

所有 Dart API 都是通过 `flutter_rust_bridge` 自动生成的，位于 `lib/src/rust/api/` 目录下。

### 3.1 设备管理 API (device_api.dart)

#### 3.1.1 获取支持的协议

```dart
/// 获取所有支持的协议
List<String> getSupportedProtocols()
```

**返回值**:
- `List<String>`: 协议标签列表

**示例**:
```dart
final protocols = getSupportedProtocols();
print(protocols); // ["Raw / 无协议", "Modbus RTU", ...]
```

---

#### 3.1.2 获取设备列表

```dart
/// 获取所有设备
List<DeviceInfo> listDevices()
```

**返回值**:
- `List<DeviceInfo>`: 设备信息列表

**示例**:
```dart
final devices = listDevices();
for (final device in devices) {
  print('Device: ${device.name} (${device.id})');
}
```

---

#### 3.1.3 添加串口设备

```dart
/// 添加串口设备
DeviceInfo addSerialDevice({
  required String name,
  required String port,
  required int baudRate,
  required Protocol protocol,
  required DataBits dataBits,
  required StopBits stopBits,
  required Parity parity,
  required FlowControl flowControl,
  required BigInt receiveTimeoutMs,
  required bool dtrEnabled,
  required bool rtsEnabled,
  required bool breakEnabled,
})
```

**示例**:
```dart
final device = addSerialDevice(
  name: 'My Device',
  port: 'COM1',
  baudRate: 9600,
  protocol: Protocol.scpi,
  dataBits: DataBits.eight,
  stopBits: StopBits.one,
  parity: Parity.none,
  flowControl: FlowControl.none,
  receiveTimeoutMs: BigInt.from(1000),
  dtrEnabled: false,
  rtsEnabled: false,
  breakEnabled: false,
);
```

---

#### 3.1.4 连接设备

```dart
/// 连接设备（异步）
Future<bool> connectDevice({required String deviceId})
```

**示例**:
```dart
final success = await connectDevice(deviceId: 'device_001');
if (success) {
  print('Device connected');
} else {
  print('Connection failed');
}
```

---

### 3.2 调试控制台 API (debug_api.dart)

#### 3.2.1 发送字符串

```dart
/// 发送字符串到设备
bool debugSendString({
  required String deviceId,
  required String text,
  required String lineEnding,
})
```

**示例**:
```dart
debugSendString(
  deviceId: 'device_001',
  text: '*IDN?',
  lineEnding: 'LF',
);
```

---

#### 3.2.2 接收数据

```dart
/// 接收设备数据
Uint8List? debugReceive({required String deviceId})
```

**示例**:
```dart
final data = debugReceive(deviceId: 'device_001');
if (data != null) {
  final response = String.fromUtf8(data);
  print('Response: $response');
}
```

---

### 3.3 Lua 脚本 API (lua_api.dart)

#### 3.3.1 执行脚本

```dart
/// 执行 Lua 脚本
bool luaExecuteScript({required String script})
```

**示例**:
```dart
final script = '''
  vcr.connect("device_001")
  vcr.send("device_001", "*IDN?")
  local response = vcr.receive("device_001")
  print("Response:", response)
  vcr.disconnect("device_001")
''';

luaExecuteScript(script: script);
```

---

#### 3.3.2 获取脚本列表

```dart
/// 获取脚本列表
List<String> luaGetScriptsList()
```

**示例**:
```dart
final scripts = luaGetScriptsList();
for (final script in scripts) {
  print('Script: $script');
}
```

---

### 3.4 绘图 API (plot_api.dart)

#### 3.4.1 注册绘图设备

```dart
/// 注册绘图设备
void plotRegisterDevice({
  required String deviceId,
  required List<String> channels,
})
```

**示例**:
```dart
plotRegisterDevice(
  deviceId: 'device_001',
  channels: ['voltage', 'current'],
);
```

---

#### 3.4.2 添加数据点

```dart
/// 添加单个数据点
void plotPushData({
  required String deviceId,
  required String channel,
  required double timestampMs,
  required double value,
})
```

**示例**:
```dart
plotPushData(
  deviceId: 'device_001',
  channel: 'voltage',
  timestampMs: DateTime.now().millisecondsSinceEpoch.toDouble(),
  value: 3.3,
);
```

---

#### 3.4.3 获取通道数据

```dart
/// 获取通道数据
List<PlotPoint> plotGetChannelData({
  required String deviceId,
  required String channel,
})
```

**PlotPoint 类**:
```dart
class PlotPoint {
  final double timestampMs;
  final double value;
  
  PlotPoint({required this.timestampMs, required this.value});
}
```

**示例**:
```dart
final points = plotGetChannelData(
  deviceId: 'device_001',
  channel: 'voltage',
);

for (final point in points) {
  print('Time: ${point.timestampMs}, Value: ${point.value}');
}
```

---

## 4. API 使用示例

### 4.1 设备管理流程

```dart
import 'package:vcr/src/rust/api/device_api.dart';

void deviceManagementExample() async {
  // 1. 获取支持的协议
  final protocols = getSupportedProtocols();
  print('Supported protocols: $protocols');
  
  // 2. 添加串口设备
  final device = addSerialDevice(
    name: 'Oscilloscope',
    port: 'COM1',
    baudRate: 9600,
    protocol: Protocol.scpi,
    dataBits: DataBits.eight,
    stopBits: StopBits.one,
    parity: Parity.none,
    flowControl: FlowControl.none,
    receiveTimeoutMs: BigInt.from(1000),
    dtrEnabled: false,
    rtsEnabled: false,
    breakEnabled: false,
  );
  
  print('Device created: ${device.id}');
  
  // 3. 连接设备
  final connected = await connectDevice(deviceId: device.id);
  if (connected) {
    print('Device connected successfully');
    
    // 4. 使用设备...
    
    // 5. 断开连接
    await disconnectDevice(deviceId: device.id);
  }
  
  // 6. 删除设备
  await removeDevice(deviceId: device.id);
}
```

---

### 4.2 调试控制台流程

```dart
import 'package:vcr/src/rust/api/debug_api.dart';

void debugConsoleExample() async {
  final deviceId = 'device_001';
  
  // 1. 初始化日志
  debugInitLogger();
  
  // 2. 发送命令
  debugSendString(
    deviceId: deviceId,
    text: '*IDN?',
    lineEnding: 'LF',
  );
  
  // 3. 接收响应
  final data = debugReceive(deviceId: deviceId);
  if (data != null) {
    final response = String.fromCharCodes(data);
    print('Response: $response');
  }
  
  // 4. 查看日志
  final logs = debugGetLog(deviceId: deviceId);
  for (final log in logs) {
    print('${log.timestamp} [${log.direction}] ${log.data}');
  }
}
```

---

### 4.3 Lua 脚本流程

```dart
import 'package:vcr/src/rust/api/lua_api.dart';

void luaScriptExample() async {
  // 1. 初始化 Lua 引擎
  await initLuaEngine();
  
  // 2. 执行简单脚本
  final script = '''
    print("Hello from Lua!")
    local a, b = 10, 20
    print("Sum:", a + b)
  ''';
  
  luaExecuteScript(script: script);
  
  // 3. 控制设备
  final deviceScript = '''
    vcr.connect("device_001")
    
    for i = 1, 10 do
      vcr.send("device_001", "*IDN?")
      local response = vcr.receive("device_001")
      print("Response " .. i .. ":", response)
      vcr.sleep(1000)  -- 等待 1 秒
    end
    
    vcr.disconnect("device_001")
  ''';
  
  luaExecuteScript(script: deviceScript);
  
  // 4. 获取日志
  final logs = luaGetLogs();
  for (final log in logs) {
    print(log);
  }
}
```

---

### 4.4 绘图流程

```dart
import 'package:vcr/src/rust/api/plot_api.dart';

void plotExample() {
  final deviceId = 'device_001';
  
  // 1. 注册绘图设备
  plotRegisterDevice(
    deviceId: deviceId,
    channels: ['voltage', 'current'],
  );
  
  // 2. 模拟数据
  for (int i = 0; i < 100; i++) {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toDouble();
    
    plotPushData(
      deviceId: deviceId,
      channel: 'voltage',
      timestampMs: timestamp,
      value: 3.3 + (i * 0.01),
    );
    
    plotPushData(
      deviceId: deviceId,
      channel: 'current',
      timestampMs: timestamp,
      value: 0.5 + (i * 0.001),
    );
  }
  
  // 3. 获取数据进行绘图
  final voltageData = plotGetChannelData(
    deviceId: deviceId,
    channel: 'voltage',
  );
  
  print('Voltage data points: ${voltageData.length}');
  
  // 4. 清空数据
  plotClearDevice(deviceId: deviceId);
}
```

---

## 5. 错误处理

### 5.1 Rust 侧错误处理

所有 Rust API 使用 `Result<T, E>` 返回结果，`flutter_rust_bridge` 会自动转换为 Dart 的异常。

**错误类型** (`src/core/error.rs`):
```rust
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Device not found: {0}")]
    DeviceNotFound(String),
    
    #[error("Connection failed: {0}")]
    ConnectionFailed(String),
    
    #[error("Protocol error: {0}")]
    ProtocolError(String),
    
    #[error("Transport error: {0}")]
    TransportError(#[from] TransportError),
    
    #[error("Lua error: {0}")]
    LuaError(String),
    
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}
```

---

### 5.2 Dart 侧错误处理

```dart
try {
  await connectDevice(deviceId: 'device_001');
} on FrbException catch (e) {
  print('Error: ${e.message}');
  print('Error code: ${e.code}');
} catch (e) {
  print('Unknown error: $e');
}
```

---

### 5.3 常见错误码

| 错误码 | 说明 | 解决方法 |
|--------|------|----------|
| 1001 | 设备未找到 | 检查设备 ID 是否正确 |
| 1002 | 连接失败 | 检查设备地址和端口 |
| 1003 | 命令执行失败 | 检查命令格式 |
| 1004 | 协议不支持 | 检查协议类型 |
| 1005 | 传输层错误 | 检查传输层配置 |
| 2001 | Lua 脚本错误 | 检查脚本语法 |
| 2002 | 绘图引擎错误 | 检查数据和通道 |

---

## 6. 附录

### 6.1 数据类型映射

| Rust 类型 | Dart 类型 | 说明 |
|-----------|-----------|------|
| `String` | `String` | 字符串 |
| `i32` | `int` | 32 位整数 |
| `u32` | `int` | 无符号 32 位整数 |
| `i64` | `BigInt` | 64 位整数 |
| `f64` | `double` | 64 位浮点数 |
| `bool` | `bool` | 布尔值 |
| `Vec<T>` | `List<T>` | 动态数组 |
| `HashMap<K, V>` | `Map<K, V>` | 哈希表 |
| `Option<T>` | `T?` | 可选值 |
| `Result<T, E>` | `Future<T>` (或抛出异常) | 结果类型 |

---

### 6.2 枚举映射

**Rust**:
```rust
pub enum DeviceStatus {
    Disconnected,
    Connecting,
    Connected,
    Error,
}
```

**Dart**:
```dart
enum DeviceStatus {
  disconnected,
  connecting,
  connected,
  error,
}
```

---

### 6.3 异步调用说明

- **Rust 侧**: 使用 `#[flutter_rust_bridge::frb]` 标记异步函数
- **Dart 侧**: 返回 `Future<T>`，需使用 `await` 调用

**Rust**:
```rust
#[flutter_rust_bridge::frb]
pub async fn connect_device(device_id: String) -> Result<bool> {
    // 异步逻辑
}
```

**Dart**:
```dart
final success = await connectDevice(deviceId: 'device_001');
```

---

### 6.4 性能优化建议

1. **批量操作**: 使用 `plot_push_batch` 而非多次 `plot_push_data`
2. **避免频繁查询**: 使用回调而非轮询
3. **数据降采样**: 绘图时只保留最近 1000 点
4. **异步操作**: 长时间运行的操作使用异步 API

---

### 6.5 完整示例：设备控制脚本

```lua
-- advanced_device_control.lua

-- 配置
local DEVICE_ID = "device_001"
local SAMPLE_COUNT = 100
local SAMPLE_INTERVAL_MS = 100

-- 连接到设备
vcr.connect(DEVICE_ID)

-- 注册绘图通道
vcr.plot.register(DEVICE_ID, {"voltage", "current"})

-- 配置设备
vcr.send(DEVICE_ID, "CONFigure:VOLTage:RANGE AUTO")
vcr.send(DEVICE_ID, "CONFigure:CURRent:RANGE AUTO")

-- 数据采集循环
for i = 1, SAMPLE_COUNT do
    -- 测量电压
    vcr.send(DEVICE_ID, "MEASure:VOLTage?")
    local voltage_str = vcr.receive(DEVICE_ID)
    local voltage = tonumber(voltage_str)
    
    -- 测量电流
    vcr.send(DEVICE_ID, "MEASure:CURRent?")
    local current_str = vcr.receive(DEVICE_ID)
    local current = tonumber(current_str)
    
    -- 记录数据
    local timestamp = vcr.get_timestamp()
    vcr.plot.push(DEVICE_ID, "voltage", timestamp, voltage)
    vcr.plot.push(DEVICE_ID, "current", timestamp, current)
    
    -- 日志
    vcr.log("info", "main", string.format("Sample %d: V=%.3f, I=%.3f", i, voltage, current))
    
    -- 等待
    vcr.sleep(SAMPLE_INTERVAL_MS)
end

-- 断开连接
vcr.disconnect(DEVICE_ID)

-- 输出统计
vcr.log("info", "main", "Data collection completed")
```

---

**文档结束**

---

**修订历史**:

| 版本 | 日期 | 作者 | 变更说明 |
|------|------|------|----------|
| 1.0 | 2026-05-18 | API文档生成器 | 初始版本 |

---

**联系方式**:
- 项目主页: [待定]
- 问题反馈: [待定]
- 文档更新: [待定]
