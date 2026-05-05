# VCR — 仪器上位机 架构设计与重建 Prompt 文档

> 版本：2026-04-25 | 项目代号：VCR | 原名：instrument_upper_computer

---

## 1. 项目概述

VCR 是一款 **仪器上位机软件**，用于通过串口/TCP 连接和控制各类测量仪器（万用表、示波器、电源、传感器等）。采用 Flutter UI + Rust 数据服务层的混合架构，目标平台为 Windows 桌面。

**核心能力：**
- 串口 (COM) / TCP 网络设备连接
- SCPI / Modbus RTU / Modbus TCP / Raw / 私有协议 支持
- 虚拟设备模拟（TCP-SCPI 服务器 + 虚拟串口对），无需真实硬件即可开发调试
- 全功能串口调试控制台（收发、HEX/ASCII、时间戳、日志导出、连续发送等）
- 设备参数编辑、持久化、自动重连

---

## 2. 技术栈

| 层 | 技术 | 版本 |
|---|------|------|
| UI | Flutter (Dart) | 3.41.7 / SDK ^3.11.5 |
| 数据服务 | Rust | 1.95.0 (MSVC x64) |
| 桥接 | flutter_rust_bridge | 2.12.0 |
| 异步运行时 | tokio | 1.x (full features) |
| 串口 | tokio-serial 5.4 + serialport 4.6 | |
| 序列化 | serde + serde_json | 1.x |
| 序列化/UUID | uuid | 1.x (v4, serde) |
| 并发锁 | parking_lot | 0.12 |
| 随机数 | rand | 0.8 |
| 文件选择 | file_picker | ^8.0.0 |
| GBK 编码 | gbk_codec | ^0.4.0 |

**构建工具链：**
- MSVC v143 (Visual Studio Build Tools)
- CMake 3.x + Ninja (Flutter Windows 构建后端)
- Windows 11 x64，开发者模式已启用

**镜像源：**
- Cargo: rsproxy.cn
- Flutter/Dart: pub.flutter-io.cn（备选 mirrors.tuna.tsinghua.edu.cn）
- Flutter SDK: mirrors.tuna.tsinghua.edu.cn

---

## 3. 项目结构

```
instrument_upper_computer/
├── lib/                          # Flutter/Dart 源码
│   ├── main.dart                 # 入口：初始化 FRB → 启动虚拟设施 → 加载设备 → 自动重连
│   ├── app/
│   │   ├── theme.dart            # AppTheme 暗色工业风配色
│   │   └── routes.dart           # 路由定义 (onGenerateRoute)
│   ├── screens/
│   │   ├── home_screen.dart      # Dashboard：统计卡片 + 设备状态列表（3s 自动刷新）
│   │   ├── device_list_screen.dart  # 设备管理：添加/编辑/删除/连接/排序
│   │   ├── device_detail_screen.dart # 设备详情
│   │   ├── data_monitor_screen.dart  # 数据监控（占位）
│   │   ├── debug_console_screen.dart # 串口调试控制台（~600行）
│   │   └── settings_screen.dart  # 设置：Auto Reconnect / 数据采集 / 外观
│   ├── widgets/
│   │   ├── main_shell.dart       # 主布局：NavigationRail (Dashboard/Devices/Monitor/Console/Settings)
│   │   └── status_indicator.dart # 状态指示灯
│   └── src/rust/                 # FRB 自动生成的 Dart 绑定
│       ├── frb_generated.dart
│       ├── api/                  # API 绑定 (device_api, debug_api, virtual_api)
│       └── core/                 # Core 绑定 (models, debug_session, simulator)
│
├── rust/                         # Rust 源码
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs                # pub mod api; pub mod core;
│       ├── frb_generated.rs      # FRB 自动生成
│       ├── api/                  # FRB 桥接层（零业务逻辑，仅类型转换 + 委托）
│       │   ├── mod.rs
│       │   ├── simple.rs         # greet() 示例
│       │   ├── device_api.rs     # 设备 CRUD、连接/断开、串口扫描、持久化
│       │   ├── debug_api.rs      # 调试连接、收发、日志管理、后台接收循环
│       │   └── virtual_api.rs    # 虚拟基础设施控制
│       └── core/                 # 业务逻辑层
│           ├── mod.rs
│           ├── app_context.rs    # 全局单例（RT/REGISTRY/SIMULATORS/DEBUG/SESSIONS）
│           ├── device/
│           │   ├── models.rs     # 数据模型（ConnectionType/DeviceStatus/Protocol/DeviceInfo等）
│           │   ├── registry.rs   # DeviceRegistry（CRUD，parking_lot::RwLock）
│           │   └── preset.rs     # 虚拟设备预设 + Demo 设备预设
│           ├── transport/
│           │   ├── mod.rs        # Transport trait + TransportError
│           │   ├── serial.rs     # SerialTransport + WMI 友好名称扫描
│           │   ├── tcp.rs        # TcpTransport
│           │   ├── virtual_channel.rs # VirtualChannelTransport (mpsc+broadcast)
│           │   └── modbus.rs     # ModbusCodec（CRC16，暂未完整集成）
│           ├── session/
│           │   ├── session_manager.rs # SessionManager（连接池，ActiveSession 枚举）
│           │   └── debug_session.rs   # DebugSessionManager（日志记录+缓冲区裁剪）
│           └── virtual_device/
│               ├── simulator.rs       # SimulatorManager + TcpSimulator + SerialPairSimulator
│               ├── scpi_responder.rs  # SCPI 命令处理器（纯逻辑，无 I/O）
│               └── data_generator.rs  # 波形数据生成器
│
├── windows/                      # Flutter Windows 壳
│   └── runner/
│       ├── main.cpp              # 窗口标题 "VCR"
│       └── Runner.rc             # 版本信息
├── flutter_rust_bridge.yaml      # FRB 配置
├── pubspec.yaml
└── analysis_options.yaml
```

