# VCR - Visual Data Recording & Plotting Tool

English | [中文](#vcr---可视化数据记录与绘图工具)

A cross-platform desktop application for real-time data visualization, built with **Flutter** and **Rust**.

## 🚀 Features

- **Real-time Plotting**: Multi-channel data visualization with adjustable sample rates
- **Data Recording**: Save data to CSV files for offline analysis
- **Protocol Support**: Serial port, TCP/UDP, and custom protocols
- **Cross-platform**: Windows, Linux (WIP)
- **High Performance**: Rust backend with Flutter frontend
- **Flexible Display**: Share Y-axis, per-channel Y-axis, scroll mode (oscilloscope-style)
- **Data Export/Import**: CSV import for offline analysis
- **Debug Console**: Real-time log output for troubleshooting

## 📦 Architecture

```
VCR/
├── lib/                  # Flutter frontend
│   ├── screens/         # UI screens (plot_screen.dart)
│   ├── widgets/         # Reusable widgets
│   └── models/          # Data models
├── rust/                # Rust backend
│   ├── src/
│   │   ├── api/         # FFI bindings (debug_api.rs, plot_api.rs)
│   │   ├── core/        # Core logic (protocol, plot)
│   │   └── ffi/        # Foreign function interface
│   └── Cargo.toml
├── linux/               # Linux platform files
├── windows/             # Windows platform files
└── test/                # Unit and integration tests
```

## 🛠️ Building from Source

### Prerequisites

- **Flutter**: 3.24+ (tested on 3.41.7)
- **Rust**: 1.75+ (tested on 1.95.0)
- **flutter_rust_bridge**: 2.0+ (tested on 2.12.0)
- **Visual Studio 2022** (Windows only, for MSVC toolchain)

### Windows

```powershell
# Clone the repository
git clone <repo-url>
cd VCR

# Install dependencies
flutter pub get
cargo build --release

# Generate FFI bindings
flutter_rust_bridge_codegen generate

# Build the application
flutter build windows --release
```

### Linux (Work in Progress)

```bash
# Install dependencies
sudo apt-get install libudev-dev

# Build
flutter build linux --release
```

## ⚙️ Configuration

### Rust Mirror (China)

If you're in China, configure Rust crate mirror:

```toml
# ~/.cargo/config.toml
[source.crates-io]
replace-with = 'rsproxy'

[source.rsproxy]
registry = "https://rsproxy.cn/index/"
```

### Flutter Mirror (China)

```bash
# Use Tsinghua mirror
export FLUTTER_STORAGE_BASE_URL=https://mirrors.tuna.tsinghua.edu.cn/flutter
flutter config --enable-windows-uwp-desktop
```

## 🐛 Debugging

### Debug Console

The application includes a debug console window that shows real-time logs:

- **Log file**: `vcr_debug_YYYYMMDD_HHMMSS.log` (saved in working directory)
- **Log levels**: `debug`, `info`, `warn`, `error`
- **Dual output**: Logs are written to both file and debug console

### Common Issues

**1. Ch0 Data Display Error**
- **Symptom**: Ch0 curve shape is incorrect
- **Cause**: CSV parsing may misinterpret prefix
- **Fix**: Check `rust/src/core/protocol/csv_parser.rs`

**2. Pause Button Doesn't Stop Data**
- **Symptom**: Pause button doesn't stop data updates
- **Cause**: Timers not cancelled on pause
- **Fix**: Cancel `_fetchTimer` and `_realDataTimer` in `_togglePause()`

**3. Y-Axis Display Issue**
- **Symptom**: Y-axis shows incorrectly when all channels have `showYAxis = false`
- **Cause**: `yAxisChannels.length <= 1` incorrectly handles empty list
- **Fix**: Changed to `yAxisChannels.length == 1`

## 📊 Performance Optimization

- **Viewport Decimation**: Automatically decimates data when zooming/scrolling
- **Ring Buffer**: Rust-side `ChannelBuffer` uses fixed-size ring buffer (10,000 points)
- **Throttled UI Updates**: UI updates throttled to ~30 FPS
- **Batch Data Fetching**: Single FFI call fetches all channel data

## 🤝 Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/foo`)
3. Commit your changes (`git commit -am 'Add foo'`)
4. Push to the branch (`git push origin feature/foo`)
5. Create a Pull Request

## 📄 License

TODO: Add license information

---

# VCR - 可视化数据记录与绘图工具

[English](#vcr---visual-data-recording--plotting-tool) | 中文

一个用于实时数据可视化的跨平台桌面应用程序，使用 **Flutter** 和 **Rust** 构建。

## 🚀 功能特性

- **实时绘图**：多通道数据可视化，可调采样率
- **数据记录**：保存数据到 CSV 文件，用于离线分析
- **协议支持**：串口、TCP/UDP、自定义协议
- **跨平台**：Windows、Linux（进行中）
- **高性能**：Rust 后端 + Flutter 前端
- **灵活显示**：共享 Y 轴、每通道独立 Y 轴、滚动模式（示波器风格）
- **数据导出/导入**：CSV 导入用于离线分析
- **调试控制台**：实时日志输出，便于故障排查

## 📦 项目结构

```
VCR/
├── lib/                  # Flutter 前端
│   ├── screens/         # UI 界面 (plot_screen.dart)
│   ├── widgets/         # 可复用组件
│   └── models/          # 数据模型
├── rust/                # Rust 后端
│   ├── src/
│   │   ├── api/         # FFI 绑定 (debug_api.rs, plot_api.rs)
│   │   ├── core/        # 核心逻辑 (protocol, plot)
│   │   └── ffi/        # 外部函数接口
│   └── Cargo.toml
├── linux/               # Linux 平台文件
├── windows/             # Windows 平台文件
└── test/                # 单元测试和集成测试
```

## 🛠️ 从源码构建

### 依赖项

- **Flutter**: 3.24+ (测试版本 3.41.7)
- **Rust**: 1.75+ (测试版本 1.95.0)
- **flutter_rust_bridge**: 2.0+ (测试版本 2.12.0)
- **Visual Studio 2022** (仅 Windows，用于 MSVC 工具链)

### Windows

```powershell
# 克隆仓库
git clone <repo-url>
cd VCR

# 安装依赖
flutter pub get
cargo build --release

# 生成 FFI 绑定
flutter_rust_bridge_codegen generate

# 构建应用程序
flutter build windows --release
```

### Linux (进行中)

```bash
# 安装依赖
sudo apt-get install libudev-dev

# 构建
flutter build linux --release
```

## ⚙️ 配置

### Rust 镜像源（中国）

如果您在中国，请配置 Rust crate 镜像源：

```toml
# ~/.cargo/config.toml
[source.crates-io]
replace-with = 'rsproxy'

[source.rsproxy]
registry = "https://rsproxy.cn/index/"
```

### Flutter 镜像源（中国）

```bash
# 使用清华镜像
export FLUTTER_STORAGE_BASE_URL=https://mirrors.tuna.tsinghua.edu.cn/flutter
flutter config --enable-windows-uwp-desktop
```

## 🐛 调试

### 调试控制台

应用程序包含调试控制台窗口，可显示实时日志：

- **日志文件**: `vcr_debug_YYYYMMDD_HHMMSS.log` (保存在工作目录)
- **日志级别**: `debug`, `info`, `warn`, `error`
- **双输出**: 日志同时写入文件和调试控制台

### 常见问题

**1. Ch0 数据显示错误**
- **症状**: Ch0 曲线形状不正确
- **原因**: CSV 解析可能错误解释前缀
- **修复**: 检查 `rust/src/core/protocol/csv_parser.rs`

**2. 暂停按钮无法停止数据**
- **症状**: 暂停按钮无法停止数据更新
- **原因**: 暂停时未取消定时器
- **修复**: 在 `_togglePause()` 中取消 `_fetchTimer` 和 `_realDataTimer`

**3. Y 轴显示问题**
- **症状**: 所有通道 `showYAxis = false` 时 Y 轴显示不正确
- **原因**: `yAxisChannels.length <= 1` 错误处理空列表
- **修复**: 改为 `yAxisChannels.length == 1`

## 📊 性能优化

- **视口降采样**: 缩放/滚动时自动降采样数据
- **环形缓冲区**: Rust 侧 `ChannelBuffer` 使用固定大小环形缓冲区（10,000 点）
- **节流 UI 更新**: UI 更新节流到 ~30 FPS
- **批量数据获取**: 单次 FFI 调用获取所有通道数据

## 🤝 贡献

欢迎贡献！请遵循以下步骤：

1. Fork 本仓库
2. 创建功能分支 (`git checkout -b feature/foo`)
3. 提交更改 (`git commit -am 'Add foo'`)
4. 推送到分支 (`git push origin feature/foo`)
5. 创建 Pull Request

## 📄 许可证

TODO: 添加许可证信息

---

## 📝 TODO

- [ ] Add unit tests for Rust backend
- [ ] Add widget tests for Flutter frontend
- [ ] Implement Linux CI build (currently commented out due to Rust compilation errors)
- [ ] Add more protocol plugins (Modbus, CAN bus)
- [ ] Add data analysis tools (FFT, filtering)
- [ ] Add multi-language support (i18n)
