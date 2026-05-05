# instrument_upper_computer 工程重建 Prompt

> 本文档包含完整的技术栈、架构、核心代码结构，可据此重新生成整个工程。

---

## 一、项目概述

**项目名称**: instrument_upper_computer (VCR - Virtual Control Room)  
**用途**: 虚拟仪器控制上位机，支持串口/TCP设备连接、Lua脚本自动化、实时数据可视化  
**平台**: Windows + Web (Flutter 3.41.7)  
**架构**: Flutter + Rust (flutter_rust_bridge 2.12.0)

---

## 二、技术栈

### Flutter 前端
- Flutter 3.41.7 / Dart 3.11.5
- flutter_rust_bridge: ^2.12.0
- cupertino_icons: ^1.0.8
- file_picker: ^8.0.0
- gbk_codec: ^0.4.0

### Rust 后端
- Rust 1.95.0 (edition 2021)
- flutter_rust_bridge: "=2.12.0"
- tokio 1.x (full features)
- tokio-serial 5.4 + serialport 4.6
- serde 1.x + serde_json 1.x
- mlua 0.10 (lua53, vendored, send)
- chrono 0.4, uuid 1.x, log 0.4, env_logger 0.11
- lazy_static 1.4, parking_lot 0.12, crossbeam-channel 0.5

---

## 三、核心架构