---

## 4. 核心架构

### 4.1 全局单例（app_context.rs）

使用 `lazy_static!` 创建 5 个进程级全局单例，避免临时 `Runtime::new()` 被 drop 导致任务取消：

```rust
lazy_static! {
    pub static ref RT: tokio::runtime::Runtime;           // 全局 tokio 运行时
    pub static ref REGISTRY: DeviceRegistry;              // 设备注册表
    pub static ref SIMULATORS: SimulatorManager;          // 虚拟设备管理
    pub static ref DEBUG: DebugSessionManager;            // 调试日志管理
    pub static ref SESSIONS: SessionManager;              // 连接会话管理
}

pub fn block_on<F, T>(future: F) -> T { RT.block_on(future) }
```

所有 FRB API 均为 `#[frb(sync)]` 同步函数，通过 `block_on()` 在全局 RT 上执行异步操作。

### 4.2 Transport 抽象层

```rust
#[async_trait]
pub trait Transport: Send + Sync {
    async fn connect(&mut self) -> Result<(), TransportError>;
    async fn disconnect(&mut self) -> Result<(), TransportError>;
    async fn send(&mut self, data: &[u8]) -> Result<(), TransportError>;
    async fn receive(&mut self) -> Result<Vec<u8>, TransportError>;
    fn is_connected(&self) -> bool;
}
```

三种实现：

| Transport | 底层 | 配置 | 超时 |
|-----------|------|------|------|
| SerialTransport | tokio-serial | SerialConfig {port, baud_rate, data_bits, stop_bits, parity, flow_control} | 200ms read |
| TcpTransport | tokio::net::TcpStream | TcpConfig {host, port, timeout_ms} | 200ms read, 5s connect |
| VirtualChannelTransport | mpsc + broadcast channel | 传入 cmd_tx + response_rx | 200ms recv |

**TransportError：** ConnectionFailed / Disconnected / SendError / ReceiveError / Timeout / InvalidConfig

### 4.3 SessionManager（连接池）

```
ActiveSession 枚举:
├── Serial(Arc<Mutex<SerialTransport>>)
├── Tcp(Arc<Mutex<TcpTransport>>)
└── Virtual(Arc<Mutex<VirtualChannelTransport>>)
```

- `Arc<Mutex<Transport>>` 包装实现并发收发（send 持锁期间不阻塞 receive）
- 连接路由逻辑：`device.is_virtual` → `connect_virtual()` / `connect_real()`
- 虚拟 TCP 设备 → 实际走真实 TcpTransport（连接 127.0.0.1:5025）
- 虚拟串口设备 → VirtualChannelTransport（从 SimulatorManager 获取 channel pair）

### 4.4 虚拟设备架构

