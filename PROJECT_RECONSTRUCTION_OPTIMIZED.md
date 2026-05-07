# VCR 工程重建 Prompt (优化版)

> **目标**: 基于此文档完整重建 `instrument_upper_computer` 工程  
> **阅读对象**: AI 代码生成器  
> **核心原则**: 先理解架构 → 再生成代码 → 最后验证约束

---

## 🎯 重建目标清单

生成以下完整工程结构:

```
instrument_upper_computer/
├── Flutter UI (Dart)          # 7 个核心页面 + 路由 + 主题
├── Rust Core (Rust)           # 6 大模块 + FFI 桥接层
├── Lua Scripts (Lua)          # 15+ 预置脚本
├── Build Config               # FRB/Cargo/pubspec 配置
└── Documentation              # 本文档
```

**代码规模**: ~10000 行 Rust + ~2000 行 Dart

---

## 📋 核心技术栈 (必须严格匹配)

### Flutter 前端
```yaml
Flutter: 3.41.7
Dart: 3.11.5
Dependencies:
  - flutter_rust_bridge: ^2.12.0  # FFI 桥接
  - cupertino_icons: ^1.0.8
  - file_picker: ^8.0.0
  - gbk_codec: ^0.4.0
```

### Rust 后端
```toml
[dependencies]
flutter_rust_bridge = "=2.12.0"  # 精确版本
tokio = { version = "1.x", features = ["full"] }
tokio-serial = "5.4"
serialport = "4.6"
serde = { version = "1.x", features = ["derive"] }
serde_json = "1.x"
mlua = { version = "0.10", features = ["lua53", "vendored", "send"] }
chrono = "0.4"
uuid = { version = "1.x", features = ["v4"] }
log = "0.4"
env_logger = "0.11"
lazy_static = "1.4"
parking_lot = "0.12"
crossbeam-channel = "0.5"
```

---

## 🏗️ 架构分层 (自顶向下生成)

### Layer 1: Flutter UI (表现层)

**路由结构**:
```dart
/ → HomeScreen (设备总览)
/devices → DeviceListScreen (设备列表)
/device/:id → DeviceDetailScreen (设备详情)
/debug → DebugConsoleScreen (调试控制台)
/lua → LuaScriptScreen (脚本编辑器)
/plot → PlotScreen (实时绘图)
/settings → SettingsScreen (系统设置)
```

**关键组件**:
- `MainShell`: NavigationRail 容器 (响应式布局)
- `StatusIndicator`: 连接状态指示器 (共享组件)
- `DeviceSelector`: 设备选择器 (跨页面复用)

**状态管理**: StatefulWidget + Rust FFI 回调

### Layer 2: Rust API (FFI 桥接层)

**API 模块** (`rust/src/api/`):

| 模块 | 核心函数 | 说明 |
|------|---------|------|
| `device_api.rs` | `list_devices()` `connect_device()` `disconnect_device()` | 设备 CRUD + 连接管理 |
| `debug_api.rs` | `send_data()` `start_debug_session()` | 调试会话 + 数据收发 |
| `lua_api.rs` | `run_script()` `stop_script()` `list_scripts()` | Lua 引擎 + 脚本管理 |
| `plot_api.rs` | `get_plot_data()` `clear_buffer()` | Plot 数据缓冲区 |
| `virtual_api.rs` | `start_virtual_device()` `stop_virtual_device()` | 虚拟设备控制 |

**关键约束**:
```rust
// ✅ 同步函数: UI 直接调用,无耗时操作
#[flutter_rust_bridge::frb(sync)]
pub fn list_devices() -> Vec<DeviceInfo>

// ✅ 异步函数: 涉及 IO,需 block_on 包装
#[flutter_rust_bridge::frb(sync)]
pub fn connect_device(device_id: String) -> bool {
    block_on(async { /* ... */ })
}
```

### Layer 3: Core (业务逻辑层)

