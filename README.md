# VCR — 仪器控制与可视化终端

-- **V**irtual --- Instrument **C**ontrol & **R**ecording — 一款跨平台实时数据采集与波形可视化桌面应用，基于 Flutter + Rust 混合架构构建。

---

## 🚀 功能特性

| 模块 | 功能 |
|------|------|
| **实时波形绘图** | 多通道示波器级渲染，12 通道 Demo 波形 + 真实设备数据采集 |
| **多模式显示** | 滚动模式（示波器扫掠）、定格模式、缩放/平移 |
| **样式系统** | Line / Dot / Dot-Line / Filled 四种线型，16 色感知均匀通道调色板 |
| **数据记录** | CSV 导入导出，支持离线回放分析 |
| **协议解析** | 串口、TCP、Modbus RTU/TCP、SCPI、Raw 协议插件 |
| **Lua 脚本引擎** | 内置 Lua 5.3 运行时，支持自动化测试、数据生成、协议解析脚本 |
| **虚拟设备** | 内置虚拟设备模拟器，无需硬件即可开发测试 |
| **GPU 加速** | 基于 wgpu (WebGPU) 的硬件加速渲染管线 |
| **调试控制台** | 实时日志输出，分级控制 (trace/debug/info/warn/error) |
| **跨平台** | Windows（主力）、Linux（WIP） |

## 🏗️ 架构

```
┌─────────────────────────────────────────────────────────────┐
│                      Flutter (Dart)                          │
│  screens/   widgets/   models/   core/   render/   app/     │
│     ▲                                                       │
│     │  flutter_rust_bridge v2.12  (FFI / 零拷贝)             │
│     ▼                                                       │
│                       Rust (vcr_lib)                         │
│  api/  core/  renderer/                                      │
│  ┌──────────┬──────────────┬──────────────┬───────────┐    │
│  │  device  │    plot      │  protocol    │ transport │    │
│  │  registry│  pipeline    │  csv/modbus  │ serial    │    │
│  │  models  │  analog_seg  │  scpi/raw    │ tcp       │    │
│  │  preset  │  time_bucket │  registry    │ modbus    │    │
│  └──────────┴──────────────┴──────────────┴───────────┘    │
│  ┌──────────┬──────────────┬──────────────────────────┐    │
│  │ session  │ virtual_dev  │  renderer (wgpu/WebGPU)   │    │
│  │ manager  │ simulator    │  shader_waveform.wgsl     │    │
│  └──────────┴──────────────┴──────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### 数据路径

```
硬件/虚拟设备 → Transport → Protocol Parser → ChannelBuffer (ring)
                                                    │
                    ┌───────────────────────────────┤
                    ▼                               ▼
          TimeBucketPyramid                 AnalogSegment (f32, 10-level 16ⁿ)
          (f64, LOD 层级)                         │
                    │                               │
                    └───────────┬───────────────────┘
                                ▼
                     Pipeline Thread (async)
                     · 零拷贝 envelope 预计算
                     · 双缓冲 gen-lock
                                │
                                ▼
                     _PlotScreenState._onTick()
                     · _refreshViewportData()
                     · _fitYAxis() / _fitXAxis()
                     · setState() → CustomPainter
```

### 渲染管线

```
采样点/像素 < envelopeThreshold (2.0)
  → Trace 模式：原始折线 (raw polyline)
  → 按 LineStyle 路由到 _drawLine / _drawDots / _drawDotLine / _drawFilled

采样点/像素 ≥ envelopeThreshold
  → Envelope 模式：
    1. _drawEnvelope() — 半透明 min-max 填充带 (α=0.25)
    2. _drawMinMaxLines() — 竖线密度条 (α=0.65)
    3. _drawGapMarkers() — 时间断点标记 (α=0.18)
    4. 前景线 — avg trace (α=1.0)