```
SimulatorManager
├── TcpSimulator (127.0.0.1:5025)
│   └── TcpListener → accept → spawn handle_scpi_client
│       └── BufReader.lines() → ScpiResponder.handle_command() → write response
└── SerialPairSimulator (COM1 ↔ COM2)
    ├── cmd_tx: mpsc::UnboundedSender<Vec<u8>>    (用户→SCPI)
    ├── response_tx: broadcast::Sender<Vec<u8>>    (SCPI→用户)
    └── spawn: try_recv loop → ScpiResponder → broadcast send
```

### 4.5 SCPI 命令处理器（scpi_responder.rs）

纯逻辑，无 I/O，支持：

| 命令 | 响应 |
|------|------|
| `*IDN?` | 设备标识 "QClaw Virtual Instrument v1.0" |
| `*RST` | 恢复默认状态 |
| `*CLS` | 清除错误队列 |
| `MEAS:VOLT?` | 电压测量 + 噪声 |
| `MEAS:CURR?` | 电流测量 + 噪声 |
| `MEAS:POW?` | 功率测量 |
| `MEAS:FREQ?` | 频率测量 |
| `MEAS:TEMP?` | 温度测量 |
| `OUTP ON/OFF` | 输出开关 |
| `VOLT/CURR/FREQ <value>` | 设置值 |
| `SYST:ERR?` | 错误队列查询 |
| `HELP?` | 帮助文本 |

内部状态：voltage / current / power / frequency / temperature / output_enabled / error_queue

### 4.6 Debug 日志系统

```
DebugSessionManager
├── sessions: Mutex<HashMap<String, DebugSessionInner>>
└── DebugSessionInner
    ├── log: Vec<DebugLogEntry>
    ├── connected: bool
    └── max_size: usize (默认 200KB)

DebugLogEntry { timestamp: i64, direction: "TX"/"RX"/"SYS"/"ERR", data: Vec<u8>, display: String }
```

- 自动裁剪：push_entry 时检查总大小，超限从头部删除旧条目
- 后台接收循环：`RECEIVE_TASKS: LazyLock<Mutex<HashMap<String, JoinHandle>>>>`
  - `spawn_receive_loop`: RT.spawn → 循环 receive → log_rx
  - Timeout 视为正常（继续轮询），真实错误 break

---

## 5. FRB 桥接 API 清单

所有 API 均为 `#[frb(sync)]` 同步函数，Dart 端调用不需要 `await`。

### device_api.rs

| 函数 | 签名 | 说明 |
|------|------|------|
| get_supported_protocols | () → Vec\<ProtocolInfo\> | 获取支持的协议列表 |
| list_devices | () → Vec\<DeviceInfo\> | 列出所有设备 |
| get_device | (device_id: String) → Option\<DeviceInfo\> | 获取单个设备 |
| add_serial_device | (name, port, baud_rate, protocol) → DeviceInfo | 添加串口设备 |
| add_tcp_device | (name, host, port, protocol) → DeviceInfo | 添加 TCP 设备 |
| update_device | (device_id, name, address, protocol) → bool | 更新设备参数 |
| remove_device | (device_id: String) → bool | 删除设备 |
| scan_serial_ports | () → Vec\<PortInfo\> | 扫描串口（10s缓存） |
| connect_device | (device_id: String) → bool | 连接设备 |
| disconnect_device | (device_id: String) → bool | 断开设备 |
| load_demo_devices | () → i32 | 加载演示设备 |
| clear_demo_devices | () → i32 | 清除演示设备 |
| save_devices | () → bool | 持久化到 devices.json |
| load_persisted_devices | () → i32 | 从 devices.json 加载 |

### debug_api.rs

| 函数 | 签名 | 说明 |
|------|------|------|
| debug_connect | (device_id: String) → bool | 调试连接 |
| debug_disconnect | (device_id: String) → bool | 调试断开 |
| debug_send_bytes | (device_id, data: Vec\<u8\>) → bool | 发送原始字节 |
| debug_send_string | (device_id, text, line_ending) → bool | 发送字符串（自动追加行尾） |
| debug_send_hex | (device_id, hex_string) → bool | 发送十六进制 |
| debug_receive | (device_id) → Option\<Vec\<u8\>\> | 手动接收（备用） |
| debug_get_log | (device_id) → Vec\<DebugLogEntry\> | 获取全部日志 |
| debug_get_log_with_limit | (device_id, max_size: i32) → Vec\<DebugLogEntry\> | 获取日志（带缓冲区限制） |
| debug_set_buffer_size | (device_id, max_size: i32) | 设置缓冲区大小 |
| debug_clear_log | (device_id) → bool | 清除日志 |
| debug_is_connected | (device_id) → bool | 检查连接状态 |
| debug_get_active_sessions | () → Vec\<String\> | 活跃调试会话列表 |

