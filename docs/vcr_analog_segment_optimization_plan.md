# VCR 架构优化方案 —— 对标 AnalogSegment 参考架构

> 日期: 2026-06-21  
> 参考: `AnalogSegment_RustFlutter_Prompt.md` (Scopy AnalogSegment 设计规范)  
> 目标项目: `D:\AI\upper_computer_tools\VCR`

---

## 一、优化概览

| # | 模块 | 当前状态 | 目标 | 优先级 |
|---|------|---------|------|:---:|
| 1 | 核心数据结构 | 4层混合金字塔 + BucketStats(40B f64) | 10层16^n等比金字塔 + EnvelopeSample(8B f32) | 🔴 P0 |
| 2 | 金字塔算法 | 逐点push + 启发式层级选择 + 滑动窗口 | 增量构建 + 数学公式层级选择 + 时间/样本号双轴 | 🔴 P0 |
| 3 | 绘制管线 | 单envelope模式(4层渲染) | trace+envelope双模式 + ENVELOPE_THRESHOLD切换 | 🔴 P1 |
| 4 | 关键常量 | 自定义2/5/5/5混合 | 采用AnalogSegment精确规范 | 🟡 P2 |
| 5 | 关键缺失 | trace模式/全局min-max/事件推送/采样率感知 | 全部补齐 | 🟡 P2 |

---

## 二、核心数据结构替换

### 2.1 替换清单

| 当前 VCR | 替换为 (AnalogSegment 参考) | 涉及文件 |
|---------|---------------------------|---------|
| `BucketStats { timestamp_ms, min_value, max_value, avg_value, count }` (40B, f64) | `EnvelopeSample { min: f32, max: f32 }` (8B, f32) | `time_bucket.rs` |
| `TimeBucket { buckets: Vec<BucketStats>, write_idx, len }` 环形 | `EnvelopeLayer { length, capacity, samples: Vec<EnvelopeSample> }` 线性 | `time_bucket.rs` |
| 4 层 (Level 0~3) | 10 层 (Level 0~9) | `time_bucket.rs` |
| `TimeBucketPyramid::new()` 固定 4 层 | `AnalogSegment::new()` 10 层预分配 + 全局 min/max | `analog_segment.rs` (新) |
| `ChannelBuffer (Vec<DataPoint>)` | `SegmentStorage { data_chunks: Vec<Vec<u8>>, sample_count: AtomicU64, unit_size, start_time, samplerate, is_complete }` | `segment.rs` (新) |
| 保持: `MAX_CHANNELS = 64` | 不变 | `pipeline.rs` |

### 2.2 数据结构定义（新增）

```rust
// rust/src/core/plot/envelope.rs (新增)

#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct EnvelopeSample {
    pub min: f32,
    pub max: f32,
}

#[derive(Debug, Clone)]
pub struct EnvelopeLayer {
    pub length: u64,      // 逻辑 EnvelopeSample 数量
    pub capacity: u64,    // 已分配容量（ENVELOPE_DATA_UNIT 对齐）
    pub samples: Vec<EnvelopeSample>,
}

pub struct EnvelopeSection {
    pub start: u64,
    pub scale: u32,
    pub length: u64,
    pub samples: Vec<EnvelopeSample>,
}
```

```rust
// rust/src/core/plot/segment.rs (新增)

pub struct SegmentStorage {
    pub data_chunks: RwLock<Vec<Vec<u8>>>,     // 每块 MAX_CHUNK_SIZE
    pub sample_count: AtomicU64,                 // 无锁读取
    pub unit_size: u32,                          // = size_of::<f32>() = 4
    pub start_time: i64,
    pub samplerate: f64,
    pub is_complete: RwLock<bool>,
}
```

```rust
// rust/src/core/plot/analog_segment.rs (新增)

pub struct AnalogSegment {
    pub storage: SegmentStorage,
    pub envelope_levels: RwLock<Vec<EnvelopeLayer>>,  // 10 层
    pub min_value: RwLock<f32>,
    pub max_value: RwLock<f32>,
    pub owner: std::sync::Weak<Analog>,
    pub notify_samples: broadcast::Sender<SamplesAddedEvent>,
    pub notify_min_max: broadcast::Sender<MinMaxChangedEvent>,
}
```

### 2.3 迁移步骤