**全局状态** (`app_context.rs`):
```rust
lazy_static::lazy_static! {
    pub static ref RT: tokio::runtime::Runtime;
    pub static ref REGISTRY: DeviceRegistry;      // 设备注册表
    pub static ref SESSIONS: SessionManager;      // 连接池
    pub static ref DEBUG: DebugSessionManager;    // 调试日志
    pub static ref SIMULATORS: SimulatorManager;  // 虚拟设备
}

pub fn block_on<F: Future, T>(future: F) -> T {
    RT.block_on(future)
}
```

**设备模型分离**:
```rust
// 不变配置 (创建时确定)
pub struct DeviceConfig {
    pub name: String,
    pub device_type: String,
    pub connection_type: ConnectionType,  // Serial | Tcp
    pub address: String,  // "COM1:115200:8:1:N:N:100" 或 "192.168.1.100:502"
    pub protocol: Protocol,  // Csv | Modbus
    pub is_virtual: bool,
}

// 可变运行时状态
pub struct DeviceRuntime {
    pub status: DeviceStatus,  // Disconnected | Connecting | Connected | Error
    pub last_seen: Option<String>,
    pub error_message: Option<String>,
}

// 对外统一模型
pub struct DeviceInfo {
    pub id: String,
    pub config: DeviceConfig,
    pub runtime: DeviceRuntime,
}
```

**连接池管理** (`session_manager.rs`):
```rust
pub enum ActiveSession {
    Serial(Arc<Mutex<SerialTransport>>),
    Tcp(Arc<Mutex<TcpTransport>>),
    Virtual(Arc<Mutex<VirtualChannelTransport>>),
}

pub struct SessionManager {
    sessions: RwLock<HashMap<String, ActiveSession>>,
    #[cfg(windows)]
    serial_handles: RwLock<HashMap<String, SafeHandle>>,  // 硬件流控制句柄
    registry: &'static DeviceRegistry,
    simulators: &'static SimulatorManager,
}
```

### Layer 4: Transport (传输层)

**串口传输** (`serial.rs`):
- 支持完整配置: `波特率/数据位/停止位/校验位/流控制/超时`
- 硬件流控制 (Windows API 直接调用):
  ```rust
  #[cfg(windows)]
  pub mod win_comm {
      pub const SETDTR: u32 = 5;  // 数据终端就绪
      pub const CLRDTR: u32 = 6;
      pub const SETRTS: u32 = 3;  // 请求发送
      pub const CLRRTS: u32 = 4;
      
      extern "system" {
          pub fn EscapeCommFunction(hFile: *mut c_void, dwFunc: u32) -> i32;
          pub fn GetCommModemStatus(hFile: *mut c_void, lpModemStat: *mut u32) -> i32;
      }
  }
  ```

**TCP 传输** (`tcp.rs`):
- 异步连接管理 (tokio::net::TcpStream)
- 自动重连机制

**虚拟通道** (`virtual_channel.rs`):
- 内存队列模拟串口行为
- 用于无硬件环境测试

---

## 🔧 Lua 脚本系统

### 引擎架构 (`lua_engine.rs`)

```rust
struct LuaEngine {
    lua: Lua,                                    // mlua 实例
    device_id: Arc<Mutex<String>>,               // 当前设备
    log_buffer: Arc<Mutex<Vec<String>>>,         // 日志缓冲
    point_buffer: Arc<Mutex<Vec<(f64, usize)>>>, // 绘图数据
}

lazy_static! {
    static ref CALLBACKS: Arc<Mutex<HashMap<String, Vec<Function>>>>;
    static ref TIMER_TASKS: Arc<Mutex<HashMap<u32, JoinHandle<()>>>>;
}
```

### 核心 API (注入 Lua)