### virtual_api.rs

| 函数 | 签名 | 说明 |
|------|------|------|
| start_virtual_infrastructure | () → VirtualInfraStatus | 启动虚拟设施 |
| stop_virtual_infrastructure | () → bool | 停止虚拟设施 |
| get_virtual_infra_status | () → VirtualInfraStatus | 查询状态 |
| is_virtual_serial_running | () → bool | 虚拟串口是否运行 |

---

## 6. Flutter UI 架构

### 6.1 导航布局

```
MainShell (Scaffold + Row)
├── NavigationRail (5 项)
│   ├── Dashboard  (home_screen)
│   ├── Devices    (device_list_screen)
│   ├── Monitor    (data_monitor_screen, 占位)
│   ├── Console    (debug_console_screen)
│   └── Settings   (settings_screen)
└── Content Area (Expanded)
```

路由使用 `onGenerateRoute`，每个路由包裹在 `MainShell` 中。

### 6.2 主题（AppTheme）

暗色工业风配色：
- Background: `#0D1117` | Surface: `#161B22` | SurfaceVariant: `#21262D`
- Primary: `#58A6FF` (蓝) | Secondary/Success: `#3FB950` (绿)
- Warning: `#D29922` | Error: `#F85149`
- TextPrimary: `#C9D1D9` | TextSecondary: `#8B949E`
- Border: `#30363D`

### 6.3 Debug Console 功能清单

| 功能 | 实现细节 |
|------|---------|
| 设备选择 | DropdownButton，记住上次选择（console_config.json） |
| 连接/断开 | 单按钮切换，颜色随状态（绿/红/灰） |
| ASCII/HEX/FILE 发送模式 | DropdownButton 切换 |
| UTF-8/GBK 编码 | gbk_codec 包，Dart 端编码后通过 debugSendBytes 发送 |
| 行尾选择 | None/CR/LF/CRLF 下拉菜单 |
| HEX 输入过滤 | FilteringTextInputFormatter.allow([0-9A-Fa-f ]) |
| HEX 输入清理 | 切换到 HEX 模式时自动清除非法字符 |
| 连续发送 | Future.delayed 递归异步循环，间隔+次数配置对话框 |
| 收发数据计数 | Tx/Rx 字节数+包数，自动换算 B/KB/MB |
| 时间戳显示/隐藏 | 图标按钮切换，毫秒精度 HH:mm:ss.SSS |
| ASCII/HEX 显示切换 | 图标按钮，HEX 模式按字节空格分隔 |
| Tx/Rx 分别显示/隐藏 | 文字标签按钮 |
| 发送后保留输入 | 不清空输入框 |
| 缓冲区大小配置 | 手动输入（最大 500MB）+ 9 档快捷预设 |
| 日志可复制 | RichText + AppBar Copy Log 按钮 |
| 日志导出 | FilePicker saveFile + Export 按钮，路径持久化 |
| 命令历史 | 最近 10 条，DropdownButton 回填 |
| 快捷命令 | *IDN? / *RST / *CLS / SYST:ERR? |
| 自动滚动 | 用户滚动时暂停，滚回底部自动恢复 |
| 滚动条 | Scrollbar + interactive: true + ScrollConfiguration 禁用原生 |

### 6.4 Device List 功能

- 设备卡片：名称、状态灯、连接类型图标、地址、虚拟设备标记、错误信息
- Add Device 对话框：串口/TCP 分页、手动刷新端口、协议选择
- Edit 按钮：修改名称/地址/协议（已连接先断开）
- 按连接状态排序：已连接 → 历史连接 → 字母序
- 排序持久化：app_config.json

### 6.5 Dashboard

- 统计卡片：Connected / Disconnected / Error / Total
- 设备状态列表：3 秒自动刷新 (Timer.periodic)
- 点击设备 → 详情页

### 6.6 Settings