| Step | 内容 | 预估 |
|------|------|------|
| 1 | 新建 `envelope.rs`，定义 `EnvelopeSample`/`EnvelopeLayer`/`EnvelopeSection` | 0.3h |
| 2 | 新建 `segment.rs`，定义 `SegmentStorage` + `MAX_CHUNK_SIZE=1MB` | 0.3h |
| 3 | 新建 `analog_segment.rs`，定义 `AnalogSegment` 骨架（10层 + RwLock min/max） | 0.5h |
| 4 | 重写 `time_bucket.rs` → `AnalogSegment` 别名 / 兼容层 | 0.5h |
| 5 | 更新 `pipeline.rs` → 引用 `AnalogSegment` 替代 `TimeBucketPyramid` | 0.5h |
| 6 | 更新 `ffi_bridge.rs`/`ffi_bridge.dart` → 适配新结构体 | 0.5h |
| 7 | 单元测试 (35+ → 40+) | 0.5h |
| 8 | 端到端验证 (Demo + Real 模式) | 0.5h |

---

## 三、金字塔算法适配

### 3.1 常量对齐

```rust
// 当前 VCR
pub const LEVEL_WIDTHS: [f64; 4] = [2.0, 10.0, 50.0, 250.0];
pub const LEVEL_MAX_BUCKETS: [usize; 4] = [3600, 2160, 1440, 1008];

// → 替换为 AnalogSegment 参考规范
pub const ENVELOPE_SCALE_POWER: u32 = 4;
pub const ENVELOPE_SCALE_FACTOR: u32 = 1 << 4;           // = 16
pub const LN_ENVELOPE_SCALE_FACTOR: f64 = 2.772588722;   // ln(16)
pub const ENVELOPE_DATA_UNIT: usize = 64 * 1024;         // 64KB
pub const SCALE_STEP_COUNT: usize = 10;                  // Level 0~9
pub const UNIT_SIZE: usize = size_of::<f32>();           // = 4
pub const MAX_CHUNK_SIZE: usize = 1 * 1024 * 1024;       // 1MB
```

### 3.2 层级关系（精确保留参考规范）

| Level | 1 EnvelopeSample = ? 原始样本 | 等效原始样本数 |
|-------|------------------------------|:------------:|
| 0 | 16 个 f32 样本 | 16 (1<<4) |
| 1 | 256 个 f32 样本 | 256 (1<<8) |
| 2 | 4096 个 f32 样本 | 4096 (1<<12) |
| 3 | 65,536 个 f32 样本 | 65536 (1<<16) |
| ... | ... | ... |
| 9 | 16^10 个 f32 样本 | 1.1×10^12 (1<<40) |

通用公式: `Level L: 1 EnvelopeSample = 16^(L+1) 原始样本 = 2^(4×(L+1)) 原始样本`

### 3.3 构建算法：增量构建替代逐点更新

**当前 VCR 问题**: `push()` 每次添加一个点遍历所有 4 层 `update()`—复杂度 O(levels × points)。

```rust
// 当前 VCR: 每点遍历所有层 (低效)
pub fn push(&mut self, timestamp_ms: f64, value: f64) {
    for level in &mut self.levels {
        level.update(timestamp_ms, value);  // O(levels) per point
    }
}
```

**优化**: 采用 `append_payload_to_envelope_levels()` 增量构建：

```rust
// 参考架构: 按区间增量构建 (高效)
fn append_payload_to_envelope_levels(&self) {
    let sample_count = self.storage.sample_count.load(Ordering::Acquire);
    if sample_count < ENVELOPE_SCALE_FACTOR as u64 { return; }

    let mut levels = self.envelope_levels.write();

    // Level 0: 原始样本 → 第一层信封 (每 16 样本 1 个 EnvelopeSample)
    let e0 = &mut levels[0];
    let new_len = sample_count / ENVELOPE_SCALE_FACTOR as u64;
    for i in (old_len * 16..new_len * 16).step_by(16) {
        let (sub_min, sub_max) = self.range_min_max(i, i+16);
        e0.samples.push(EnvelopeSample { min: sub_min, max: sub_max });
    }

    // Level 1~9: 上层信封 → 下层信封 (每 16 个 EnvelopeSample 聚合为 1)
    for level_idx in 1..SCALE_STEP_COUNT {
        let new_len = levels[level_idx-1].length / ENVELOPE_SCALE_FACTOR as u64;
        for chunk in (old_len * 16..new_len * 16).step_by(16) {
            let sub = levels[level_idx-1].samples[chunk..chunk+16]
                .iter()
                .fold(levels[level_idx-1].samples[chunk], |a, s| EnvelopeSample {
                    min: a.min.min(s.min),
                    max: a.max.max(s.max),
                });
            levels[level_idx].samples.push(sub);
        }
    }
}
```

