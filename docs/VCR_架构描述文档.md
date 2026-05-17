# VCR (Virtual Instrument Control Application) 架构描述文档

**版本**: 1.0  
**日期**: 2026-05-18  
**架构师**: AI架构分析师

---

## 目录

1. [系统概述](#1-系统概述)
2. [架构设计原则](#2-架构设计原则)
3. [技术栈](#3-技术栈)
4. [系统架构图](#4-系统架构图)
5. [分层架构](#5-分层架构)
6. [核心模块设计](#6-核心模块设计)
7. [数据流向](#7-数据流向)
8. [关键设计模式](#8-关键设计模式)
9. [模块依赖关系](#9-模块依赖关系)
10. [部署架构](#10-部署架构)
11. [性能优化策略](#11-性能优化策略)
12. [安全性设计](#12-安全性设计)
13. [扩展性设计](#13-扩展性设计)

---

## 1. 系统概述

VCR (Virtual Instrument Control Application) 是一款跨平台桌面应用程序，用于管理和控制各类工业仪器设备。系统采用 **Flutter + Rust** 混合架构，结合了Flutter的跨平台UI能力和Rust的高性能、内存安全特性。

### 1.1 核心能力

- **多协议支持**: SCPI, Modbus (RTU/TCP), CSV, Raw
- **多传输层**: 串口 (Serial), TCP/IP, 虚拟通道
- **脚本自动化**: 内置Lua引擎，支持自定义自动化脚本
- **实时数据监控**: 实时绘图和数据记录
- **虚拟设备仿真**: 无需真实硬件即可测试和开发
- **跨平台支持**: Windows, Linux

### 1.2 目标用户

- 自动化测试工程师
- 仪器研发工程师
- 工业控制系统集成商
- 教育培训机构

---

## 2. 架构设计原则

### 2.1 SOLID原则

- **单一职责原则 (SRP)**: 每个模块只负责一个功能领域
- **开闭原则 (OCP)**: 协议和传输层可扩展，无需修改现有代码
- **里氏替换原则 (LSP)**: 所有协议插件实现统一Trait
- **接口隔离原则 (ISP)**: API设计精细化，避免臃肿接口
- **依赖倒置原则 (DIP)**: 高层模块不依赖低层模块，二者依赖抽象

### 2.2 设计原则

- **性能优先**: Rust核心层处理计算密集型任务
- **类型安全**: Rust的借用检查器保证内存安全
- **异步优先**: 使用Tokio异步运行时，避免UI阻塞
- **插件化架构**: 协议和传输层采用插件化设计
- **跨平台兼容**: 抽象平台差异，共享核心逻辑

---

## 3. 技术栈

### 3.1 前端技术栈 (Flutter/Dart)

| 技术 | 版本 | 用途 |
|------|------|------|
| Flutter SDK | ≥3.11.5 | UI框架 |
| Dart | ≥3.11.5 | 编程语言 |
| flutter_rust_bridge | ^2.12.0 | Flutter-Rust FFI绑定 |
| file_picker | ^8.0.0 | 文件选择 |
| gbk_codec | ^0.4.0 | GBK编码支持 |
| flutter_highlight | ^0.7.0 | 代码高亮 |
| fl_chart | ^0.65.0 | 数据绘图 |

### 3.2 后端技术栈 (Rust)

| 技术 | 版本 | 用途 |
|------|------|------|
| Rust | stable | 系统编程语言 |
| Tokio | 1.x | 异步运行时 |
| flutter_rust_bridge | 2.12.0 | FFI代码生成 |
| serialport | 4.2 | 串口通信 |
| rlua | 0.19 | Lua引擎集成 |
| tokio-modbus | 0.8 | Modbus协议 |
| csv | 1.3 | CSV解析 |
| serde | 1.0 | 序列化/反序列化 |
| thiserror | 1.0 | 错误处理 |
| tracing | 0.1 | 结构化日志 |

### 3.3 开发工具链

- **构建工具**: Cargo (Rust), flutter_tools (Flutter)
- **代码生成**: flutter_rust_bridge_codegen
- **IDE**: VS Code, IntelliJ IDEA
- **版本控制**: Git
- **CI/CD**: GitHub Actions

---

## 4. 系统架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Presentation Layer (Flutter)                │
├─────────────────────────────────────────────────────────────────────┤
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐ │
│  │HomeScreen  │  │DeviceList  │  │ DebugConsole│  │ LuaScript  │ │
│  └────────────┘  └────────────┘  └────────────┘  └────────────┘ │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐                  │
│  │ PlotScreen │  │  Settings  │  │ MainShell  │                  │
│  └────────────┘  └────────────┘  └────────────┘                  │
├─────────────────────────────────────────────────────────────────────┤
│                      Bridge Layer (FFI)                            │
├─────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │         flutter_rust_bridge (Code Generation)               │  │
│  │  frb_generated.dart ↔ libs/runtime/src/api/*.rs           │  │
│  └─────────────────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────────────────────┤
│                       Core Logic Layer (Rust)                      │
├─────────────────────────────────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ Device   │  │ Protocol │  │ Transport│  │ Session  │        │
│  │ Registry │  │ Plugins  │  │  Layer   │  │ Manager  │        │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                      │
│  │ Virtual  │  │   Plot   │  │   Lua    │                      │
│  │  Device  │  │  Engine  │  │  Engine  │                      │
│  └──────────┘  └──────────┘  └──────────┘                      │
├─────────────────────────────────────────────────────────────────────┤
│                       Infrastructure Layer                          │
├─────────────────────────────────────────────────────────────────────┤
│  ┌────────────┐  ┌────────────┐  ┌────────────┐                  │
│  │  Serial    │  │ TCP/UDP    │  │  Virtual   │                  │
│  │  Port      │  │ Socket     │  │  Channel   │                  │
│  └────────────┘  └────────────┘  └────────────┘                  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 5. 分层架构

### 5.1 表现层 (Presentation Layer)

**职责**: 用户界面展示和交互处理

**关键组件**:
- **Screens**: 各个功能页面 (Home, DeviceList, DebugConsole等)
- **Widgets**: 可复用UI组件 (MainShell, StatusIndicator)
- **Routing**: 页面路由管理 (AppRoutes)
- **Theme**: 主题和样式管理 (AppTheme)

**技术实现**:
```dart
// 路由配置
class AppRoutes {
  static const String home = '/';
  static const String deviceList = '/devices';
  static const String debugConsole = '/debug';
  // ...
}
```

### 5.2 桥接层 (Bridge Layer)

**职责**: Flutter与Rust之间的FFI绑定

**关键技术**: flutter_rust_bridge
- 自动生成Dart和Rust之间的绑定代码
- 支持异步函数、结构体、枚举的跨语言传递
- 类型安全的数据转换

**工作流程**:
```
Dart Call → frb_generated.dart → FFI → Rust Function
Rust Result → FFI → frb_generated.dart → Dart Future
```

### 5.3 核心逻辑层 (Core Logic Layer)

**职责**: 业务逻辑和数据处理

**子模块**:
1. **Device Module**: 设备管理和注册
2. **Protocol Module**: 通信协议实现
3. **Transport Module**: 数据传输层
4. **Session Module**: 会话管理
5. **Virtual Device Module**: 虚拟设备仿真
6. **Plot Module**: 数据绘图引擎
7. **Lua Module**: 脚本引擎

### 5.4 基础设施层 (Infrastructure Layer)

**职责**: 底层系统资源访问

**组件**:
- 串口通信 (serialport crate)
- TCP/UDP网络通信 (tokio::net)
- 虚拟通道 (内存通道)
- 文件系统访问

---

## 6. 核心模块设计

### 6.1 设备管理层 (Device Module)

**类图**:
```
┌─────────────────────────────────────┐
│         DeviceRegistry             │
├─────────────────────────────────────┤
│ - devices: HashMap<String, Device> │
│ - config_path: PathBuf             │
├─────────────────────────────────────┤
│ + register_device(config)          │
│ + unregister_device(id)            │
│ + get_device(id)                   │
│ + list_devices()                   │
│ + save_config()                    │
│ + load_config()                    │
└─────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────┐
│           Device                    │
├─────────────────────────────────────┤
│ - config: DeviceConfig             │
│ - runtime: DeviceRuntime           │
│ - protocol: Box<dyn DeviceProtocol>│
│ - transport: Box<dyn Transport>    │
├─────────────────────────────────────┤
│ + connect()                        │
│ + disconnect()                     │
│ + send_command(cmd)                │
│ + receive_response()               │
│ + get_status()                     │
└─────────────────────────────────────┘
```

**设备状态机**:
```
[Disconnected] ──connect()──► [Connecting] ──success──► [Connected]
      ▲                              │                     │
      │                              │ failure             │ disconnect()
      │                              ▼                     ▼
      └────────────────────── [Error] ◄─────── [Disconnected]
```

**数据结构**:
```rust
pub struct DeviceConfig {
    pub name: String,
    pub device_type: String,
    pub connection_type: ConnectionType,
    pub address: String,
    pub protocol: Protocol,
    pub is_virtual: bool,
}

pub struct DeviceRuntime {
    pub status: DeviceStatus,
    pub last_seen: Option<DateTime<Utc>>,
    pub error_message: Option<String>,
}
```

### 6.2 协议层 (Protocol Module)

**Trait定义**:
```rust
#[async_trait]
pub trait DeviceProtocol: Send + Sync {
    async fn connect(&mut self, params: &ConnectionParams) -> Result<()>;
    async fn disconnect(&mut self) -> Result<()>;
    async fn send(&mut self, command: &str) -> Result<()>;
    async fn receive(&mut self) -> Result<String>;
    fn is_connected(&self) -> bool;
    fn protocol_name(&self) -> &'static str;
}
```

**插件架构**:
```
┌─────────────────────────────────────────┐
│           ProtocolRegistry             │
├─────────────────────────────────────────┤
│ - plugins: HashMap<String, Box<dyn    │
│           DeviceProtocolFactory>>      │
├─────────────────────────────────────────┤
│ + register(name, factory)             │
│ + create(name, params)                │
│ + list_supported()                    │
└─────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────┐
│         Protocol Implementations       │
├─────────────────────────────────────────┤
│ • ScpiProtocol                        │
│ • ModbusRtuProtocol                   │
│ • ModbusTcpProtocol                   │
│ • CsvProtocol                         │
│ • RawProtocol                         │
└─────────────────────────────────────────┘
```

**SCPI协议实现示例**:
```rust
pub struct ScpiProtocol {
    transport: Box<dyn Transport>,
    command_set: HashMap<String, String>, // 命令 -> 预期响应
}

#[async_trait]
impl DeviceProtocol for ScpiProtocol {
    async fn send(&mut self, command: &str) -> Result<()> {
        let scpi_cmd = format!("{}\n", command);
        self.transport.send(scpi_cmd.as_bytes()).await?;
        Ok(())
    }
    
    async fn receive(&mut self) -> Result<String> {
        let data = self.transport.receive().await?;
        let response = String::from_utf8_lossy(&data).trim().to_string();
        
        // SCPI响应验证
        if response.starts_with("ERROR") {
            return Err(Error::ScpiError(response));
        }
        
        Ok(response)
    }
}
```

### 6.3 传输层 (Transport Module)

**Trait定义**:
```rust
#[async_trait]
pub trait Transport: Send + Sync {
    async fn send(&mut self, data: &[u8]) -> Result<()>;
    async fn receive(&mut self) -> Result<Vec<u8>>;
    fn is_open(&self) -> bool;
    fn local_addr(&self) -> Option<String>;
    fn peer_addr(&self) -> Option<String>;
}
```

**传输层实现**:
```
┌──────────────────────────────────────┐
│          Transport Trait             │
└──────────────────────────────────────┘
          ▲
          │
    ┌─────┴─────┬─────────┬──────────┐
    ▼           ▼         ▼          ▼
SerialTransport  TcpTransport  VirtualTransport  ModbusTransport
```

**串口传输实现**:
```rust
pub struct SerialTransport {
    port: Box<dyn SerialPort>,
    timeout: Duration,
}

#[async_trait]
impl Transport for SerialTransport {
    async fn send(&mut self, data: &[u8]) -> Result<()> {
        self.port.write_all(data)?;
        self.port.flush()?;
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

**TCP传输实现**:
```rust
pub struct TcpTransport {
    stream: TcpStream,
    read_buffer: BytesMut,
}

#[async_trait]
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

### 6.4 会话管理层 (Session Module)

**功能**: 调试会话管理，记录命令历史和数据日志

**核心结构**:
```rust
pub struct DebugSession {
    pub session_id: String,
    pub device_id: String,
    pub start_time: DateTime<Utc>,
    pub command_history: VecDeque<CommandRecord>,
    pub data_log: Vec<DataRecord>,
    pub is_recording: bool,
}

pub struct CommandRecord {
    pub timestamp: DateTime<Utc>,
    pub command: String,
    pub response: String,
    pub latency_ms: u64,
}

pub struct DataRecord {
    pub timestamp: DateTime<Utc>,
    pub data: Vec<u8>,
    pub direction: DataDirection, // Sent | Received
}
```

**会话管理器**:
```rust
pub struct SessionManager {
    sessions: HashMap<String, DebugSession>,
    max_history_size: usize,
}

impl SessionManager {
    pub fn start_session(&mut self, device_id: &str) -> String {
        let session_id = Uuid::new_v4().to_string();
        let session = DebugSession::new(session_id.clone(), device_id.to_string());
        self.sessions.insert(session_id.clone(), session);
        session_id
    }
    
    pub fn log_command(&mut self, session_id: &str, command: &str, response: &str) {
        if let Some(session) = self.sessions.get_mut(session_id) {
            session.command_history.push_back(CommandRecord {
                timestamp: Utc::now(),
                command: command.to_string(),
                response: response.to_string(),
                latency_ms: 0, // 实际计算中
            });
            
            // 限制历史大小
            if session.command_history.len() > self.max_history_size {
                session.command_history.pop_front();
            }
        }
    }
}
```

### 6.5 虚拟设备模块 (Virtual Device Module)

**功能**: 模拟真实设备行为，用于测试和开发

**架构**:
```
┌──────────────────────────────────────────┐
│           VirtualDeviceManager          │
├──────────────────────────────────────────┤
│ - virtual_devices: HashMap<String,      │
│                     VirtualDevice>      │
│ - tcp_server: Option<TcpServer>         │
│ - virtual_serial: Option<VirtualSerial>  │
├──────────────────────────────────────────┤
│ + start_tcp_server(port)                │
│ + start_virtual_serial(port1, port2)    │
│ + register_virtual_device(device)        │
│ + simulate_response(device_id, command) │
└──────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────┐
│         VirtualDevice Trait              │
├──────────────────────────────────────────┤
│ + handle_command(&self, cmd: &str)      │
│   -> String                             │
│ + get_device_info(&self) -> DeviceInfo  │
│ + generate_data(&self) -> Vec<f64>      │
└──────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────┐
│      VirtualDevice Implementations      │
├──────────────────────────────────────────┤
│ • ScpiVirtualDevice                    │
│ • ModbusVirtualDevice                  │
│ • CustomVirtualDevice                  │
└──────────────────────────────────────────┘
```

**SCPI虚拟设备实现**:
```rust
pub struct ScpiVirtualDevice {
    pub device_id: String,
    pub device_info: DeviceInfo,
    pub command_handlers: HashMap<String, CommandHandler>,
    pub data_generator: Box<dyn DataGenerator>,
}

impl VirtualDevice for ScpiVirtualDevice {
    fn handle_command(&self, cmd: &str) -> String {
        match cmd.trim() {
            "*IDN?" => "VCR,Virtual-SCPI-Device,1.0".to_string(),
            "*RST" => "OK".to_string(),
            "MEASure:VOLTage?" => {
                let voltage = self.data_generator.generate_single();
                format!("{}", voltage)
            }
            "SYSTem:ERRor?" => "0,No error".to_string(),
            _ => "ERROR:Unknown command".to_string(),
        }
    }
}
```

**TCP服务器实现**:
```rust
pub struct TcpServer {
    listener: TcpListener,
    virtual_device: Arc<dyn VirtualDevice>,
}

impl TcpServer {
    pub async fn start(&self) -> Result<()> {
        loop {
            let (mut stream, addr) = self.listener.accept().await?;
            let device = self.virtual_device.clone();
            
            tokio::spawn(async move {
                let mut buffer = [0u8; 1024];
                
                loop {
                    let n = match stream.read(&mut buffer).await {
                        Ok(0) => break, // 连接关闭
                        Ok(n) => n,
                        Err(e) => {
                            eprintln!("Failed to read from {}: {}", addr, e);
                            break;
                        }
                    };
                    
                    let command = String::from_utf8_lossy(&buffer[..n]).trim().to_string();
                    let response = device.handle_command(&command);
                    
                    if let Err(e) = stream.write_all(response.as_bytes()).await {
                        eprintln!("Failed to write to {}: {}", addr, e);
                        break;
                    }
                }
            });
        }
    }
}
```

### 6.6 Lua脚本引擎模块 (Lua Module)

**功能**: 提供自动化脚本能力

**架构**:
```
┌───────────────────────────────────────┐
│           LuaEngine                   │
├───────────────────────────────────────┤
│ - lua: Lua                           │
│ - api_bindings: ApiBindings          │
│ - script_context: ScriptContext      │
├───────────────────────────────────────┤
│ + execute_script(script)             │
│ + register_api(name, func)           │
│ + set_global(name, value)            │
│ + get_global(name)                   │
└───────────────────────────────────────┘
          │
          ▼
┌───────────────────────────────────────┐
│        ApiBindings (VCR API)         │
├───────────────────────────────────────┤
│ • vcr.connect(device_id)             │
│ • vcr.disconnect(device_id)          │
│ • vcr.send(device_id, command)       │
│ • vcr.receive(device_id)             │
│ • vcr.plot.add_series(name, data)    │
│ • vcr.plot.update(name, value)       │
│ • vcr.sleep(ms)                      │
│ • vcr.log(message)                    │
└───────────────────────────────────────┘
```

**Lua引擎实现**:
```rust
pub struct LuaEngine {
    lua: Lua,
    device_registry: Arc<DeviceRegistry>,
    plot_engine: Arc<PlotEngine>,
}

impl LuaEngine {
    pub fn new(device_registry: Arc<DeviceRegistry>, plot_engine: Arc<PlotEngine>) -> Self {
        let lua = Lua::new();
        
        let mut engine = Self {
            lua,
            device_registry,
            plot_engine,
        };
        
        engine.register_api();
        engine
    }
    
    fn register_api(&mut self) {
        self.lua.context(|lua_ctx| {
            let globals = lua_ctx.globals();
            
            // 创建 vcr 表
            let vcr_table = lua_ctx.create_table().unwrap();
            
            // vcr.connect(device_id)
            let device_registry = self.device_registry.clone();
            vcr_table.set("connect", lua_ctx.create_function(move |_, device_id: String| {
                tokio::runtime::Handle::current().block_on(async {
                    device_registry.connect(&device_id).await
                }).map_err(|e| rlua::Error::RuntimeError(e.to_string()))?;
                Ok(())
            }).unwrap()).unwrap();
            
            // vcr.send(device_id, command)
            let device_registry = self.device_registry.clone();
            vcr_table.set("send", lua_ctx.create_function(move |_, (device_id, command): (String, String)| {
                tokio::runtime::Handle::current().block_on(async {
                    device_registry.send_command(&device_id, &command).await
                }).map_err(|e| rlua::Error::RuntimeError(e.to_string()))?;
                Ok(())
            }).unwrap()).unwrap();
            
            // vcr.plot.add_series(name, data)
            let plot_engine = self.plot_engine.clone();
            vcr_table.set("plot", lua_ctx.create_table().unwrap()).unwrap();
            let plot_table = vcr_table.get::<_, rlua::Table>("plot").unwrap();
            
            let plot_engine_clone = plot_engine.clone();
            plot_table.set("add_series", lua_ctx.create_function(move |_, (name, data): (String, rlua::Table)| {
                let data_vec: Vec<f64> = data.sequence_values().collect();
                plot_engine_clone.add_series(&name, &data_vec);
                Ok(())
            }).unwrap()).unwrap();
            
            globals.set("vcr", vcr_table).unwrap();
        });
    }
    
    pub fn execute(&self, script: &str) -> Result<String> {
        self.lua.context(|lua_ctx| {
            let result: rlua::Value = lua_ctx.load(script).eval()
                .map_err(|e| Error::LuaError(e.to_string()))?;
            
            Ok(format!("{:?}", result))
        })
    }
}
```

**Lua脚本示例**:
```lua
-- 自动测量电压脚本
vcr.connect("device_001")

for i = 1, 10 do
    vcr.send("device_001", "MEASure:VOLTage?")
    local response = vcr.receive("device_001")
    
    -- 解析响应并绘图
    local voltage = tonumber(response)
    vcr.plot.update("voltage", voltage)
    
    vcr.sleep(1000) -- 等待1秒
end

vcr.disconnect("device_001")
```

### 6.7 数据绘图模块 (Plot Module)

**功能**: 实时数据可视化

**核心结构**:
```rust
pub struct PlotEngine {
    series: Arc<Mutex<HashMap<String, DataSeries>>>,
    max_points: usize,
}

pub struct DataSeries {
    pub name: String,
    pub x_data: Vec<f64>, // 时间戳
    pub y_data: Vec<f64>, // 数据值
    pub color: (u8, u8, u8), // RGB颜色
    pub line_style: LineStyle,
}

pub enum LineStyle {
    Solid,
    Dashed,
    Dotted,
}
```

**Flutter端实现**:
```dart
class PlotScreen extends StatefulWidget {
  @override
  _PlotScreenState createState() => _PlotScreenState();
}

class _PlotScreenState extends State<PlotScreen> {
  List<LineChartBarData> _series = [];
  
  @override
  void initState() {
    super.initState();
    _startDataUpdate();
  }
  
  void _startDataUpdate() {
    Timer.periodic(Duration(milliseconds: 100), (timer) {
      setState(() {
        // 从Rust获取数据并更新图表
        final data = PlotApi.getSeriesData();
        _updateChart(data);
      });
    });
  }
  
  void _updateChart(Map<String, List<FlSpot>> data) {
    _series = data.entries.map((entry) {
      return LineChartBarData(
        spots: entry.value,
        isCurved: true,
        colors: [_getColorForSeries(entry.key)],
        barWidth: 2,
        isStrokeCapRound: true,
      );
    }).toList();
  }
  
  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        gridData: FlGridData(show: true),
        titlesData: FlTitlesData(show: true),
        borderData: FlBorderData(show: true),
        lineBarsData: _series,
      ),
    );
  }
}
```

---

## 7. 数据流向

### 7.1 设备控制数据流

```
┌──────────┐    ┌────────────┐    ┌────────────┐    ┌────────────┐
│  User    │───►│  Flutter   │───►│    FFI     │───►│    Rust    │
│  Action  │    │    UI      │    │   Bridge   │    │   Core     │
└──────────┘    └────────────┘    └────────────┘    └────────────┘
                                                         │
                                                         ▼
                                                   ┌────────────┐
                                                   │  Protocol  │
                                                   │  Plugin    │
                                                   └────────────┘
                                                         │
                                                         ▼
                                                   ┌────────────┐
                                                   │  Transport │
                                                   │   Layer    │
                                                   └────────────┘
                                                         │
                                                         ▼
                                                   ┌────────────┐
                                                   │  Hardware  │
                                                   │  Device    │
                                                   └────────────┘
```

**详细流程** (以发送SCPI命令为例):

1. **用户输入**: 在DebugConsoleScreen输入 `*IDN?`
2. **UI处理**: `DebugConsoleScreen.onSendPressed()` 被调用
3. **FFI调用**: `device_api.sendCommand(deviceId, "*IDN?")`
4. **Rust处理**: 
   - `DeviceApi::send_command()` 找到对应Device
   - `Device::send_command()` 调用 `Protocol::send()`
   - `ScpiProtocol::send()` 格式化命令为 `*\n`
   - `Transport::send()` 发送字节流
5. **设备响应**: 硬件设备返回响应数据
6. **数据回传**:
   - `Transport::receive()` 接收字节流
   - `ScpiProtocol::receive()` 解析为字符串
   - `DeviceApi::send_command()` 返回 `Result<String>`
   - FFI转换为Dart `Future<String>`
7. **UI更新**: `DebugConsoleScreen` 显示响应

### 7.2 实时数据绘图流

```
┌────────────┐    ┌────────────┐    ┌────────────┐    ┌────────────┐
│  Device    │───►│  Transport │───►│    Data    │───►│   Plot    │
│  (Data     │    │   Layer    │    │  Buffer    │    │  Engine   │
│   Stream)  │    │            │    │            │    │            │
└────────────┘    └────────────┘    └────────────┘    └────────────┘
                                                         │
                                                         ▼
                                                   ┌────────────┐
                                                   │  Flutter   │
                                                   │   Chart    │
                                                   │  (UI)      │
                                                   └────────────┘
```

**关键优化**:
- 使用环形缓冲区限制内存使用
- 批量更新UI (100ms间隔)
- 数据降采样 (显示最近1000点)

---

## 8. 关键设计模式

### 8.1 插件化架构 (Plugin Architecture)

**应用场景**: 协议支持、传输层

**实现**:
```rust
// 插件Trait
pub trait Plugin: Send + Sync {
    fn name(&self) -> &'static str;
    fn initialize(&mut self) -> Result<()>;
    fn shutdown(&mut self) -> Result<()>;
}

// 插件注册表
pub struct PluginRegistry {
    plugins: HashMap<String, Box<dyn Plugin>>,
}

impl PluginRegistry {
    pub fn register(&mut self, plugin: Box<dyn Plugin>) {
        let name = plugin.name().to_string();
        self.plugins.insert(name, plugin);
    }
    
    pub fn get(&self, name: &str) -> Option<&dyn Plugin> {
        self.plugins.get(name).map(|p| &**p)
    }
}
```

### 8.2 策略模式 (Strategy Pattern)

**应用场景**: 不同协议的不同处理方式

**实现**:
```rust
pub trait CommandHandler {
    fn handle(&self, cmd: &str) -> String;
}

pub struct ScpiCommandHandler;
pub struct ModbusCommandHandler;

impl CommandHandler for ScpiCommandHandler {
    fn handle(&self, cmd: &str) -> String {
        // SCPI特定处理逻辑
    }
}

impl CommandHandler for ModbusCommandHandler {
    fn handle(&self, cmd: &str) -> String {
        // Modbus特定处理逻辑
    }
}

// 使用
let handler: Box<dyn CommandHandler> = match protocol {
    Protocol::Scpi => Box::new(ScpiCommandHandler),
    Protocol::ModbusRtu => Box::new(ModbusCommandHandler),
    _ => unimplemented!(),
};

let response = handler.handle(command);
```

### 8.3 观察者模式 (Observer Pattern)

**应用场景**: 实时数据更新通知

**Rust端实现**:
```rust
pub struct DataSubject {
    observers: Vec<Box<dyn DataObserver>>,
    data: Vec<f64>,
}

pub trait DataObserver {
    fn on_data_updated(&mut self, data: &[f64]);
}

impl DataSubject {
    pub fn attach(&mut self, observer: Box<dyn DataObserver>) {
        self.observers.push(observer);
    }
    
    pub fn set_data(&mut self, data: Vec<f64>) {
        self.data = data;
        self.notify_observers();
    }
    
    fn notify_observers(&mut self) {
        for observer in &mut self.observers {
            observer.on_data_updated(&self.data);
        }
    }
}
```

**Flutter端实现**:
```dart
class PlotScreen extends StatefulWidget {
  @override
  _PlotScreenState createState() => _PlotScreenState();
}

class _PlotScreenState extends State<PlotScreen> implements DataObserver {
  @override
  void initState() {
    super.initState();
    DataSubject.instance.attach(this);
  }
  
  @override
  void onDataUpdated(List<double> data) {
    setState(() {
      // 更新图表数据
    });
  }
}
```

### 8.4 工厂模式 (Factory Pattern)

**应用场景**: 创建不同类型的协议实例

**实现**:
```rust
pub trait ProtocolFactory {
    fn create(&self, params: &ConnectionParams) -> Box<dyn DeviceProtocol>;
}

pub struct ScpiProtocolFactory;

impl ProtocolFactory for ScpiProtocolFactory {
    fn create(&self, params: &ConnectionParams) -> Box<dyn DeviceProtocol> {
        Box::new(ScpiProtocol::new(params))
    }
}

// 使用
let factory: Box<dyn ProtocolFactory> = match protocol_type {
    Protocol::Scpi => Box::new(ScpiProtocolFactory),
    _ => unimplemented!(),
};

let protocol = factory.create(&params);
```

### 8.5 单例模式 (Singleton Pattern)

**应用场景**: 全局设备管理、会话管理

**Rust实现** (使用 lazy_static):
```rust
use lazy_static::lazy_static;
use std::sync::Mutex;

lazy_static! {
    pub static ref DEVICE_REGISTRY: Mutex<DeviceRegistry> = {
        Mutex::new(DeviceRegistry::new())
    };
    
    pub static ref SESSION_MANAGER: Mutex<SessionManager> = {
        Mutex::new(SessionManager::new())
    };
}
```

---

## 9. 模块依赖关系

### 9.1 依赖图

```
┌─────────────────────────────────────────────────────────────┐
│                    Flutter UI Layer                        │
│  (HomeScreen, DeviceListScreen, DebugConsoleScreen, etc.)  │
└────────────────────┬────────────────────────────────────────┘
                     │ depends on
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                  API Bridge Layer                          │
│  (device_api.dart, debug_api.dart, lua_api.dart, etc.)     │
└────────────────────┬────────────────────────────────────────┘
                     │ FFI
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                Rust Core Logic Layer                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌────────────┐   ┌────────────┐   ┌────────────┐         │
│  │   Device   │◄──│  Protocol  │◄──│  Transport │         │
│  │   Module   │   │   Module   │   │   Module   │         │
│  └────────────┘   └────────────┘   └────────────┘         │
│        │                │                │                   │
│        ▼                ▼                ▼                   │
│  ┌────────────┐   ┌────────────┐   ┌────────────┐         │
│  │  Session   │   │   Plot     │   │    Lua     │         │
│  │  Module    │   │   Module   │   │   Module   │         │
│  └────────────┘   └────────────┘   └────────────┘         │
│        │                │                │                   │
│        └────────────────┴────────────────┘                   │
│                         ▼                                   │
│               ┌──────────────────┐                          │
│               │ Virtual Device   │                          │
│               │    Module        │                          │
│               └──────────────────┘                          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│              Infrastructure Layer                           │
│  (Serial Port, TCP Socket, File System, etc.)              │
└─────────────────────────────────────────────────────────────┘
```

### 9.2 依赖关系说明

| 模块 | 依赖模块 | 说明 |
|------|----------|------|
| Device Module | Protocol Module, Transport Module | 设备使用协议和传输层 |
| Protocol Module | Transport Module | 协议需要传输层发送数据 |
| Session Module | Device Module | 会话管理设备连接 |
| Plot Module | Device Module | 绘图需要从设备获取数据 |
| Lua Module | Device Module, Plot Module | Lua脚本控制设备和绘图 |
| Virtual Device Module | Protocol Module, Transport Module | 虚拟设备模拟真实设备行为 |

---

## 10. 部署架构

### 10.1 Windows部署

**构建流程**:
```bash
# 1. 构建Rust库
cd rust
cargo build --release

# 2. 生成FFI绑定
flutter_rust_bridge_codegen --rust-input rust/src/api/*.rs --dart-output lib/src/rust/

# 3. 构建Flutter应用
flutter build windows --release

# 4. 打包
# 使用msix或Inno Setup创建安装包
```

**输出结构**:
```
VCR/
├── vcr.exe                    # 主可执行文件
├── data/
│   └── flutter_assets/        # Flutter资源
├── rust/
│   └── rust_lib_vcr.dll       # Rust动态库
├── plugins/
│   ├── protocol_plugins/      # 协议插件
│   └── transport_plugins/     # 传输层插件
├── config/
│   ├── app_config.json        # 应用配置
│   └── device_config.json     # 设备配置
└── logs/
    └── vcr.log                # 日志文件
```

### 10.2 Linux部署

**构建流程**:
```bash
# 1. 安装依赖
sudo apt-get install libgtk-3-dev libwebkit2gtk-4.0-dev

# 2. 构建Rust库
cd rust
cargo build --release

# 3. 生成FFI绑定
flutter_rust_bridge_codegen --rust-input rust/src/api/*.rs --dart-output lib/src/rust/

# 4. 构建Flutter应用
flutter build linux --release

# 5. 打包
# 创建AppImage或.deb包
```

**输出结构**:
```
vcr/
├── vcr                        # 主可执行文件
├── data/
│   └── flutter_assets/
├── lib/
│   └── librust_lib_vcr.so
├── plugins/
├── config/
└── logs/
```

---

## 11. 性能优化策略

### 11.1 Rust端优化

**异步处理**:
```rust
// 使用Tokio异步运行时
#[async_trait]
impl DeviceProtocol for ScpiProtocol {
    async fn send(&mut self, command: &str) -> Result<()> {
        self.transport.send(command.as_bytes()).await?;
        Ok(())
    }
}
```

**零拷贝**:
```rust
// 使用Bytes类型避免拷贝
use bytes::Bytes;

pub async fn receive(&mut self) -> Result<Bytes> {
    let mut buffer = BytesMut::with_capacity(1024);
    self.stream.read_buf(&mut buffer).await?;
    Ok(buffer.freeze())
}
```

**内存池**:
```rust
// 重用缓冲区
lazy_static! {
    static ref BUFFER_POOL: Mutex<Vec<Vec<u8>>> = Mutex::new(Vec::new());
}

pub fn get_buffer() -> Vec<u8> {
    BUFFER_POOL.lock().unwrap().pop().unwrap_or_else(|| vec![0u8; 1024])
}

pub fn return_buffer(buf: Vec<u8>) {
    BUFFER_POOL.lock().unwrap().push(buf);
}
```

### 11.2 Flutter端优化

**懒加载**:
```dart
// 路由懒加载
MaterialPageRoute(
  builder: (_) => MainShell(
    child: FutureBuilder(
      future: _loadData(),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return DeviceListScreen(devices: snapshot.data!);
        } else {
          return CircularProgressIndicator();
        }
      },
    ),
  ),
)
```

**虚拟化列表**:
```dart
ListView.builder(
  itemCount: devices.length,
  itemBuilder: (context, index) {
    return DeviceTile(device: devices[index]);
  },
)
```

**图片缓存**:
```dart
CachedNetworkImage(
  imageUrl: device.iconUrl,
  placeholder: (context, url) => CircularProgressIndicator(),
  errorWidget: (context, url, error) => Icon(Icons.error),
)
```

---

## 12. 安全性设计

### 12.1 Lua沙箱

**限制Lua脚本权限**:
```rust
impl LuaEngine {
    fn create_sandbox(&self) -> Lua {
        let lua = Lua::new();
        
        lua.context(|lua_ctx| {
            let globals = lua_ctx.globals();
            
            // 移除危险函数
            globals.set("os", rlua::Value::Nil).unwrap();
            globals.set("io", rlua::Value::Nil).unwrap();
            globals.set("require", rlua::Value::Nil).unwrap();
            
            // 仅保留安全的API
            let safe_api = lua_ctx.create_table().unwrap();
            // ... 注册安全的vcr API
            globals.set("vcr", safe_api).unwrap();
        });
        
        lua
    }
}
```

### 12.2 输入验证

**设备ID验证**:
```rust
pub fn validate_device_id(id: &str) -> Result<()> {
    let re = Regex::new(r"^[a-zA-Z0-9_-]{1,64}$").unwrap();
    
    if !re.is_match(id) {
        return Err(Error::InvalidDeviceId(id.to_string()));
    }
    
    Ok(())
}
```

**命令注入防护**:
```rust
pub fn sanitize_command(cmd: &str) -> String {
    // 移除危险字符
    cmd.replace(';', "")
       .replace('&', "")
       .replace('|', "")
       .trim()
       .to_string()
}
```

### 12.3 加密存储

**敏感信息加密**:
```rust
use aes_gcm::{Aes256Gcm, Key, Nonce};
use aes_gcm::aead::{Aead, NewAead};

pub fn encrypt_password(password: &str, key: &[u8]) -> Result<Vec<u8>> {
    let key = Key::from_slice(key);
    let cipher = Aes256Gcm::new(key);
    
    let nonce = Nonce::from_slice(b"unique nonce"); // 实际应使用随机nonce
    
    cipher.encrypt(nonce, password.as_bytes().as_ref())
        .map_err(|e| Error::EncryptionError(e.to_string()))
}
```

---

## 13. 扩展性设计

### 13.1 协议扩展

**添加新协议**:
1. 在 `rust/src/core/protocol/plugins/` 创建新文件
2. 实现 `DeviceProtocol` trait
3. 在 `protocol/registry.rs` 中注册

**示例: 添加CANoe协议**:
```rust
// rust/src/core/protocol/plugins/canoe.rs
pub struct CanoeProtocol {
    transport: Box<dyn Transport>,
}

impl DeviceProtocol for CanoeProtocol {
    // ... 实现方法
}

// 注册
registry.register("Canoe", Box::new(CanoeProtocolFactory));
```

### 13.2 传输层扩展

**添加新传输层**:
1. 在 `rust/src/core/transport/` 创建新文件
2. 实现 `Transport` trait
3. 在设备配置中添加新选项

**示例: 添加WebSocket传输**:
```rust
// rust/src/core/transport/websocket.rs
pub struct WebSocketTransport {
    ws_stream: WebSocketStream<TcpStream>,
}

#[async_trait]
impl Transport for WebSocketTransport {
    async fn send(&mut self, data: &[u8]) -> Result<()> {
        self.ws_stream.send(Message::Binary(data.to_vec())).await?;
        Ok(())
    }
    
    async fn receive(&mut self) -> Result<Vec<u8>> {
        let msg = self.ws_stream.next().await?;
        match msg {
            Message::Binary(data) => Ok(data),
            _ => Err(Error::InvalidDataFormat),
        }
    }
}
```

### 13.3 UI扩展

**添加新屏幕**:
1. 在 `lib/screens/` 创建新Dart文件
2. 在 `app/routes.dart` 中添加路由
3. 在 `widgets/main_shell.dart` 中添加导航项

---

## 14. 测试策略

### 14.1 单元测试

**Rust单元测试**:
```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_device_registry() {
        let mut registry = DeviceRegistry::new();
        
        let config = DeviceConfig {
            name: "Test Device".to_string(),
            // ...
        };
        
        let id = registry.register(config);
        assert!(!id.is_empty());
        
        let device = registry.get(&id);
        assert!(device.is_some());
    }
}
```

**Dart单元测试**:
```dart
import 'package:test/test.dart';

void main() {
  test('Device list loads correctly', () async {
    final devices = await DeviceApi.listDevices();
    expect(devices, isA<List<DeviceInfo>>());
  });
}
```

### 14.2 集成测试

**使用虚拟设备测试**:
```rust
#[tokio::test]
async fn test_full_communication_flow() {
    // 启动虚拟设备
    let virtual_device = ScpiVirtualDevice::new();
    let server = TcpServer::new("127.0.0.1:5025", virtual_device);
    tokio::spawn(async move {
        server.start().await.unwrap();
    });
    
    // 创建真实设备连接
    let mut device = Device::new(DeviceConfig {
        connection_type: ConnectionType::Tcp,
        address: "127.0.0.1:5025".to_string(),
        protocol: Protocol::Scpi,
        ..Default::default()
    });
    
    // 测试连接
    device.connect().await.unwrap();
    
    // 测试发送命令
    device.send_command("*IDN?").await.unwrap();
    let response = device.receive_response().await.unwrap();
    
    assert_eq!(response, "VCR,Virtual-SCPI-Device,1.0");
    
    device.disconnect().await.unwrap();
}
```

### 14.3 UI测试

**Flutter Widget测试**:
```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Device list displays correctly', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DeviceListScreen(),
    ));
    
    expect(find.text('Device List'), findsOneWidget);
    expect(find.byType(ListTile), findsWidgets);
  });
}
```

---

## 15. 附录

### 15.1 配置文件示例

**app_config.json**:
```json
{
  "theme": "dark",
  "auto_reconnect": true,
  "log_level": "info",
  "device_sort_order": ["device_001", "device_002"],
  "last_connected_devices": ["device_001"]
}
```

**device_config.json**:
```json
{
  "devices": [
    {
      "id": "device_001",
      "name": "Oscilloscope",
      "device_type": "Oscilloscope",
      "connection_type": "Tcp",
      "address": "192.168.1.100:5025",
      "protocol": "Scpi",
      "is_virtual": false
    }
  ]
}
```

### 15.2 错误码定义

| 错误码 | 描述 |
|--------|------|
| 0 | 成功 |
| 1001 | 设备未找到 |
| 1002 | 连接失败 |
| 1003 | 命令执行失败 |
| 1004 | 协议不支持 |
| 1005 | 传输层错误 |
| 2001 | Lua脚本错误 |
| 2002 | 绘图引擎错误 |

### 15.3 术语表

| 术语 | 定义 |
|------|------|
| SCPI | Standard Commands for Programmable Instruments |
| Modbus | 一种串行通信协议 |
| FFI | Foreign Function Interface |
| Trait | Rust的接口概念 |
| Widget | Flutter的UI组件 |
| Virtual Device | 模拟真实设备行为的软件实体 |

---

**文档结束**

---

**修订历史**:

| 版本 | 日期 | 作者 | 变更说明 |
|------|------|------|----------|
| 1.0 | 2026-05-18 | AI架构分析师 | 初始版本 |

---

**联系方式**:
- 项目主页: [待定]
- 问题反馈: [待定]
- 文档更新: [待定]