```

## 📂 项目结构

```
VCR/
├── lib/                          # Flutter 前端 (Dart)
│   ├── main.dart                 # 入口，RustLib.init(), 日志初始化
│   ├── app/
│   │   ├── routes.dart           # 路由表 (7 screens + MainShell)
│   │   └── theme.dart            # 主题定义
│   ├── screens/
│   │   ├── plot_screen.dart      # ★ 核心：示波器波形界面 (~3200 行)
│   │   ├── plot_models.dart      # PlotChannel, PlotGroup, LineStyle, _DataBuf
│   │   ├── plot_painter.dart     # CustomPainter：envelope/trace/dots 渲染
│   │   ├── device_list_screen.dart
│   │   ├── device_detail_screen.dart
│   │   ├── settings_screen.dart  # 日志级别、文件日志、主题设置
│   │   ├── debug_console_screen.dart
│   │   ├── lua_script_screen.dart # Lua 脚本编辑器 + 运行时
│   │   └── gpu_test_screen.dart  # GPU 诊断
│   ├── widgets/
│   │   ├── main_shell.dart       # 主导航框架 (5-tab)
│   │   ├── multi_send_panel.dart
│   │   └── status_indicator.dart
│   ├── core/
│   │   ├── ffi_bridge.dart       # 零拷贝 FFI：Pointer.asTypedList, 批量查询
│   │   ├── viewport.dart
│   │   └── typed_data_pool.dart
│   ├── render/
│   │   └── picture_cache.dart    # PictureRecorder 缓存
│   ├── models/
│   │   └── multi_send_item.dart
│   ├── api/                      # FRB 生成的 Dart API 包装
│   ├── src/rust/                 # FRB 生成的 Rust↔Dart 绑定
│   └── frb_generated.dart
│
├── rust/                         # Rust 后端
│   ├── Cargo.toml                # crate: vcr_lib (cdylib + staticlib)
│   ├── src/
│   │   ├── lib.rs                # crate root: api, core, renderer, frb_generated
│   │   ├── api/                  # FFI 导出接口
│   │   │   ├── plot_api.rs       # 波形查询、缓冲区、overflow
│   │   │   ├── device_api.rs     # 设备发现/管理
│   │   │   ├── debug_api.rs      # 日志控制
│   │   │   ├── lua_api.rs        # Lua 脚本引擎
│   │   │   ├── gpu_api.rs        # GPU 渲染接口
│   │   │   ├── data_receiver.rs  # 数据接收线程
│   │   │   ├── virtual_api.rs    # 虚拟设备 API
│   │   │   └── simple.rs
│   │   ├── core/
│   │   │   ├── plot/             # ★ 核心绘图引擎
│   │   │   │   ├── pipeline.rs       # 异步 envelope 预计算线程
│   │   │   │   ├── analog_segment.rs # f32 16ⁿ 层级金字塔
│   │   │   │   ├── time_bucket.rs    # f64 时间桶聚合
│   │   │   │   ├── data_buffer.rs    # ChannelBuffer 环形缓冲区
│   │   │   │   ├── query.rs          # LOD 金字塔查询
│   │   │   │   ├── envelope.rs       # RenderEnvelope 零拷贝结构
│   │   │   │   ├── ffi_bridge.rs     # C-ABI 桥接
│   │   │   │   ├── segment.rs        # 数据段管理
│   │   │   │   ├── lttb.rs           # LTTB 降采样
│   │   │   │   ├── lockfree_buffer.rs
│   │   │   │   └── constants.rs
│   │   │   ├── device/           # 设备管理
│   │   │   │   ├── registry.rs
│   │   │   │   ├── models.rs
│   │   │   │   └── preset.rs
│   │   │   ├── protocol/         # 协议解析插件
│   │   │   │   ├── trait.rs
│   │   │   │   ├── registry.rs
│   │   │   │   ├── csv_parser.rs
│   │   │   │   └── plugins/
│   │   │   │       ├── csv.rs
│   │   │   │       ├── modbus_rtu.rs
│   │   │   │       ├── modbus_tcp.rs
│   │   │   │       ├── scpi.rs
│   │   │   │       └── raw.rs
│   │   │   ├── session/          # 会话管理
│   │   │   │   ├── session_manager.rs
│   │   │   │   └── debug_session.rs
│   │   │   ├── transport/        # 传输层
│   │   │   │   ├── serial.rs
│   │   │   │   ├── tcp.rs
│   │   │   │   ├── modbus.rs
│   │   │   │   └── virtual_channel.rs
│   │   │   ├── virtual_device/   # 虚拟设备
│   │   │   │   ├── simulator.rs
│   │   │   │   ├── scpi_responder.rs
│   │   │   │   └── data_generator.rs
│   │   │   └── app_context.rs
│   │   ├── renderer/             # wgpu GPU 渲染
│   │   │   ├── gpu_renderer.rs
│   │   │   ├── shader_waveform.wgsl
│   │   │   ├── shader_lttb.wgsl
│   │   │   └── shader.wgsl
│   │   └── frb_generated.rs
│   └── target/
│
├── rust_builder/                 # FRB 构建桥 (cargokit)
├── windows/                      # Windows 平台文件 (CMake)
├── scripts/                      # Lua 示例脚本 (13个)
├── tools/                        # 辅助 Python 脚本
├── test_hardware/                # 硬件测试数据
├── docs/                         # 设计文档
├── assets/                       # 字体 (DS-Digital) + 图片
├── rebuild.ps1                   # ★ 一键构建脚本
└── pubspec.yaml
```

## 🔧 构建

### 环境要求

| 工具 | 最低版本 | 测试版本 |
|------|---------|---------|
| Flutter | 3.24+ | 3.41.7 |
| Rust | 1.75+ | 1.95.0 |
| flutter_rust_bridge | 2.0+ | 2.12.0 |
| Visual Studio 2022 | — | BuildTools (MSVC) |

### 一键构建 (Windows)

```powershell
powershell -ExecutionPolicy Bypass -File rebuild.ps1
```

脚本自动完成：Rust 编译 → Codegen 生成 → Flutter 编译 → 启动

### 分步构建

```powershell
# 1. Rust
cd rust; cargo build --release
Copy-Item target\release\vcr_lib.dll ..\build\windows\x64\runner\Release\