### 3.4 层级选择算法：数学公式替代启发式遍历

**当前 VCR**: 遍历 4 层 + 覆盖率回溯 O(levels + 多次查询)

```rust
// 当前 VCR
pub fn select_level(&self, t_min: f64, t_max: f64, target_points: usize) -> usize {
    for (i, level) in self.levels.iter().enumerate() {
        let buckets_in_range = (t_range / level.bucket_width_ms).ceil() as usize;
        if buckets_in_range <= target_points && data_span >= t_range * 0.1 {
            return i;
        }
    }
    self.levels.len() - 1
}
```

**优化**: 数学闭式解 O(1)

```rust
// AnalogSegment 参考算法 (需适配时间→样本号映射)
pub fn get_envelope_section(&self, start: u64, end: u64, samples_per_pixel: f32) -> EnvelopeSection {
    let total_samples = self.storage.sample_count.load(Ordering::Acquire);
    let end = end.min(total_samples);

    // 层级选择: ln(samples_per_pixel) / ln(16) - 1
    let min_level = if samples_per_pixel >= ENVELOPE_SCALE_FACTOR as f32 {
        let level_f = (samples_per_pixel.ln() / LN_ENVELOPE_SCALE_FACTOR) - 1.0;
        (level_f.floor() as i32).max(0) as usize
    } else {
        0
    };

    // 边界计算: 位运算精确对齐
    let scale_power = ((min_level + 1) * ENVELOPE_SCALE_POWER as usize) as u32;
    let scale = 1u64 << scale_power;
    let env_start = start >> scale_power;
    let env_end = ((end - 1) >> scale_power) + 1;

    let levels = self.envelope_levels.read();
    let layer = &levels[min_level];
    let actual_end = env_end.min(layer.length);
    let length = actual_end.saturating_sub(env_start);

    let samples = layer.samples[env_start as usize..(env_start + length) as usize].to_vec();

    EnvelopeSection {
        start: env_start << scale_power,
        scale,
        length: samples.len() as u64,
        samples,
    }
}
```

### 3.5 查询粒度：时间 → 样本号

| 当前 VCR | 优化后 |
|---------|--------|
| 查询基于 `timestamp_ms` (浮点时间，不准确) | 查询基于 `sample_number` (整数样本号，精确) |
| 无采样率概念 | `samples_per_pixel = samplerate × time_per_pixel` |
| `query(t_min, t_max, target_points)` | `get_envelope_section(start_sample, end_sample, samples_per_pixel)` |

### 3.6 全局 min/max O(1) 维护

```rust
// 在 append_payload_to_envelope_levels() 中维护
let mut min_val = *self.min_value.read();
let mut max_val = *self.max_value.read();
for i in (start..end).step_by(16) {
    let (sub_min, sub_max) = self.range_min_max(i, i+16);
    if sub_min < min_val { min_val = sub_min; }
    if sub_max > max_val { max_val = sub_max; }
}
*self.min_value.write() = min_val;
*self.max_value.write() = max_val;
```

---

## 四、Flutter 绘制管线优化

### 4.1 双模式架构

```
                  ┌───────────────────┐
                  │  ViewportConfig   │
                  │  (zoom level)     │
                  └────────┬──────────┘
                           │
                  samples_per_pixel =
                  samplerate × time_per_pixel
                           │
              ┌────────────┴────────────┐
              │                         │
    spp < ENVELOPE_THRESHOLD    spp >= ENVELOPE_THRESHOLD
              │                         │
    ┌─────────▼──────────┐    ┌─────────▼──────────────────┐
    │  trace 模式         │    │  envelope 模式              │
    │  (高采样率/放大)     │    │  (低采样率/缩小)            │
    ├────────────────────┤    ├────────────────────────────┤
    │ analog_segment_    │    │ analog_segment_get_        │
    │   get_samples()    │    │   envelope()               │
    │ ↓                  │    │ ↓                          │
    │ Vec<f32> 逐点      │    │ EnvelopeSection            │
    │ ↓                  │    │ (min/max pairs)            │
    │ Path.moveTo/       │    │ ↓                          │
    │   lineTo           │    │ _drawEnvelope (填充)       │
    │ → drawPath         │    │ _drawMinMaxLines (竖线)    │
    │                    │    │ _drawLine (avg 线)         │
    │                    │    │ _drawGapMarkers (缺口)     │
    └────────────────────┘    └────────────────────────────┘
```