| API | 功能 | 示例 |
|-----|------|------|
| `apiSend(channel, data)` | 发送数据 | `apiSend("uart", "HELLO")` |
| `apiSendUartData(data)` | 串口发送 | `apiSendUartData("AT\\r\\n")` |
| `apiSetCb(channel, cb)` | 注册回调 | `apiSetCb("uart", function(data) ... end)` |
| `apiStartTimer(id, ms)` | 启动定时器 | `apiStartTimer(1, 1000)` |
| `apiSerialSetDTR(level)` | DTR 控制 | `apiSerialSetDTR(1)` |
| `apiSerialSetRTS(level)` | RTS 控制 | `apiSerialSetRTS(0)` |
| `apiSerialGetCTS()` | 读取 CTS | `local cts = apiSerialGetCTS()` |
| `apiSerialGetDSR()` | 读取 DSR | `local dsr = apiSerialGetDSR()` |
| `apiGetPath()` | exe 路径 | `local path = apiGetPath()` |
| `apiInputBox(...)` | 输入框 | `local input = apiInputBox("提示", "默认值", "标题")` |

### string 扩展库

```lua
string.toHex("abc")              -- → "616263"
string.fromHex("616263")         -- → "abc"
string.utf8Len("你好")           -- → 2
string.split("a,b,c", ",")       -- → {"a","b","c"}
string.urlEncode("hello world")  -- → "hello%20world"
string.toValue("FF")             -- → 255.0
string.formatNumberThousands(1234567)  -- → "1,234,567"
```

### sys 协程模块 (关键!)

```lua
-- ✅ 正确: 在协程中调用
sys.taskInit(function()
    sys.wait(500)                    -- 等待 500ms
    sys.waitUntil("uart", 1000)      -- 等待 UART 数据,超时 1s
end)

-- ❌ 错误: 主线程直接调用会 panic
sys.wait(500)  -- panic!

-- 定时器
local tid = sys.timerStart(callback, 1000, arg1, arg2)
sys.timerStop(tid)
sys.timerLoopStart(callback, 1000)  -- 循环定时器

-- 发布订阅
sys.subscribe("event", callback)
sys.publish("event", data)
```

### 内嵌脚本 (`lua_core_scripts.rs`)

```rust
pub const LOG_LUA: &str = r#"
    function log.info(msg) ... end
    function log.error(msg) ... end
"#;

pub const SYS_LUA: &str = r#"
    -- 协程调度器
    sys = { tasks = {}, timers = {} }
    function sys.taskInit(func) ... end
    function sys.wait(ms) ... end
"#;

pub const HEAD_LUA: &str = r#"
    -- 初始化脚本
    require("log")
    require("sys")
"#;
```

---

## 🎨 Flutter UI 模式

### 路由 (Navigator 2.0)

```dart
class AppRoutes {
  static const home = '/';
  static const devices = '/devices';
  static const debug = '/debug';
  static const lua = '/lua';
  static const plot = '/plot';
  static const settings = '/settings';
  
  static Route onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case devices:
        return MaterialPageRoute(builder: (_) => DeviceListScreen());
      // ...
    }
  }
}
```

### 主题 (暗色优先)

```dart
class AppTheme {
  static ThemeData get darkTheme => ThemeData(
    brightness: Brightness.dark,
    primarySwatch: Colors.blue,
    scaffoldBackgroundColor: Color(0xFF1E1E1E),
    cardColor: Color(0xFF2D2D2D),
    dividerColor: Color(0xFF3D3D3D),
  );
}
```

### Lua 脚本编辑器

```dart
class LuaScriptScreen extends StatefulWidget {
  // 设备选择器 + 脚本列表 + 代码编辑器 + 输出面板
  // 功能:
  // - 新建/保存/删除脚本
  // - 运行/停止脚本
  // - 实时日志输出
  // 脚本目录: <exe_path>/scripts/
}
```

---

## 🧪 虚拟设备基础设施