# 2. Dart bindings
cd ..; flutter_rust_bridge_codegen generate

# 3. Flutter
flutter build windows --release
```

### 调试运行

```powershell
flutter run -d windows    # Debug 模式（控制台可见日志）
```

### 国内镜像

```toml
# ~/.cargo/config.toml
[source.crates-io]
replace-with = 'rsproxy'
[source.rsproxy]
registry = "https://rsproxy.cn/index/"
```

## ⚙️ 核心设计

### 零拷贝 FFI

Flutter 端通过 `Pointer.asTypedList()` 将 Rust `Vec<f64>` 内存直接映射为 Dart `Float64List`，消除每帧约 8000 次 FFI 边界跨越。配合 gen-lock（双缓冲 + 奇偶世代号）保证读安全。

### LOD 金字塔

Rust 端维护两层金字塔结构，视口查询 O(log n)：
- **TimeBucketPyramid** (f64): 固定桶宽，适合时间序列
- **AnalogSegment** (f32, 10-level 16ⁿ): 高精度降采样，10 层级每层 16 倍聚合

### 性能优化

- **GC-free 数据缓冲** (`_DataBuf`): `Float64List` 预分配，零堆分配
- **帧预算保护** (`_tickBusy`): 跳过仍在渲染的帧，防止级联卡顿
- **空闲跳过**: `checkDataReady()` + `envelopeGetGeneration()` 检测无新数据时跳过重绘
- **EMA Y 轴平滑**: 40% 新值 + 60% 旧值，消除范围振荡
- **批量 FFI**: `pushChannelBatch()` 一次推送全部子采样点
- **Canvas 复用**: 静态 `Path` + `Paint` + `Float32List` 缓冲区
- **PictureRecorder 缓存**: Viewport 不变时跳过 `canvas.drawPath`

### Lua 脚本引擎

内置 mlua (Lua 5.3) 运行时，支持：
- 定时器、协程 (`sys.taskInit`, `sys.wait`)
- UART 收发 (`uart.write`, `uart.read`)
- 波形绘图 (`plot.add_data`)
- Pub/Sub 消息系统
- 自动化测试脚本

示例脚本见 `scripts/` 目录（13 个示例，从基础到协议解析）。

## 🖥️ 界面导航

| Tab | 路由 | 功能 |
|-----|------|------|
| Devices | `/`, `/devices` | 设备发现、连接管理 |
| Plot | `/monitor` | ★ 示波器波形界面 |
| Debug | `/debug` | 实时日志控制台 |
| Settings | `/settings` | 日志配置、主题 |
| Lua | `/lua` | 脚本编辑器 + 运行时 |

## 📊 依赖

### Rust (核心)

| crate | 用途 |
|-------|------|
| `flutter_rust_bridge` =2.12 | Flutter↔Rust FFI 桥梁 |
| `wgpu` 23 | WebGPU 硬件加速渲染 |
| `tokio` + `tokio-serial` | 异步运行时 + 串口 |
| `serialport` 4.6 | 同步串口通信 |
| `crossbeam-channel` | 线程间消息传递 |
| `mlua` 0.10 (lua53) | Lua 脚本引擎 |
| `parking_lot` | 高性能同步原语 |
| `chrono` + `serde` | 时间处理 + 序列化 |

### Flutter

| package | 用途 |
|---------|------|
| `flutter_rust_bridge` ^2.12 | FFI 集成 |
| `ffi` ^2.2 | 原生指针操作 |
| `file_picker` | 文件导入导出 |
| `flutter_highlight` | Lua 代码高亮 |

## 🤝 贡献

1. Fork → Feature Branch → PR
2. 遵循现有代码风格（Dart: lints 5.x, Rust: clippy）
3. 核心改动请附设计说明

## 📄 许可证

TODO
