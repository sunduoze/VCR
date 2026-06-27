# VCR 实时波形数据路径架构文档

> **版本**: 2026-06-27 | **审查者**: AI Code Reviewer

---

## 1. 概述

VCR 的实时波形渲染存在 3 条并行的数据路径（Flutter-Rust Bridge 生成代码路径、dart:ffi 手动零拷贝路径、Pipeline 后台线程路径），分别由不同模块维护，通过 4 个独立 flag 编排。本文档描述每条路径的角色、数据格式、性能特征和状态迁移。

---

## 2. 数据路径总览

```
                          Serial / TCP / Demo
                               │
                               ▼
                   ┌───────────────────────┐
                   │  Rust receive_loop    │ (debug_api.rs)
                   │  CSV parse → push     │
                   └──────┬────────────────┘
                          │
              ┌───────────┼───────────┐
              ▼           ▼           ▼
    ┌─────────────┐ ┌───────────┐ ┌──────────────────┐
    │ FRB Channel │ │ Pipeline  │ │ AnalogSegment    │
    │ Buffer      │ │ Thread    │ │ (f32 10-level)   │
    │ (plot_api)  │ │ (pipeline │ │ (analog_segment) │
    └──────┬──────┘ │ .rs)      │ └────────┬─────────┘
           │        └─────┬─────┘          │
           │              │                │
           ▼              ▼                ▼
    ┌──────────┐   ┌────────────┐   ┌──────────────┐
    │ Dart     │   │ FFI_CH_    │   │ FFI_CH_      │
    │ Timer    │   │ PYRAMIDS   │   │ ANALOG       │
    │ 50ms     │   │ (Mutex<    │   │ (RwLock<     │
    │ poll     │   │  HashMap>) │   │  HashMap>)   │
    └────┬─────┘   └─────┬──────┘   └──────┬───────┘
         │               │                 │
         ▼               ▼                 ▼
    ┌──────────────────────────────────────────┐
    │        _refreshViewportData()            │
    │  (plot_screen.dart, per-frame Ticker)    │
    │                                          │
    │  Routes:                                 │
    │  1. RENDER_ENVELOPE (pipeline 零拷贝)    │
    │  2. AnalogSegment C-ABI envelope         │
    │  3. Per-channel pyramid query fallback   │
    └──────────────────┬───────────────────────┘
                       │
                       ▼
              ┌─────────────────┐
              │  _PlotPainter   │
              │  CustomPainter  │
              └─────────────────┘
```

---

## 3. 路径详解

### 路径 A: Flutter-Rust-Bridge (FRB)

- **入口**: `lib/src/rust/api/plot_api.dart` (auto-generated)
- **Rust 端**: `plot_api.rs` → `PLOT_DATA` (PlotDataManager)
- **传输格式**: `List<DataPoint>` (每次调用涉及序列化/反序列化)
- **调用方**: `_realDataTimer` (50ms Timer) → `_fetchRealData()` → `plotGetChannelLatestData()`
- **性能**: 每次调用 ~1ms FFI 边界开销 + JSON 序列化。适用于首次全量加载（`ch.data.isEmpty` 时），增量路径每帧仅返回 delta 数据。
- **状态**: **活跃**，用于 Dart 端 `ch.data` 的维护（显示数值、导出 CSV、cursor 查询）。不用于渲染。

### 路径 B: Pipeline Thread (FFI 零拷贝)

- **入口**: `rust/src/core/plot/pipeline.rs`
- **触发**: `FfiBridge.instance.startPipeline()` → 后台线程每 16ms 执行一次
- **数据流**:
  1. `PENDING_BATCHES` (parking_lot::Mutex<Vec<BatchEntry>>) — push 方写入
  2. Pipeline thread: drain with pointer swap (~20ns lock hold)
  3. Process → `FFI_CH_PYRAMIDS` (Mutex<HashMap<u32, Arc<TimeBucketPyramid>>>) 
  4. Pre-compute `RENDER_ENVELOPE` (double-buffered Vec<Float64>, generation counter)
- **Dart 读取**: `_refreshViewportDataFromEnvelope()` — 通过 `dataPtr.asTypedList()` 一次映射，零 FFI 边界跨越
- **性能**: 每帧 ~300μs Rust 端计算 + ~5μs Dart 端读取（无拷贝）
- **状态**: **活跃**，`_pipelineEnabled` 控制
- **控制 flag**: `_pipelineEnabled` (工具栏按钮 `Icons.memory`)

### 路径 C: AnalogSegment Envelope