```
┌─────────────────────────────────────────────────────────────┐
│                     Flutter UI Layer                        │
│  home_screen | device_list | debug_console | lua_script    │
│  plot_screen | settings | device_detail                    │
└─────────────────────┬───────────────────────────────────────┘
                      │ FFI (flutter_rust_bridge)
┌─────────────────────┴───────────────────────────────────────┐
│                     Rust API Layer                          │
│  device_api | debug_api | lua_api | plot_api | virtual_api │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────┴───────────────────────────────────────┐
│                     Core Layer                              │
│  ┌─────────────┐ ┌───────────────┐ ┌──────────────────┐    │
│  │  Device     │ │   Transport   │ │     Session      │    │
│  │  Registry   │ │ Serial/TCP    │ │    Manager       │    │
│  └─────────────┘ └───────────────┘ └──────────────────┘    │
│  ┌─────────────┐ ┌───────────────┐ ┌──────────────────┐    │
│  │  Virtual    │ │   Protocol    │ │   Debug Session  │    │
│  │  Simulator  │ │ CSV/Modbus    │ │    Manager       │    │
│  └─────────────┘ └───────────────┘ └──────────────────┘    │
│  ┌─────────────┐ ┌───────────────┐ ┌──────────────────┐    │
│  │   Plot      │ │     Lua       │ │   App Context    │    │
│  │ DataBuffer  │ │   Engine      │ │  (lazy_static)   │    │
│  └─────────────┘ └───────────────┘ └──────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

---

## 四、目录结构

```
instrument_upper_computer/
├── lib/                          # Flutter UI
│   ├── main.dart                 # 入口：RustLib.init(), auto-reconnect
│   ├── app/
│   │   ├── routes.dart          # Navigator 2.0 路由
│   │   └── theme.dart           # 暗色主题
│   ├── screens/
│   │   ├── home_screen.dart
│   │   ├── device_list_screen.dart
│   │   ├── device_detail_screen.dart
│   │   ├── debug_console_screen.dart
│   │   ├── lua_script_screen.dart
│   │   ├── plot_screen.dart
│   │   └── settings_screen.dart
│   ├── widgets/
│   │   ├── main_shell.dart      # NavigationRail 容器
│   │   └── status_indicator.dart # 连接状态图标
│   └── src/rust/                 # FRB 生成的 Dart 绑定
│       └── api/*.dart
├── rust/                         # Rust 后端
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── api/                  # FFI 接口层
│       │   ├── mod.rs
│       │   ├── device_api.rs    # 设备 CRUD + 连接管理
│       │   ├── debug_api.rs     # 调试会话 + 发送接收
│       │   ├── lua_api.rs       # Lua 引擎 + 脚本管理
│       │   ├── lua_core_scripts.rs # 内嵌 log/sys/head.lua
│       │   ├── plot_api.rs      # Plot 数据缓冲区
│       │   └── virtual_api.rs   # 虚拟设备控制
│       └── core/
│           ├── app_context.rs   # 全局单例：RT, REGISTRY, SESSIONS, DEBUG
│           ├── device/
│           │   ├── models.rs    # DeviceConfig, DeviceInfo, Protocol 等
│           │   ├── registry.rs  # 设备注册表（CRUD）
│           │   └── preset.rs     # 演示设备预设
│           ├── transport/
│           │   ├── serial.rs    # 串口传输层 + DTR/RTS/CTS/DSR 控制
│           │   ├── tcp.rs       # TCP 传输层
│           │   └── virtual_channel.rs # 虚拟通道
│           ├── session/
│           │   ├── session_manager.rs # 连接池管理
│           │   └── debug_session.rs   # 调试日志管理
│           ├── virtual_device/
│           │   ├── simulator.rs       # 虚拟设备模拟器
│           │   ├── data_generator.rs  # 数据生成器
│           │   └── scpi_responder.rs  # SCPI 命令响应
│           ├── protocol/
│           │   └── csv_parser.rs      # CSV 协议解析
│           └── plot/
│               └── data_buffer.rs     # Plot 环形缓冲区
├── scripts/                      # Lua 用户脚本（exe 同路径）
│   ├── 01_timer_test.lua
│   ├── 05_uart_test.lua
│   ├── 13_hardware_flow_control.lua
│   └── ...（共 15+ 脚本）
├── windows/
│   └── CMakeLists.txt           # 添加 scripts 目录安装规则
├── flutter_rust_bridge.yaml     # FRB 配置
└── pubspec.yaml
```

---

## 五、核心设计模式

### 1. 全局状态管理 (app_context.rs)

```rust
lazy_static::lazy_static! {
    pub static ref RT: tokio::runtime::Runtime = ...;
    pub static ref REGISTRY: DeviceRegistry = ...;
    pub static ref SESSIONS: SessionManager = ...;
    pub static ref DEBUG: DebugSessionManager = ...;
    pub static ref SIMULATORS: SimulatorManager = ...;
}

// 同步包装器（用于 #[frb(sync)] 函数）
pub fn block_on<F, T>(future: F) -> T { RT.block_on(future) }
```

### 2. 设备模型分离

```rust
// 不变配置（创建时确定）
pub struct DeviceConfig {
    pub name: String,
    pub device_type: String,
    pub connection_type: ConnectionType,
    pub address: String,  // Serial: "COM1:115200:8:1:N:N:100"
                          // TCP: "192.168.1.100:502"
    pub protocol: Protocol,
    pub is_virtual: bool,
}

// 可变运行时状态
pub struct DeviceRuntime {
    pub status: DeviceStatus,
    pub last_seen: Option<String>,
    pub error_message: Option<String>,
}

// 对外统一模型
pub struct DeviceInfo {
    pub id: String,
    // 配置字段
    pub name: String, ...
    // 运行时字段
    pub status: DeviceStatus, ...
}
```

### 3. SessionManager 连接池

```rust
pub enum ActiveSession {
    Serial(Arc<Mutex<SerialTransport>>),
    Tcp(Arc<Mutex<TcpTransport>>),
    Virtual(Arc<Mutex<VirtualChannelTransport>>),
}

pub struct SessionManager {
    sessions: RwLock<HashMap<String, ActiveSession>>,
    #[cfg(windows)]
    serial_handles: RwLock<HashMap<String, SafeHandle>>, // 无锁 DTR/RTS
    registry: &'static DeviceRegistry,
    simulators: &'static SimulatorManager,
}
```

### 4. 硬件流控制 (Windows API)

```rust
// 直接调用 Windows API，无需 Mutex
#[cfg(windows)]
pub mod win_comm {
    pub const SETDTR: u32 = 5;
    pub const CLRDTR: u32 = 6;
    pub const SETRTS: u32 = 3;
    pub const CLRRTS: u32 = 4;
    
    extern "system" {
        pub fn EscapeCommFunction(hFile: *mut c_void, dwFunc: u32) -> i32;
        pub fn GetCommModemStatus(hFile: *mut c_void, lpModemStat: *mut u32) -> i32;
    }
}
```

---

## 六、Lua 脚本系统

### 架构

```rust
struct LuaEngine {
    lua: Lua,
    device_id: Arc<Mutex<String>>,
    log_buffer: Arc<Mutex<Vec<String>>>,
    point_buffer: Arc<Mutex<Vec<(f64, usize)>>>,
}

lazy_static! {
    static ref CALLBACKS: Arc<Mutex<HashMap<String, Vec<Function>>>>;
    static ref TIMER_TASKS: Arc<Mutex<HashMap<u32, JoinHandle<()>>>>;
}
```

### 核心 API

| API | 功能 |
|-----|------|
| `apiSend(channel, data)` | 发送数据到指定通道 |
| `apiSendUartData(data)` | 发送串口数据 |
| `apiSetCb(channel, cb)` | 注册回调 |
| `apiStartTimer(id, ms)` | 启动定时器 |
| `apiSerialSetDTR(level)` | 设置 DTR |
| `apiSerialSetRTS(level)` | 设置 RTS |
| `apiSerialGetCTS()` | 读取 CTS |
| `apiSerialGetDSR()` | 读取 DSR |
| `apiGetPath()` | 获取 exe 目录 |
| `apiInputBox(prompt, default, title)` | 同步输入框 |

### string 扩展

```lua
string.toHex(str)       -- "abc" → "616263"
string.fromHex(hex)     -- "616263" → "abc"
string.utf8Len(str)     -- "你好" → 2
string.split(str, sep)  -- "a,b,c" → {"a","b","c"}
string.urlEncode(str)   -- "hello world" → "hello%20world"
string.toValue(hex)     -- "FF" → 255.0
string.formatNumberThousands(n) -- 1234567 → "1,234,567"
```

### sys 协程模块

```lua
-- ✅ 正确：在协程中调用
sys.taskInit(function()
    sys.wait(500)           -- 等待 500ms
    sys.waitUntil("uart", 1000) -- 等待 UART 数据，超时 1s
end)

-- ❌ 错误：主线程直接调用会失败
sys.wait(500)  -- panic!

-- 定时器
local tid = sys.timerStart(callback, 1000, arg1, arg2)
sys.timerStop(tid)
sys.timerLoopStart(callback, 1000) -- 循环定时器

-- 发布订阅
sys.subscribe("event", callback)
sys.publish("event", data)
sys.unsubscribe("event", callback)
```

### 内嵌脚本 (lua_core_scripts.rs)

```rust
pub const LOG_LUA: &str = r#"...#;  // 日志模块
pub const SYS_LUA: &str = r#"...#; // 协程调度
pub const HEAD_LUA: &str = r#"...#; // 初始化脚本
```

---

## 七、串口配置格式

```
port:baudRate:dataBits:stopBits:parity:flowControl:timeoutMs
COM1:115200:8:1:N:N:100
COM2:9600:7:2:E:H:50

dataBits: 5,6,7,8
stopBits: 1,2
parity: N(one), O(dd), E(ven)
flowControl: N(one), H(ardware), S(oftware)
```

---

## 八、Flutter UI 模式

### 路由

```dart
class AppRoutes {
  static const home = '/';
  static const devices = '/devices';
  static const debug = '/debug';
  static const lua = '/lua';
  static const plot = '/plot';
  static const settings = '/settings';
  
  static Route onGenerateRoute(RouteSettings settings) {
    // Navigator 2.0 风格
  }
}
```

### 主题

```dart
class AppTheme {
  static ThemeData get darkTheme => ThemeData(
    brightness: Brightness.dark,
    primarySwatch: Colors.blue,
    // ...
  );
}
```

### Lua 脚本编辑器

```dart
class LuaScriptScreen extends StatefulWidget {
  // 设备选择器 + 脚本选择器 + 编辑器 + 输出面板
  // 支持新建/保存/删除脚本
  // 脚本目录: <exe_path>/scripts/
}
```

---

## 九、虚拟设备基础设施

### 启动流程 (main.dart)

```dart
void main() async {
  await RustLib.init();
  await initLuaEngine();  // 预初始化，避免竞态
  startVirtualInfrastructure(); // 启动 TCP-SCPI + 虚拟串口
  loadPersistedDevices() || loadDemoDevices();
  _autoReconnectIfNeeded();
  runApp(MyApp());
}
```

### 虚拟设备能力

- TCP SCPI 服务器（模拟仪器响应）
- 虚拟串口对（COM1 ↔ COM2）
- 数据生成器（正弦/方波/三角波）
- SCPI 命令响应（*IDN?, MEAS:VOLT?, MEAS:CURR?）

---

## 十、关键注意事项

### FRB sync vs async

```rust
// ✅ 同步函数：用于 UI 直接调用，无耗时操作
#[flutter_rust_bridge::frb(sync)]
pub fn list_devices() -> Vec<DeviceInfo>

// ✅ 异步函数：涉及 IO 操作
pub async fn connect_device(device_id: String) -> bool

// ⚠️ 异步函数用 block_on 包装后可标记 sync
#[flutter_rust_bridge::frb(sync)]
pub fn connect_device(device_id: String) -> bool {
    block_on(async { ... })
}
```

### Mutex poisoning 恢复

```rust
fn lock_mutex<T>(mutex: &Mutex<T>) -> MutexGuard<T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            log::warn!("Mutex was poisoned, recovering...");
            poisoned.into_inner() // 恢复而非 panic
        }
    }
}
```

### Lua os 模块不可用

```lua
-- ❌ 不可用（mlua lua53 未启用 os）
os.time()
os.date()

-- ✅ 替代方案
math.randomseed(123456789) -- 固定种子
count = count + 1           -- 计数器
```

---

## 十一、构建命令

```powershell
# 首次构建
flutter clean
flutter_rust_bridge_codegen generate
flutter build windows

# 开发调试
cd rust && cargo build --release
cd .. && flutter run -d windows

# FRB 哈希不匹配时
flutter clean
flutter_rust_bridge_codegen generate
flutter build windows
```

---

## 十二、国内镜像配置

```powershell
# PowerShell profile
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"

# Cargo config (~/.cargo/config.toml)
[source.crates-io]
replace-with = 'rsproxy'

[source.rsproxy]
registry = "https://rsproxy.cn/crates.io-index"
```

---

## 十三、文件写入规范

- 使用 Python 脚本写入文本文件（utf-8-sig BOM, CRLF）
- 禁止直接用 PowerShell `Set-Content`（会损坏编码）
- 禁止用内置 `write` 工具写最终文件（无 BOM）

---

## 十四、重构计划 (已完成)

- [x] P0: `#[frb(sync)]` → async（connect/disconnect/update/remove）
- [x] P0: Plot 内存泄漏（数据截断）
- [x] P1: DebugConsole 计数器修复
- [x] P1: 轮询同步确认
- [x] P2: StatusIndicator 共享组件
- [x] P2: AppConstants 提取
- [x] 设备级状态绑定（`_deviceStates` Map）
- [x] 配置持久化（`%APPDATA%\instrument_upper_computer\`）
- [x] Lua 引擎预初始化（避免竞态）
- [x] 脚本目录迁移（exe 同路径）
- [x] 硬件流控制 API

---

*此文档可完整重建整个工程。核心代码约 10000 行 Rust + 2000 行 Dart。*