### 4.2 模式切换阈值

```dart
// 新增常量
const ENVELOPE_THRESHOLD = 2.0;

/// samples_per_pixel < 2  → trace 模式（逐点折线，高采样率细节）
/// samples_per_pixel >= 2 → envelope 模式（min/max 聚合，缩放视图）
```

### 4.3 WaveformPainter 双模式实现

```dart
// lib/screens/plot_screen.dart — 在 _PlotPainter 中新增

enum PaintMode { trace, envelope }

class PaintCommand {
  final int channelId;
  final PaintMode mode;
  final Color color;
  final Float64List? samples;     // trace 模式
  final EnvelopeSectionData? envelope;  // envelope 模式
}

void _drawTrace(Canvas canvas, PlotChannel ch, _DataBuf data, ...) {
  // 逐点折线模式 — 用于高采样率（放大视图）
  // 复用 _polylinePath
  _linePaint.color = ch.color;
  _linePaint.strokeWidth = ch.lineWidth;
  
  final n = data.length;
  if (n < 2) return;
  
  _polylinePath.reset();
  _polylinePath.moveTo(_xToScreen(data.x(0), w) + ox, yTransform(data.y(0)) + oy);
  for (int i = 1; i < n; i++) {
    _polylinePath.lineTo(_xToScreen(data.x(i), w) + ox, yTransform(data.y(i)) + oy);
  }
  canvas.drawPath(_polylinePath, _linePaint);
}

@override
void paint(Canvas canvas, Size size) {
  // ...
  for (final cmd in commands) {
    switch (cmd.mode) {
      case PaintMode.trace:
        _drawTrace(canvas, cmd);
      case PaintMode.envelope:
        // 保持现有 4 层渲染
        _drawEnvelope(canvas, cmd);
        _drawMinMaxLines(canvas, cmd);
        _drawLine(canvas, cmd);
        _drawGapMarkers(canvas, cmd);
    }
  }
}
```

### 4.4 调用链重构

```dart
// _PlotScreenState._refreshViewportData() 内部

void _refreshViewportData() {
  final timePerPixel = (xMax - xMin) / plotW;
  final samplesPerPixel = samplerate * timePerPixel;

  if (samplesPerPixel < ENVELOPE_THRESHOLD) {
    // Trace 模式: 请求原始样本
    for (final ch in _visibleChannels) {
      final rawSamples = ffiBridge.getSamples(
        ch.id,
        _absoluteToSample(xMin),
        _absoluteToSample(xMax),
      );
      ch.viewportData = _DataBuf.fromFloats(rawSamples);
    }
  } else {
    // Envelope 模式: 使用现有 envelope 零拷贝路径
    _refreshViewportDataFromEnvelope();
  }
}
```

### 4.5 优化前后对比

| 维度 | 当前 | 优化后 |
|------|------|--------|
| 绘制模式数 | 1 (envelope only) | 2 (trace + envelope) |
| 模式切换 | 无 | `ENVELOPE_THRESHOLD = 2.0` (samples_per_pixel) |
| 放大视图 | 波形塌陷成直线 (桶数不足) | 逐点折线 (trace 模式) |
| 缩小视图 | 保持现有 4 层 envelope | 不变 |
| FFI 调用 | 1 次/envelope 帧 | 1 次/帧 (路径自动选择) |
| 回退路径 | fallback → 逐通道 pyramid 查询 | trace 模式使用独立 getSamples API |

---

## 五、关键常量替代（AnalogSegment 参考）

```rust
// ── 增量常量定义 (rust/src/core/plot/constants.rs 新增) ──

/// 缩放幂指数 — 每层信封以 2^4 = 16 倍聚合
pub const ENVELOPE_SCALE_POWER: u32 = 4;
/// 每层信封的缩放因子
pub const ENVELOPE_SCALE_FACTOR: u32 = 1 << 4; // 16
/// ln(16) ≈ 2.7726 — 层级选择预计算常量
pub const LN_ENVELOPE_SCALE_FACTOR: f64 = 2.772588722239781;
/// 信封内存分配对齐单位 (64KB)
pub const ENVELOPE_DATA_UNIT: usize = 64 * 1024;
/// 信封层级总数
pub const SCALE_STEP_COUNT: usize = 10;
/// 单样本字节数 (f32)
pub const UNIT_SIZE: usize = size_of::<f32>(); // 4
/// 原始数据分块存储大小 (1MB)
pub const MAX_CHUNK_SIZE: usize = 1 * 1024 * 1024;
/// 最大通道数 (保持现有)
pub const MAX_CHANNELS: usize = 64;

// ── Dart 侧 ──
const ENVELOPE_THRESHOLD = 2.0;  // trace/envelope 模式切换阈值
```