- **入口**: `rust/src/core/plot/analog_segment.rs`
- **数据格式**: f32（非 f64），10-level exponential pyramid（16^n 段大小）
- **Dart 读取**: `_refreshViewportFromAnalog()` — C-ABI `vcr_analog_get_envelope()` / `vcr_analog_get_trace()`
- **性能**: f32 节省一半内存，100M 样本约 400MB（vs f64 800MB）。阈值 `ENVELOPE_THRESHOLD` 控制 envelope/trace 模式切换。
- **控制 flag**: `_analogEnvelopeEnabled` (工具栏按钮 `Icons.stacked_bar_chart`)
- **依赖**: 可独立运行（不需要 Pipeline），也可与 Pipeline 配合（Pipeline 启用时走 RENDER_ENVELOPE 预计算）

---

## 4. Flag 组合与数据路径选择

| `_pipelineEnabled` | `_analogEnvelopeEnabled` | `_useRealData` | 活跃渲染路径 |
|:-:|:-:|:-:|---|
| ON | ON | ON | Pipeline RENDER_ENVELOPE (AnalogSegment 数据源) |
| ON | OFF | ON | Pipeline RENDER_ENVELOPE (TimeBucketPyramid 数据源) |
| OFF | ON | ON | Per-frame C-ABI analog envelope query |
| OFF | OFF | ON | Per-frame per-channel pyramid query (f64, fallback) |
| * | * | OFF | Demo 模式：每 16ms 生成正弦波 → pyramid push → query |

---

## 5. 关键模块文件

| 文件 | 层 | 角色 |
|------|------|------|
| `lib/screens/plot_screen.dart` | Dart UI | 主屏幕，Ticker 驱动，数据路由 |
| `lib/core/ffi_bridge.dart` | Dart FFI | 手动 dart:ffi 零拷贝绑定（C-ABI） |
| `lib/src/rust/api/plot_api.dart` | Dart FRB | FRB 自动生成 plot API 代理 |
| `lib/src/rust/api/data_receiver.dart` | Dart FRB | 数据接收器绑定（当前 TEMP no-op） |
| `rust/src/core/plot/pipeline.rs` | Rust | 后台线程，PENDING_BATCHES 处理，RENDER_ENVELOPE |
| `rust/src/core/plot/ffi_bridge.rs` | Rust | C-ABI 导出函数，FFI_CH_PYRAMIDS/FFI_CH_ANALOG |
| `rust/src/core/plot/time_bucket.rs` | Rust | f64 TimeBucketPyramid 实现 |
| `rust/src/core/plot/analog_segment.rs` | Rust | f32 AnalogSegment 10-level pyramid |
| `rust/src/core/plot/lockfree_buffer.rs` | Rust | SPSC lock-free ring buffer (feature-gated, 未集成) |
| `rust/src/api/plot_api.rs` | Rust | FRB plot API 实现 |
| `rust/src/api/debug_api.rs` | Rust | 接收循环，CSV 解析，Pipeline push |

---

## 6. 性能特征

| 指标 | 路径 B (Pipeline) | 路径 C (Analog) | 路径 A fallback (FRB query) |
|------|:--:|:--:|:--:|
| 每帧 Dart↔Rust 边界跨越 | 1 (dataPtr) | N×2 (per channel) | N (pyramidChQueryPoints) |
| 数据传输 | 零拷贝 (TypedList view) | calloc buffer 拷贝 | CDataPoint 结构体拷贝 |
| Rust 端锁争用 | parking_lot::Mutex (20ns) | RwLock::read (轻量) | Mutex per query |
| 适用数据量 | 任意 | ≤100M samples | ≤10K samples/viewport |
| 内存占用 | ~16MB (double buffer) | ~400MB @100M f32 | ~500KB buffers |

---

## 7. 废弃/未使用模块

| 模块 | 状态 | 说明 |
|------|------|------|
| `lib/chart_isolate.dart` | ❌ 已删除 | Dart isolate 渲染方案，已被 Ticker 替代 |
| `lib/ffi_bridge.dart` | ❌ 已删除 | 70行占位类，与 `lib/core/ffi_bridge.dart` 命名冲突 |
| `rust/src/core/plot/lockfree_buffer.rs` | 🟡 feature-gated | ~350行 SPSC lock-free buffer，`cargo build --features lockfree` 启用 |
| `rust/src/api/data_receiver.rs` | 🟡 TEMP no-op | `start_data_receiver()` 函数体为 `return;`，用于内存诊断 |
