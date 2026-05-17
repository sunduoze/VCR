# Changelog

English | [中文](#变更日志)

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial project structure (Flutter + Rust)
- Real-time plotting with multi-channel support
- Data recording to CSV files
- Debug console with log output
- Viewport decimation for performance optimization
- Y-axis display options (share Y / per-channel Y)
- Scroll mode (oscilloscope-style)
- Data export/import (CSV format)
- Protocol support (serial, TCP/UDP)

### Fixed
- Y-axis display logic (yAxisChannels.length == 1)
- _fetchRealData() index error for new channels
- Scrollbar drag jitter
- Anti-aliasing color fade
- Pause button not stopping data updates

### Optimized
- Ring buffer (Rust-side, 10,000 points)
- Throttled UI updates (~30 FPS)
- Batch data fetching (single FFI call)

---

## [0.1.0] - 2026-05-18

### Added
- Project initialization
- Basic plotting functionality
- Rust backend integration
- FFI bindings (flutter_rust_bridge)

---

**Legend**:
- 🆕 Added (new features)
- 🔧 Fixed (bug fixes)
- ⚡ Optimized (performance improvements)
- 📝 Changed (changes in existing functionality)
- ⛔ Deprecated (soon-to-be removed features)
- ❌ Removed (now removed features)
- 🔒 Security (security fixes)

---

# 变更日志

[English](#changelog) | 中文

本项目所有值得注意的更改都将记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/),
本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/).

## [未发布]

### 新增
- 初始项目结构 (Flutter + Rust)
- 支持多通道的实时绘图
- 数据记录到 CSV 文件
- 带日志输出的调试控制台
- 视口降采样以优化性能
- Y 轴显示选项 (共享 Y / 每通道独立 Y)
- 滚动模式 (示波器风格)
- 数据导出/导入 (CSV 格式)
- 协议支持 (串口, TCP/UDP)

### 修复
- Y 轴显示逻辑 (yAxisChannels.length == 1)
- _fetchRealData() 新通道索引错误
- 滚动条拖动抖动
- 抗锯齿颜色变淡
- 暂停按钮无法停止数据更新

### 优化
- 环形缓冲区 (Rust 侧, 10,000 点)
- 节流 UI 更新 (~30 FPS)
- 批量数据获取 (单次 FFI 调用)

---

## [0.1.0] - 2026-05-18

### 新增
- 项目初始化
- 基本绘图功能
- Rust 后端集成
- FFI 绑定 (flutter_rust_bridge)

---

**图例**:
- 🆕 新增 (新功能)
- 🔧 修复 (错误修复)
- ⚡ 优化 (性能改进)
- 📝 更改 (现有功能更改)
- ⛔ 已弃用 (即将移除的功能)
- ❌ 已移除 (现已移除的功能)
- 🔒 安全 (安全修复)
