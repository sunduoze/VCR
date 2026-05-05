// ============================================================================
// instrument_upper_computer — 重构方案
// ============================================================================
//
// ## 当前问题
//
// 1. **全局单例反模式**：DEVICE_MANAGER / CONNECTION_MANAGER / VIRTUAL_SERIAL_PAIR
//    / DATA_PIPELINE / VIRTUAL_SERIAL_MANAGER 均为 lazy_static 全局变量，
//    导致隐式耦合、不可测试、生命周期失控
//
// 2. **Runtime 混乱**：api/device.rs 的 connect_device / scan_serial_ports 创建
//    临时 `Runtime::new()`，spawn 的任务随 runtime drop 而被取消（TCP/虚拟串口
//    连接失败的根因）。部分地方用 CONNECTION_MANAGER.block_on()，部分用临时 rt
//
// 3. **API 层职责越界**：api/device.rs 包含设备创建逻辑、Demo 加载逻辑；
//    api/debug_console.rs 包含虚拟基础设施管理 + 调试会话 + 设备连接路由，
//    完全是两个不相关关注点的混合体
//
// 4. **死代码**：protocol.rs（GenericProtocol 未使用）、VirtualSerialManager
//    （向后兼容包装无人调用）、data_pipeline.rs（RingBuffer 未接入实际数据流）
//
// 5. **Flutter 无状态管理**：每个 screen 独立调用 Rust API 拉取数据，无共享
//    状态，无法响应式更新
//
// 6. **模型混乱**：DeviceInfo 同时承担「配置」和「运行时状态」两个职责
//
// ## 重构目标
//
// - 单一 AppContext 持有全局 runtime + 所有子系统引用，取代散落的全局变量
// - API 层只做 FRB 类型桥接，零业务逻辑
// - 清晰分层：transport → session → service → api
// - 删除死代码
// - Flutter 侧引入 ChangeNotifier 状态管理
//
// ## 新 Rust 目录结构
//
// rust/src/
// ├── lib.rs                          # crate 入口
// ├── frb_generated.rs                # FRB 自动生成
// ├── api/                            # FRB 桥接层（零业务逻辑）
// │   ├── mod.rs
// │   ├── device_api.rs               # 设备 CRUD + 连接/断开
// │   ├── debug_api.rs                # 调试收发 + 日志
// │   └── virtual_api.rs              # 虚拟基础设施控制
// ├── core/                           # 业务核心
// │   ├── mod.rs
// │   ├── app_context.rs              # 全局上下文：runtime + 子系统
// │   ├── device/
// │   │   ├── mod.rs
// │   │   ├── models.rs               # DeviceInfo / DeviceConfig / DeviceStatus
// │   │   ├── registry.rs             # 设备注册表（增删查改）
// │   │   └── preset.rs               # 虚拟设备 / Demo 预设
// │   ├── transport/
// │   │   ├── mod.rs                  # Transport trait + TransportError
// │   │   ├── serial.rs               # SerialTransport
// │   │   ├── tcp.rs                  # TcpTransport
// │   │   └── virtual_channel.rs      # 虚拟串口 channel 传输
// │   ├── session/
// │   │   ├── mod.rs                  # Session trait
// │   │   ├── session_manager.rs      # 连接池 + 收发路由
// │   │   └── debug_session.rs        # 调试日志包装
// │   ├── protocol/
// │   │   ├── mod.rs                  # Protocol enum + codec trait
// │   │   ├── modbus.rs               # Modbus RTU/TCP 编解码
// │   │   └── scpi.rs                 # SCPI 编解码（挪自 virtual_device/）
// │   └── virtual_device/
//       ├── mod.rs
//       ├── simulator.rs              # 虚拟设备模拟器（TCP server + serial pair 统一接口）
//       ├── scpi_responder.rs         # SCPI 命令响应器（纯逻辑，无 I/O）
//       └── data_generator.rs         # 波形数据生成器
//
// ## 核心设计
//
// ### AppContext（取代所有 lazy_static 全局变量）
//
// ```rust
// pub struct AppContext {
//     rt: tokio::runtime::Runtime,
//     registry: DeviceRegistry,
//     sessions: SessionManager,
//     simulators: SimulatorManager,
// }
//
// lazy_static! {
//     pub static ref APP: AppContext = AppContext::new();
// }
// ```
//
// - 唯一的 lazy_static，只此一个
// - rt.block_on() 是唯一的异步执行路径
// - 子系统通过 &APP 引用，不各自持有 runtime
//
// ### SessionManager（取代 ConnectionManager）
//
// ```rust
// pub struct SessionManager {
//     sessions: RwLock<HashMap<String, DeviceSession>>,
// }
//
// enum DeviceSession {
//     Serial(SerialTransport),
//     Tcp(TcpTransport),
//     VirtualChannel { tx: mpsc::UnboundedSender<Vec<u8>>, rx: broadcast::Receiver<Vec<u8>> },
// }
// ```
//
// - 统一管理所有连接，不再区分虚拟/真实（由 transport 层屏蔽）
// - send / receive 通过 Session trait 统一接口
//
// ### SimulatorManager（取代散落的 VIRTUAL_SERVERS + VIRTUAL_SERIAL_PAIR）
//
// ```rust
// pub struct SimulatorManager {
//     tcp_servers: RwLock<HashMap<u16, TcpSimulator>>,
//     serial_pair: RwLock<Option<SerialPairSimulator>>,
// }
// ```
//
// - 虚拟基础设施的启动/停止/状态查询统一入口
// - 不再混在 debug_console.rs 里
//
// ### API 层原则
//
// ```rust
// // ❌ 之前：API 层包含业务逻辑
// pub fn connect_device(device_id: String) -> bool {
//     DEVICE_MANAGER.update_status(...);
//     let rt = Runtime::new().unwrap();  // BUG: 临时 runtime
//     rt.block_on(async { ... })
// }
//
// // ✅ 重构后：API 层只做类型转换和委托
// pub fn connect_device(device_id: String) -> bool {
//     APP.rt().block_on(async {
//         APP.sessions().connect(&device_id).await.is_ok()
//     })
// }
// ```
//
// ## 执行顺序
//
// Phase 1: Rust 后端核心重构
//   1. 创建 AppContext
//   2. 拆分 device_manager → device/models + device/registry + device/preset
//   3. 重构 transport → 新增 virtual_channel
//   4. 创建 session/session_manager（取代 connection_manager）
//   5. 重构 virtual_device → simulator + scpi_responder
//   6. 清理 API 层
//   7. 删除死代码（protocol.rs GenericProtocol, VirtualSerialManager 等）
//
// Phase 2: Flutter 侧重构
//   1. 创建 DeviceStore (ChangeNotifier)
//   2. 简化 screens，消费 store 而非直接调 API
//   3. 统一 MainShell 路由
