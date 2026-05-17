# VCR (Virtual Instrument Control Application) 完整构建提示词

## 项目概述

你是一个全栈开发专家，需要构建一个名为VCR (Virtual Instrument Control Application) 的跨平台桌面应用。该应用用于管理和控制各种仪器设备，支持多种工业通信协议。

## 核心技术栈

- **前端框架**: Flutter (Dart)
- **核心引擎**: Rust (通过 flutter_rust_bridge 集成)
- **目标平台**: Windows, Linux (桌面应用)
- **通信协议**: SCPI, Modbus (RTU/TCP), CSV, Raw
- **传输层**: Serial (串口), TCP/IP, Virtual (虚拟通道)

## 项目目录结构

```
vcr/
├── lib/                          # Flutter Dart 代码
│   ├── main.dart                 # 应用入口
│   ├── app/                      # 应用配置
│   │   ├── routes.dart          # 路由配置
│   │   └── theme.dart           # 主题配置
│   ├── screens/                  # 界面屏幕
│   │   ├── home_screen.dart     # 主页
│   │   ├── device_list_screen.dart      # 设备列表
│   │   ├── device_detail_screen.dart   # 设备详情
│   │   ├── debug_console_screen.dart    # 调试控制台
│   │   ├── lua_script_screen.dart       # Lua脚本编辑器
│   │   ├── plot_screen.dart            # 数据绘图
│   │   └── settings_screen.dart        # 设置页面
│   ├── src/rust/                # Rust FFI 绑定
│   │   ├── frb_generated.dart  # 自动生成的绑定代码
│   │   └── api/                # API接口封装
│   │       ├── device_api.dart
│   │       ├── debug_api.dart
│   │       ├── lua_api.dart
│   │       ├── plot_api.dart
│   │       └── virtual_api.dart
│   └── widgets/                 # 共享组件
│       ├── main_shell.dart      # 主界面框架
│       └── status_indicator.dart # 状态指示器
├── rust/                        # Rust 核心代码
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs               # Rust 库入口
│       ├── api/                 # API接口层
│       │   ├── mod.rs
│       │   ├── device_api.rs
│       │   ├── debug_api.rs
│       │   ├── lua_api.rs
│       │   ├── plot_api.rs
│       │   └── virtual_api.rs
│       └── core/                # 核心业务逻辑
│           ├── mod.rs
│           ├── app_context.rs   # 应用上下文
│           ├── device/          # 设备管理
│           │   ├── mod.rs
│           │   ├── models.rs    # 数据模型
│           │   ├── registry.rs  # 设备注册表
│           │   └── preset.rs    # 设备预设
│           ├── protocol/        # 协议实现
│           │   ├── mod.rs
│           │   ├── trait.rs     # 协议 trait 定义
│           │   ├── registry.rs  # 协议注册
│           │   ├── csv_parser.rs
│           │   └── plugins/     # 具体协议插件
│           │       ├── scpi.rs
│           │       ├── modbus_rtu.rs
│           │       ├── modbus_tcp.rs
│           │       ├── csv.rs
│           │       └── raw.rs
│           ├── transport/       # 传输层
│           │   ├── mod.rs
│           │   ├── serial.rs    # 串口通信
│           │   ├── tcp.rs       # TCP通信
│           │   ├── modbus.rs    # Modbus 传输
│           │   └── virtual_channel.rs # 虚拟通道
│           ├── session/         # 会话管理
│           │   ├── mod.rs
│           │   ├── session_manager.rs
│           │   └── debug_session.rs
│           ├── plot/            # 数据绘图
│           │   ├── mod.rs
│           │   └── data_buffer.rs
│           └── virtual_device/  # 虚拟设备
│               ├── mod.rs
│               ├── simulator.dart
│               ├── scpi_responder.rs
│               └── data_generator.rs
├── assets/
│   └── images/
│       └── vcr_logo.png
├── docs/                        # 项目文档
├── test/                        # 测试代码
├── scripts/                     # 工具脚本
├── windows/                     # Windows 平台配置
├── linux/                       # Linux 平台配置
├── pubspec.yaml                 # Flutter 依赖配置
├── Cargo.toml                   # Rust 依赖配置
└── analysis_options.yaml         # Dart 代码分析配置
```

## 详细功能需求

### 1. 设备管理模块

**功能描述**：
- 支持添加、编辑、删除仪器设备
- 设备连接/断开控制
- 设备状态监控（已连接/未连接/错误）
- 持久化存储设备配置
- 自动重连功能