- Auto Reconnect on Startup（持久化到 app_config.json）
- 数据采集设置（采样率/缓冲区/日志）
- 外观（暗色模式/语言切换）
- 版本信息

---

## 7. 持久化方案

| 文件 | 路径 | 内容 |
|------|------|------|
| devices.json | %APPDATA%\instrument_upper_computer\ | 设备配置（DeviceInfo 序列化） |
| console_config.json | 同上 | Console 配置（lastSelectedDeviceId, continuousSend*, lastExportDir） |
| app_config.json | 同上 | 全局配置（autoReconnect, lastConnectedDevices, deviceSortOrder） |

### 启动顺序
1. `RustLib.init()` — 初始化 FRB
2. `startVirtualInfrastructure()` — 启动 TCP-SCPI 服务器 + 虚拟串口对
3. `loadPersistedDevices()` — 从 devices.json 加载已保存设备
4. 若加载 0 个设备 → `loadDemoDevices()` — 兜底加载演示设备
5. `_autoReconnectIfNeeded()` — 如果开启自动重连，重连上次连接的设备

---

## 8. 已修复的关键 Bug 记录

| Bug | 根因 | 修复 |
|-----|------|------|
| TCP 连接被拒绝 (os error 10061) | tcp.rs connect() 硬编码 127.0.0.1:8080，SCPI 服务器监听 5025 | 使用 TcpConfig.host/port |
| Add Device 对话框"没反应" | `late Protocol _protocol` 在新增分支未初始化，Release 模式静默吞异常 | 加默认值 Protocol.scpi |
| 串口扫描中文乱码 | PowerShell 输出 GBK，from_utf8_lossy 乱码 | `-EncodedCommand` + UTF-16LE base64 |
| 连续发送卡死 UI | Timer.periodic 回调内同步 FFI 调用占满 UI 线程 | 改为 `await Future.delayed` 递归异步循环 |
| None 行尾实际发送 LF | Rust match 缺少 `"" | "NONE" | "None"` 分支 | 补全 match 分支 |
| 双滚动条 | Windows 原生 + RawScrollbar 同时显示 | `ScrollConfiguration.copyWith(scrollbars: false)` |
| 文字无法选择 | SelectableText 与 Scrollbar 手势冲突 | 改用 RichText + Copy Log 按钮 |
| Flutter 构建失败 | pubspec.lock 为空 + 未设 PUB_HOSTED_URL | 删除 lock + 设置镜像环境变量 |

---

## 9. FRB 类型约束

FRB 不支持以下 Rust 类型，需要手动适配：

| Rust 类型 | 替代方案 |
|-----------|---------|
| `DateTime<Utc>` | `Option<String>` 或 `i64` 毫秒时间戳 |
| `chrono::Local::now()` | `SystemTime::now().duration_since(UNIX_EPOCH).as_millis() as i64` |
| `Box<dyn Transport>` | `ActiveSession` 枚举 + `Arc<Mutex<ConcreteTransport>>` |
| `async fn` | `#[frb(sync)]` + `block_on()` 包装 |

**所有 FRB API 为 sync 函数**，Dart 端调用不需要 `await`。

---

## 10. 构建流程

### 环境要求
- Flutter SDK 3.41.7+（PATH 中可用 `flutter`）
- Rust 1.95.0+（PATH 中可用 `cargo`）
- MSVC v143 Build Tools
- Windows 11 x64 开发者模式

### 构建命令

```powershell
# 设置镜像
$env:PUB_HOSTED_URL="https://pub.flutter-io.cn"

# 进入项目
cd D:\AI\upper_computer_tools\instrument_upper_computer

# 清理（如需全新构建）
flutter clean
Remove-Item pubspec.lock -ErrorAction SilentlyContinue

# 获取依赖
flutter pub get

# Rust 端编译通过后，FRB 生成绑定（通常 build 自动触发）
# 如需手动：flutter_rust_bridge_codegen generate

# 构建 Release
flutter build windows --release

# 输出路径
# build\windows\x64\runner\Release\instrument_upper_computer.exe
```

### 常见构建问题

1. **pubspec.lock 为空** → 删除后重新 `flutter pub get`
2. **清华镜像 502** → 换用 `pub.flutter-io.cn`
3. **DLL 被占用** → 关闭正在运行的 exe 后重新构建
4. **INSTALL.vcxproj 失败** → 不影响 exe 生成，可忽略
5. **Dart 字符串插值 `${...}` 被 shell 吃掉** → 必须用 write_file.py 写入 Dart 源文件