| 常量 | 当前 VCR 值 | 替换为 | 作用 |
|------|-----------|--------|------|
| 层级数 | 4 (自定义) | **10** (`SCALE_STEP_COUNT`) | 金字塔层数 |
| 缩放因子 | 2/5/5/5 (混合) | **16** (`ENVELOPE_SCALE_FACTOR`) | 层间缩放 |
| 对数常量 | 无 | **2.7726** (`LN_ENVELOPE_SCALE_FACTOR`) | 层级选择公式 |
| 内存对齐 | 无 | **64KB** (`ENVELOPE_DATA_UNIT`) | 分配优化 |
| 存储分块 | 无 | **1MB** (`MAX_CHUNK_SIZE`) | 原始数据分段 |
| 类型精度 | **f64** | **f32** (`UNIT_SIZE=4`) | 节省 50% 内存 |
| 通道上限 | **64** | **64** (不变) | — |

---

## 六、关键缺失项 (VCR vs 参考) 补齐计划

### 6.1 🔴 trace 模式 (P0)

**状态**: 缺失。放大时波形塌陷成直线。

**修复**: 在 `_PlotPainter` 中实现 `PaintMode.trace` + `samples_per_pixel < 2.0` 模式切换。

**涉及文件**: `plot_screen.dart` (新增 `_drawTrace` 方法 + `_refreshViewportData` 分支)

**预估**: 2h

### 6.2 🔴 10 层 16^n 等比金字塔 (P0)

**状态**: 缺失。当前 4 层混合比例金字塔覆盖范围不足 (252K ~10^7)。

**修复**: 替换 `TimeBucketPyramid` 为 `AnalogSegment` 10 层信封金字塔。

**涉及文件**: `time_bucket.rs` → `envelope.rs` + `analog_segment.rs` (新建), `pipeline.rs`, `ffi_bridge.rs`, `ffi_bridge.dart`

**预估**: 4h

### 6.3 🟡 数学化层级选择 (P1)

**状态**: 缺失。当前使用启发式遍历 + 覆盖率回溯。

**修复**: 实现 `ln(samples_per_pixel) / ln(16) - 1` 数学公式选择层级。

**涉及文件**: `analog_segment.rs` (新增 `get_envelope_section` 方法)

**预估**: 1h (依赖于 6.2)

### 6.4 🟡 全局 min/max O(1) 维护 (P1)

**状态**: 缺失。Y 轴自动量程需遍历查询。

**修复**: 在 `AnalogSegment` 中新增 `RwLock<f32>` 字段，`append_payload_to_envelope_levels()` 中维护。

**涉及文件**: `analog_segment.rs`

**预估**: 0.5h (依赖于 6.2)

### 6.5 🟡 事件推送通知 (P2)

**状态**: 缺失。当前使用 Ticker 每帧轮询 `VP_GEN`。

**修复**: 采用 `tokio::sync::broadcast` + `StreamSink` 推送 `SamplesAddedEvent`/`MinMaxChangedEvent`。

**涉及文件**: `analog_segment.rs`, `analog_segment_api.rs` (FFI 新), Dart 端 Riverpod 订阅

**预估**: 3h

### 6.6 🟡 采样率感知 (P2)

**状态**: 缺失。当前查询基于绝对时间戳，不感知采样率。

**修复**: 引入 `samplerate` 参数，实现 `sample_number ↔ timestamp_ms` 双向转换，`samples_per_pixel = samplerate × time_per_pixel`。

**涉及文件**: `analog_segment.rs`, `pipeline.rs`, `ffi_bridge.rs`

**预估**: 1h (依赖于 6.2)

---

## 七、实施优先级与排期

```
Phase 0 (核心数据结构 + 金字塔):  4h
  ├── 6.2 10层16^n金字塔    ──── 4h
  └── 6.1 trace模式         ──── 2h (并行)

Phase 1 (算法优化):            2h
  ├── 6.3 数学化层级选择     ──── 1h
  └── 6.4 全局min/max        ──── 0.5h

Phase 2 (架构完善):            4h
  ├── 6.5 事件推送           ──── 3h
  └── 6.6 采样率感知         ──── 1h

Phase 3 (测试验证):            2h
  ├── 单元测试 (40+)         ──── 1h
  └── 端到端 (Demo+Real)    ──── 1h
```