**设备属性**：
```dart
class DeviceInfo {
  String id;              // 唯一标识
  String name;            // 设备名称
  String protocol;        // 协议类型 (SCPI, ModbusRTU, ModbusTCP, CSV, Raw)
  String transportType;   // 传输类型 (Serial, TCP, Virtual)
  Map<String, dynamic> connectionParams; // 连接参数
  DeviceStatus status;    // 状态
}
```

**连接参数示例**：
- Serial: {port: "COM1", baudRate: 9600, dataBits: 8, stopBits: 1, parity: "None", flowControl: "None"}
- TCP: {host: "192.168.1.100", port: 502}
- Virtual: {type: "TCP-SCPI" | "Serial-SCPI"}

### 2. 调试控制台模块

**功能描述**：
- 发送命令到设备
- 接收并显示设备响应
- 支持命令历史记录
- 支持十六进制/ASCII显示切换
- 实时日志输出

**核心功能**：
```dart
// 发送命令
Future<String> sendCommand(String deviceId, String command);

// 接收数据
Stream<String> receiveData(String deviceId);

// 获取历史记录
List<String> getCommandHistory(String deviceId);
```

### 3. Lua脚本模块

**功能描述**：
- 内置Lua引擎（通过 Rust 集成 rlua）
- 脚本编辑器（语法高亮）
- 脚本执行和控制
- 访问设备API（通过Lua绑定）
- 脚本示例和模板

**Lua API 绑定**：
```lua
-- 设备控制
vcr.connect(device_id)
vcr.disconnect(device_id)
vcr.send(device_id, command)
vcr.receive(device_id)

-- 数据绘图
vcr.plot.add_series(name, data)
vcr.plot.update(series_name, value)

-- 定时任务
vcr.timer(delay_ms, callback)
```

### 4. 数据绘图模块

**功能描述**：
- 实时数据绘图
- 多系列数据支持
- 缩放、平移、重置视图
- 数据导出（CSV）
- 绘图配置保存

**数据结构**：
```rust
struct PlotData {
    series_name: String,
    timestamp: Vec<f64>,
    values: Vec<f64>,
}
```

### 5. 虚拟设备模块

**功能描述**：
- 模拟SCPI设备
- 虚拟串口 (COM1/COM2)
- TCP-SCPI服务器
- 可配置响应行为
- 数据生成器（正弦波、方波等）

**虚拟设备类型**：
- TCP-SCPI-Demo: 在端口 5025 模拟SCPI设备
- Serial-SCPI-Demo: 通过虚拟串口 COM1 模拟SCPI设备

### 6. 设置模块

**功能描述**：
- 应用配置持久化
- 主题切换（深色/浅色）
- 自动重连开关
- 日志级别配置
- 设备排序规则

**配置文件位置**：
- Windows: `%APPDATA%\VCR\app_config.json`
- Linux: `~/.config/vcr/app_config.json`

## 技术实现要点

### Flutter-Rust 集成

使用 `flutter_rust_bridge` 进行 Dart 和 Rust 之间的 FFI 绑定。

**pubspec.yaml 依赖**：
```yaml
dependencies:
  flutter_rust_bridge: ^2.12.0
  rust_lib_vcr:
    path: rust_builder
```

**Rust 端导出函数示例**：
```rust
use flutter_rust_bridge::frb;

#[frb]
pub async fn connect_device(device_id: String) -> Result<()> {
    // 实现连接逻辑
}

#[frb]
pub fn list_devices() -> Vec<DeviceInfo> {
    // 返回设备列表
}
```

### 协议实现

**协议 Trait 定义**：
```rust
#[async_trait]
pub trait DeviceProtocol: Send + Sync {
    async fn connect(&mut self, params: &ConnectionParams) -> Result<()>;
    async fn disconnect(&mut self) -> Result<()>;
    async fn send(&mut self, command: &str) -> Result<()>;
    async fn receive(&mut self) -> Result<String>;
    fn is_connected(&self) -> bool;
}
```

**SCPI 协议实现**：
```rust
pub struct ScpiProtocol {
    transport: Box<dyn Transport>,
}

#[async_trait]
impl DeviceProtocol for ScpiProtocol {
    async fn send(&mut self, command: &str) -> Result<()> {
        let scpi_cmd = format!("{}\n", command);
        self.transport.send(scpi_cmd.as_bytes()).await
    }
    
    async fn receive(&mut self) -> Result<String> {
        let data = self.transport.receive().await?;
        Ok(String::from_utf8_lossy(&data).trim().to_string())
    }
}
```

### 传输层实现