### 启动流程 (`main.dart`)

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. 初始化 Rust
  await RustLib.init();
  
  // 2. 预初始化 Lua 引擎 (避免竞态)
  await initLuaEngine();
  
  // 3. 启动虚拟设备基础设施
  startVirtualInfrastructure();  // TCP-SCPI + 虚拟串口
  
  // 4. 加载设备
  final hasPersisted = await loadPersistedDevices();
  if (!hasPersisted) {
    await loadDemoDevices();  // 演示设备预设
  }
  
  // 5. 自动重连
  await _autoReconnectIfNeeded();
  
  runApp(MyApp());
}
```

### 虚拟设备能力

- **TCP SCPI 服务器**: 模拟仪器响应 (`*IDN?`, `MEAS:VOLT?`, `MEAS:CURR?`)
- **虚拟串口对**: COM1 ↔ COM2 (需第三方驱动)
- **数据生成器**: 正弦/方波/三角波
- **SCPI 响应器**: 标准命令解析

---

## ⚠️ 关键约束 (必须遵守)

### 1. FRB sync vs async

```rust
// ❌ 错误: 耗时操作标记为 sync 会阻塞 UI
#[flutter_rust_bridge::frb(sync)]
pub fn connect_device(device_id: String) -> bool {
    tokio::time::sleep(Duration::from_secs(5)).await;  // 阻塞!
    true
}

// ✅ 正确: 用 block_on 包装异步操作
#[flutter_rust_bridge::frb(sync)]
pub fn connect_device(device_id: String) -> bool {
    block_on(async {
        tokio::time::sleep(Duration::from_secs(5)).await;
        true
    })
}
```

### 2. Mutex poisoning 恢复

```rust
// ❌ 错误: 默认 recover 会 panic
let guard = mutex.lock().unwrap();

// ✅ 正确: 显式恢复
fn lock_mutex<T>(mutex: &Mutex<T>) -> MutexGuard<T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            log::warn!("Mutex was poisoned, recovering...");
            poisoned.into_inner()  // 恢复而非 panic
        }
    }
}
```

### 3. Lua os 模块不可用

```lua
-- ❌ 不可用 (mlua lua53 未启用 os)
os.time()
os.date()

-- ✅ 替代方案
math.randomseed(123456789)  -- 固定种子
count = count + 1           -- 计数器
```

### 4. 文件写入规范

- **必须使用 Python 脚本** (`write_file.py`) 写入文本文件
- **禁止** PowerShell `Set-Content` (损坏编码)
- **禁止** 内置 `write` 工具写最终文件 (无 BOM)
- 编码: `utf-8-sig` (Windows CSV) / `utf-8` (代码文件)
- 换行符: `CRLF` (Windows) / `LF` (macOS/Linux)

---

## 🚀 构建命令

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

## 🌐 国内镜像配置

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

## 📦 串口配置格式

```
格式: port:baudRate:dataBits:stopBits:parity:flowControl:timeoutMs

示例:
COM1:115200:8:1:N:N:100        # 最常见配置
COM2:9600:7:2:E:H:50           # 奇校验 + 硬件流控制

参数说明:
- dataBits: 5, 6, 7, 8
- stopBits: 1, 2
- parity: N(one), O(dd), E(ven)
- flowControl: N(one), H(ardware), S(oftware)
```

---

## ✅ 重构计划 (已完成)

- [x] P0: `#[frb(sync)]` → async (connect/disconnect/update/remove)
- [x] P0: Plot 内存泄漏 (数据截断)
- [x] P1: DebugConsole 计数器修复
- [x] P1: 轮询同步确认
- [x] P2: StatusIndicator 共享组件
- [x] P2: AppConstants 提取
- [x] 设备级状态绑定 (`_deviceStates` Map)
- [x] 配置持久化 (`%APPDATA%\instrument_upper_computer\`)
- [x] Lua 引擎预初始化 (避免竞态)
- [x] 脚本目录迁移 (exe 同路径)
- [x] 硬件流控制 API

---

## 🎓 生成顺序建议

1. **先理解**: 通读架构分层,理解数据流向
2. **后生成**: 按以下顺序生成代码
   - Rust Core (app_context → models → transport → session → api)
   - Flutter UI (theme → routes → widgets → screens)
   - Lua Scripts (预置脚本)
3. **再验证**: 检查约束条件,确保无违规
4. **最后构建**: 执行构建命令,验证可运行

---

**此文档包含完整的技术栈、架构、核心代码结构,可据此重新生成整个工程。**