---

## 11. 开发约束与经验

### 文件写入
- 所有 .dart / .rs / .json / .yaml 等文本文件**必须**用 `write_file.py` 脚本写入
- 脚本自动处理 utf-8-sig BOM + CRLF 换行
- Shell 的 `${...}` 会被 PowerShell 解析为变量替换，导致 Dart 字符串插值丢失

### PowerShell
- 不支持 `&&` 语法 → 用分号 `;` 分隔命令
- `$_` 在管道外无效 → 需要时写 .ps1 脚本文件
- 输出编码默认 GBK → 交互中文用 `-EncodedCommand` + UTF-16LE base64

### Flutter Release 模式
- **静默吞异常**：builder 中的异常不会红屏，只会导致"没反应"
- 排查方法：用 Debug 模式运行，或检查 `late` 变量是否在所有分支都已初始化

### 连续发送模式
- `Timer.periodic` 回调在 UI 线程同步执行，不主动让出控制权
- 需用户交互中断的循环任务**必须**用 `async/await` + `Future.delayed` 模式
- `await Future.delayed` 等待期间让出事件循环，Dart 可处理排队 UI 事件

### 滚动条与选择
- `SelectionArea` 必须在 `Scrollbar` 外层（嵌套顺序影响手势优先级）
- `SelectableText` 会拦截拖拽手势，与 `Scrollbar` 冲突
- Windows `ListView` 默认显示原生滚动条，需 `ScrollConfiguration.copyWith(scrollbars: false)` 禁用
- `Scrollbar(interactive: true)` 支持点击轨道跳转，`RawScrollbar` 无此属性

### flutter clean 后
- **必须**删除 `pubspec.lock`，否则依赖解析失败
- **必须**设置 `PUB_HOSTED_URL` 环境变量

---

## 12. 数据模型

### Rust 核心类型

```rust
enum ConnectionType { Serial, Tcp, Usb, Ble, Wifi }
enum DeviceStatus { Disconnected, Connecting, Connected, Error }
enum Protocol { Raw, ModbusRtu, ModbusTcp, Scpi, Private }

struct DeviceConfig {           // 不可变配置
    name: String, device_type: String, connection_type: ConnectionType,
    address: String, protocol: Protocol, is_virtual: bool, server_info: Option<String>,
}

struct DeviceRuntime {          // 可变状态
    status: DeviceStatus, last_seen: Option<String>, error_message: Option<String>,
}

struct DeviceInfo {             // 对外暴露 = Config + Runtime + id
    id: String,
    // Config 部分
    name, device_type, connection_type, address, protocol, is_virtual, server_info,
    // Runtime 部分
    status, last_seen, error_message,
}

struct PortInfo { name: String, port_type: String, description: String, is_virtual: bool }
struct ProtocolInfo { value: Protocol, label: String, description: String }
struct DebugLogEntry { timestamp: i64, direction: String, data: Vec<u8>, display: String }
struct VirtualInfraStatus { tcp_scpi_running: bool, tcp_scpi_address: String, virtual_serial_running: bool, virtual_serial_ports: String }
```

### 地址格式
- 串口：`"COM3:9600"` → `address.split(':')` 得到 port + baud_rate
- TCP：`"192.168.1.101:502"` → `address.split(':')` 得到 host + port
- 虚拟串口：`"COM1:9600"`

### 虚拟设备预设 ID
- TCP-SCPI-Demo: `00000001-0000-0000-0000-000000000001`
- Serial-SCPI-Demo: `00000001-0000-0000-0000-000000000002`

---

## 13. 未来扩展方向

| 方向 | 说明 |
|------|------|
| Modbus RTU/TCP 完整实现 | modbus.rs 已有 CRC16，需集成到 SessionManager |
| 数据监控 (Monitor) | data_monitor_screen.dart 目前占位，需实现实时波形图 |
| 数据生成器集成 | data_generator.rs 支持 Sine/Square/Triangle/Sawtooth/Noise/Mixed |
| 串口高级配置 | 数据位/停止位/校验位/流控 UI |
| 多设备同步采集 | 需扩展 SessionManager 支持并发会话 |
| 插件系统 | 动态加载用户自定义协议处理器 |