**串口通信** (使用 `serialport` crate):
```rust
pub struct SerialTransport {
    port: Box<dyn SerialPort>,
}

impl Transport for SerialTransport {
    async fn send(&mut self, data: &[u8]) -> Result<()> {
        self.port.write_all(data)?;
        Ok(())
    }
    
    async fn receive(&mut self) -> Result<Vec<u8>> {
        let mut buffer = vec![0u8; 1024];
        let n = self.port.read(&mut buffer)?;
        buffer.truncate(n);
        Ok(buffer)
    }
}
```

**TCP通信** (使用 `tokio::net`):
```rust
pub struct TcpTransport {
    stream: TcpStream,
}

impl Transport for TcpTransport {
    async fn send(&mut self, data: &[u8]) -> Result<()> {
        self.stream.write_all(data).await?;
        Ok(())
    }
    
    async fn receive(&mut self) -> Result<Vec<u8>> {
        let mut buffer = vec![0u8; 1024];
        let n = self.stream.read(&mut buffer).await?;
        buffer.truncate(n);
        Ok(buffer)
    }
}
```

### Lua 集成

使用 `rlua` crate 集成 Lua 引擎：

```rust
use rlua::{Lua, Table};

pub struct LuaEngine {
    lua: Lua,
}

impl LuaEngine {
    pub fn new() -> Self {
        let lua = Lua::new();
        
        // 注册 VCR API
        lua.context(|lua_ctx| {
            let vcr_table = lua_ctx.create_table().unwrap();
            
            // vcr.connect()
            vcr_table.set("connect", lua_ctx.create_function(|_, device_id: String| {
                // 调用 Rust 连接函数
                Ok(())
            }).unwrap()).unwrap();
            
            lua_ctx.globals().set("vcr", vcr_table).unwrap();
        });
        
        Self { lua }
    }
    
    pub fn execute(&self, script: &str) -> Result<String> {
        self.lua.context(|lua_ctx| {
            let result: rlua::Value = lua_ctx.load(script).eval()?;
            Ok(format!("{:?}", result))
        })
    }
}
```

### 虚拟设备实现

**SCPI 响应模拟**：
```rust
pub struct ScpiResponder {
    commands: HashMap<String, String>, // 命令 -> 响应
}

impl ScpiResponder {
    pub fn new() -> Self {
        let mut commands = HashMap::new();
        commands.insert("*IDN?".to_string(), "VCR,Virtual Device,1.0".to_string());
        commands.insert("*RST".to_string(), "OK".to_string());
        // ... 更多命令
        
        Self { commands }
    }
    
    pub fn respond(&self, command: &str) -> String {
        self.commands.get(command)
            .cloned()
            .unwrap_or_else(|| "ERROR".to_string())
    }
}
```

**虚拟串口** (使用 `com0com` 或类似工具):
```rust
pub async fn start_virtual_serial() -> Result<()> {
    // 创建虚拟串口对 (COM1 <-> COM2)
    // 在 COM1 上监听，模拟设备行为
    // COM2 提供给用户连接
    Ok(())
}
```

### 数据绘图

使用 `fl_chart` 或 `syncfusion_flutter_charts` 实现实时绘图：

```dart
class PlotScreen extends StatefulWidget {
  @override
  _PlotScreenState createState() => _PlotScreenState();
}

class _PlotScreenState extends State<PlotScreen> {
  List<LineChartBarData> _series = [];
  
  void addDataPoint(String seriesName, double x, double y) {
    // 添加数据点并更新图表
    setState(() {
      // 更新 _series
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        lineBarsData: _series,
        // ... 配置
      ),
    );
  }
}
```

## 构建步骤

### 1. 环境准备

**安装 Flutter**:
```bash
# 下载 Flutter SDK
# 添加到 PATH
flutter doctor
```

**安装 Rust**:
```bash
# Windows
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# 安装 stable 工具链
rustup default stable
```

**安装 flutter_rust_bridge 代码生成器**:
```bash
cargo install flutter_rust_bridge_codegen
```

### 2. 创建 Flutter 项目

```bash
flutter create vcr --org com.vcr
cd vcr
```

### 3. 配置 Rust 集成

**创建 Rust 库**:
```bash
cargo new rust --lib
cd rust
```

**Cargo.toml**:
```toml
[package]
name = "rust_lib_vcr"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib", "staticlib"]

[dependencies]
flutter_rust_bridge = "2.12.0"
tokio = { version = "1", features = ["full"] }
serialport = "4.2"
rlua = "0.19"
# ... 其他依赖
```

**生成绑定代码**:
```bash
flutter_rust_bridge_codegen \
  --rust-input rust/src/api/*.rs \
  --dart-output lib/src/rust/frb_generated.dart
```