**总计估算**: 12h (1.5 工作日)

### 风险与约束

| 风险 | 缓解措施 |
|------|---------|
| `TimeBucketPyramid` 环形缓冲与 `AnalogSegment` 线性增长不兼容 | 保留 `MAX_BUCKETS` 限制作为可选容量上限 |
| f64→f32 精度损失可能影响 Demo 模式数据准确性 | Demo 模式数据在 f32 精度范围内 (≤2^24 整数精度) |
| 移除滑动窗口导致长时间采集内存无限增长 | 实现 `MAX_CHUNK_SIZE` 分块 + 可选总量限制 |
| `MAX_CHANNELS=64` 保持不变，与 10 层金字塔共存需验证 | 内存: 64×10×(8MB per level max) ≈ 5GB worst-case，需引入逐层容量上限 |
| Release 构建 DLL 路径问题 (`rust_lib_vcr.dll` vs `vcr_lib.dll`) | 独立于本次优化，保持现有 `Copy-Item` 修复策略 |

---

## 八、保留的 VCR 独有优势

以下 VCR 当前实现优于参考架构，继续保留：

| # | 特性 | 说明 |
|---|------|------|
| 1 | `PENDING_BATCHES` 批缓冲 | 解耦接收线程与金字塔线程，优于 reference 的直接 RwLock |
| 2 | `RenderEnvelope` 预计算 + 零拷贝 | 替代逐通道查询，保持性能 |
| 3 | 4 层渲染 (填充+竖线+avg+缺口) | envelope 模式保持现有渲染丰富度 |
| 4 | `PictureRecorder` 静态层缓存 | 网格/坐标轴缓存 (~60% 减少绘制) |
| 5 | LTTB 降采样实现 | `lttb.rs` 继续用于 avg 线优化 |
| 6 | C-ABI 裸 FFI + `asTypedList` 零拷贝 | 比 flutter_rust_bridge 更灵活 |
| 7 | Ticker vsync 驱动 | 保留，同时增加 StreamSink 作为补充通知机制 |
| 8 | Polygon closure edge fix | `PointMode.polygon → Path` 修复坚持使用 |

---

## 九、文件变更清单

| 操作 | 文件 | 说明 |
|------|------|------|
| **新增** | `rust/src/core/plot/constants.rs` | 关键常量集中定义 |
| **新增** | `rust/src/core/plot/envelope.rs` | EnvelopeSample, EnvelopeLayer, EnvelopeSection |
| **新增** | `rust/src/core/plot/segment.rs` | SegmentStorage 分块存储 |
| **新增** | `rust/src/core/plot/analog_segment.rs` | AnalogSegment: 10 层信封 + 全局 min/max + broadcast 通知 |
| **重写** | `rust/src/core/plot/time_bucket.rs` | 替换为基于 EnvelopeLayer 的实现或标记 deprecated |
| **修改** | `rust/src/core/plot/pipeline.rs` | FFI_CH_PYRAMIDS → AnalogSegment 引用；增量构建调用 |
| **修改** | `rust/src/core/plot/ffi_bridge.rs` | 新增 AnalogSegment 相关 C-ABI 函数 |
| **修改** | `rust/src/core/plot/lttb.rs` | 适配 EnvelopeSample → DataPoint 类型转换 |
| **修改** | `lib/screens/plot_screen.dart` | 新增 PaintMode.trace + _drawTrace + ENVELOPE_THRESHOLD |
| **修改** | `lib/core/ffi_bridge.dart` | 新增 getSamples/getEnvelope Section FFI 绑定 |
| **修改** | `lib/models/` | 新增 EnvelopeSectionData Dart 模型 |

---

## 十、成功标准

- [ ] `cargo check` 零错误零警告
- [ ] `flutter analyze` 零 issue
- [ ] `cargo test` 40+ 测试全部通过
- [ ] Demo 模式: 任意缩放级别波形无塌陷
- [ ] Real 模式: 实时采集 + 缩放 + 平移正常
- [ ] Release build: `cargo build --release` + `flutter build windows --release` 通过
- [ ] `vcr.exe` 双击启动无崩溃
- [ ] 内存: < 500MB @ 64 通道 × 1M samples (with capacity limits)
- [ ] FPS: ≥ 60 @ Demo 模式, ≥ 30 @ Real 模式