### 4. 实现核心功能

按照上述功能需求，逐个实现：
1. 数据模型和协议 trait
2. 传输层实现
3. 协议插件
4. 设备管理
5. Lua引擎集成
6. 虚拟设备
7. Flutter UI

### 5. 构建和打包

**Windows**:
```bash
flutter build windows --release
```

**Linux**:
```bash
flutter build linux --release
```

## 关键依赖

**Flutter packages** (`pubspec.yaml`):
```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_rust_bridge: ^2.12.0
  file_picker: ^8.0.0
  gbk_codec: ^0.4.0  # GBK 编码支持
  flutter_highlight: ^0.7.0  # 代码高亮
  highlight: ^0.7.0
  cupertino_icons: ^1.0.8
  fl_chart: ^0.65.0  # 绘图
  # 或 syncfusion_flutter_charts (更强大)
```

**Rust crates** (`Cargo.toml`):
```toml
[dependencies]
flutter_rust_bridge = "2.12.0"
tokio = { version = "1", features = ["full", "sync"] }
serialport = "4.2"
rlua = "0.19"
tokio-modbus = "0.8"
csv = "1.3"
chrono = "0.4"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
thiserror = "1.0"
tracing = "0.1"
tracing-subscriber = "0.3"
```

## UI 设计指南

**主题**: 深色主题为主，专业工业风格

**主界面布局**:
```
┌─────────────────────────────────────────┐
│  VCR Logo    [设备] [调试] [脚本] [绘图] │
├─────────────────────────────────────────┤
│                                         │
│        当前页面的内容区域                  │
│                                         │
│                                         │
├─────────────────────────────────────────┤
│  状态栏: 已连接设备数 | 日志级别 | 时间  │
└─────────────────────────────────────────┘
```

**颜色方案**:
- 背景: `#1E1E1E` (深灰)
- 主色调: `#00A86B` (绿色，工业感)
- 强调色: `#FF6B35` (橙色，警告/操作)
- 文本: `#FFFFFF` (白色)

## 测试策略

**单元测试**:
- Rust 核心逻辑测试 (`cargo test`)
- Dart 工具函数测试 (`flutter test`)

**集成测试**:
- 设备连接测试
- 协议解析测试
- Lua脚本执行测试

**虚拟设备测试**:
- 使用虚拟串口和TCP服务器
- 自动化测试脚本

## 部署和分发

**Windows**:
- 使用 `flutter build windows --release`
- 打包为 MSI 安装程序 (使用 `msix` 或 `Inno Setup`)

**Linux**:
- 使用 `flutter build linux --release`
- 打包为 AppImage 或 .deb/.rpm

## 注意事项

1. **线程安全**: Rust 端确保线程安全，使用 `Arc<Mutex<>>` 共享状态
2. **异步处理**: 使用 `tokio` 处理异步 I/O
3. **错误处理**: 使用 `thiserror` 定义错误类型，统一错误处理
4. **日志**: 使用 `tracing` 进行结构化日志
5. **跨平台**: 注意 Windows/Linux 差异（路径、串口名称等）
6. **性能**: 大数据量时使用流式处理，避免内存溢出
7. **安全性**: Lua 沙箱限制，避免执行危险操作

## 示例代码结构

由于完整代码过长，这里提供关键模块的代码框架。在实际实现时，需要逐个模块完成：

1. **先实现 Rust 核心库** (不依赖 Flutter)
2. **生成 Flutter 绑定**
3. **实现 Flutter UI**
4. **集成测试和优化**

## 交付物

完成后的项目应包含：

1. ✅ 完整的 Flutter + Rust 混合应用
2. ✅ 支持 SCPI, Modbus, CSV, Raw 协议
3. ✅ 串口和 TCP 通信
4. ✅ Lua 脚本自动化
5. ✅ 实时数据绘图
6. ✅ 虚拟设备模拟
7. ✅ 设备配置持久化
8. ✅ 跨平台支持 (Windows/Linux)
9. ✅ 完整文档和注释
10. ✅ 单元测试和集成测试

---

**使用说明**: 

1. 按照"构建步骤"一节准备开发环境
2. 按照"项目目录结构"创建项目框架
3. 参考"技术实现要点"逐步实现各个模块
4. 使用"关键依赖"配置项目依赖
5. 遵循"UI设计指南"实现界面
6. 按照"测试策略"进行验证

这个提示词提供了构建 VCR 应用所需的全部信息。根据实际需求，可以调整功能优先级和实现细节。
