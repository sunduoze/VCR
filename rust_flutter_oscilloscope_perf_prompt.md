# Rust + Flutter 工业级实时曲线（Oscilloscope）性能优化参考提示词

> 来源：微信公众号「字节忍者」「先瞳编码」三篇 Qt Oscilloscope 系列文章  
> 转译：将 Qt/C++ 概念映射到 Rust + Flutter + flutter_rust_bridge + wgpu 技术栈  
> 用途：作为 AI 编码会话的系统提示词/参考上下文，指导 Rust + Flutter 下实时波形渲染的性能优化

---

## 一、性能目标与反模式

### 工业级参数基准

| 参数 | 目标值 |
|------|--------|
| 采样率 | 100 ~ 500 kHz |
| 通道数 | 1 ~ 8 通道 |
| 显示窗口 | 5 ~ 10 秒 |
| 单通道数据量 | 100万 ~ 250万点 |
| 多通道总量 | 可达 2000万点 |
| 目标帧率 | 60 FPS（16ms/帧） |
| 运行要求 | 7×24h 连续，内存不增长 |

### ❌ 必须避免的反模式

```dart
// ❌ 反模式1：每帧全量重绘所有原始数据
@override
void paint(Canvas canvas, Size size) {
  for (final point in allPoints) {  // allPoints 无限增长
    canvas.drawLine(...);
  }
}

// ❌ 反模式2：用 Vec::push 无限追加
// Rust 侧
fn push_sample(&mut self, value: f64) {
    self.samples.push(value);  // 永远不释放，内存持续增长
}

// ❌ 反模式3：每帧重建 GPU 缓冲区
// wgpu 侧
queue.write_buffer(&buffer, 0, bytemuck::cast_slice(&all_vertices));  // 千万点全量上传
```

**后果**：
- 100万点 × 60FPS = 6000万次绘制操作/秒（单通道），8通道 = 12亿次/秒
- 运行 1 小时内存达几个 GB
- CPU 90%+，界面卡死

---

## 二、四大核心优化原则

### 原则 1：固定容量环形缓冲区（Ring Buffer）—— Rust 侧数据存储

**目标**：内存永不增长，O(1) 写入，适合 7×24h 运行。

**Rust 实现要点**：

```rust
use std::sync::Mutex;

/// 固定容量的无锁环形缓冲区（用于流式采样数据）
pub struct RingBuffer<T: Copy + Default> {
    buffer: Vec<T>,
    capacity: usize,
    head: usize,    // 下一个写入位置
    count: usize,   // 当前有效数据量
}

impl<T: Copy + Default> RingBuffer<T> {
    pub fn new(capacity: usize) -> Self {
        Self {
            buffer: vec![T::default(); capacity],
            capacity,
            head: 0,
            count: 0,
        }
    }

    /// O(1) 写入，满后自动覆盖最旧数据
    pub fn push(&mut self, value: T) {
        self.buffer[self.head] = value;
        self.head = (self.head + 1) % self.capacity;
        if self.count < self.capacity {
            self.count += 1;
        }
        // count 达到 capacity 后保持不变，旧数据被无缝覆盖
    }

    /// 获取从旧到新的所有有效数据的切片引用
    pub fn as_slice(&self) -> &[T] {
        let start = (self.head + self.capacity - self.count) % self.capacity;
        if start + self.count <= self.capacity {
            &self.buffer[start..start + self.count]
        } else {
            // 跨越环形边界时需拼接（调用方处理）
            &self.buffer  // 简化示例，生产代码应分两段返回
        }
    }

    pub fn len(&self) -> usize { self.count }
    pub fn is_full(&self) -> bool { self.count == self.capacity }
}
```

**线程安全版本**（采集线程写入，UI 线程读取）：

```rust
use std::sync::{Arc, RwLock};

pub type SharedRingBuffer<T> = Arc<RwLock<RingBuffer<T>>>;

// 采集线程：write lock
// UI 线程：read lock (RwLock 允许多读单写)
```

**关键特性**：
- 固定容量，无堆分配（初始分配后零 malloc）
- 写入 O(1)，可升级为 lock-free CAS（crossbeam/crossbeam-queue）
- 线程安全：采集线程写 → RwLock 写锁；渲染线程读 → RwLock 读锁（多读少写场景高性能）
- 容量计算公式：`capacity = sample_rate × window_seconds`（如 100kHz × 10s = 1,000,000）

---

### 原则 2：视口级降采样（Decimation / Envelope）—— 只绘制屏幕能显示的像素数

**核心认知**：屏幕宽度 1920px，100万数据点 = 每像素 520 个点，人眼无法分辨，纯浪费。

**✅ 正确做法**：按当前视口宽度降采样，每像素列只保留 min/max 值（Min-Max Envelope）。

```rust
/// Min-Max 包络降采样（保护尖峰不丢失）
/// screen_width: 当前视口的实际像素宽度
/// samples_per_pixel (spp): 每个像素列对应的原始采样点数 = data.len() / screen_width
pub fn decimate_minmax(data: &[f64], screen_width: u32) -> Vec<(f64, f64)> {
    let n = data.len();
    if n == 0 || screen_width == 0 {
        return vec![];
    }
    let spp = (n as f64 / screen_width as f64).max(1.0);
    let mut result = Vec::with_capacity(screen_width as usize);

    for px in 0..screen_width {
        let start = (px as f64 * spp) as usize;
        let end = ((px as f64 + 1.0) * spp).min(n as f64) as usize;
        if start >= end { continue; }

        let slice = &data[start..end];
        let min = slice.iter().cloned().fold(f64::INFINITY, f64::min);
        let max = slice.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        result.push((min, max));  // 每像素列画一条垂直线段 (min→max)
    }
    result
}
```

**多级金字塔优化**（适用于缩放/平移场景）：

```
Level 0 (L0): 原始采样数据    → 最多保留 7200 个数据单元
Level 1 (L1): 2x 降采样       → 每 2 点取 min/max
Level 2 (L2): 4x 降采样       → 每 4 点取 min/max
Level 3 (L3): 8x 降采样       → ...
...
Level N: 适合任意缩放级别

渲染时根据 spp（samples per pixel）自动选择最合适的金字塔层级。
```

**效果**：100万点 → ~1920×2 = 3840 个绘制点，**绘制量减少约 260 倍**，尖峰细节不丢失。

**Flutter 侧调用**：

```dart
// 通过 FFI 获取当前视口对应的 envelope 数据
final envelope = RustLib.instance.api.analogGetEnvelope(
  deviceKey: deviceIdx,
  channelId: channelId,
  startSample: viewportStart,
  endSample: viewportEnd,
  samplesPerPixel: (viewportEnd - viewportStart) ~/ widgetWidth,
);
// envelope 返回 min/max 对 + section metadata（start, scale），直接映射到屏幕坐标
```

---

### 原则 3：GPU 加速渲染 —— CustomPainter → wgpu

**与 Qt QPainter vs OpenGL 的映射**：

| Qt 概念 | Rust + Flutter 对应 |
|---------|-------------------|
| QPainter (CPU 光栅化) | CustomPainter 的 Canvas (Skia CPU/GPU) |
| QOpenGLWidget (GPU) | wgpu (Rust 原生 GPU 渲染) |
| VBO (顶点缓冲) | wgpu::Buffer (GPU Buffer) |
| glDrawArrays | wgpu render pass draw() |
| glBufferSubData (增量更新) | queue.write_buffer 增量写入 |

**性能对照**（参考 Qt 实测数据推算）：

| 数据量 | CustomPainter (FPS) | wgpu GPU (FPS) |
|--------|--------------------|--------------------|
| 1万 | 60 | 60 |
| 10万 | 55~60 | 60 |
| 50万 | 25~40 | 60 |
| 100万 | 10~25 | 60 |
| 500万 | <5 | 60 |
| 1000万 | <1 | 55~60 |

**GPU 渲染关键原则**：

```
✅ 一次性分配 GPU 缓冲区（创建时指定最大容量）
✅ 增量更新：只写新增/变化的数据片段（write_buffer offset+size）
✅ 数据驻留 GPU 显存，每帧只发 draw call
❌ 每帧重建整个缓冲区
❌ 每帧从 CPU 内存全量重新上传
```

**Rust wgpu 侧要点**：

```rust
// ✅ 初始化：预分配足够大的 GPU 缓冲区
let vertex_buffer = device.create_buffer(&wgpu::BufferDescriptor {
    label: Some("waveform_vertices"),
    size: (MAX_POINTS * std::mem::size_of::<Vertex>()) as u64,
    usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
    mapped_at_creation: false,
});

// ✅ 增量更新：每帧只写入新增数据
queue.write_buffer(
    &vertex_buffer,
    (write_offset * std::mem::size_of::<Vertex>()) as u64,
    bytemuck::cast_slice(&new_vertices),
);

// ❌ 避免：全量重建
// queue.write_buffer(&vertex_buffer, 0, bytemuck::cast_slice(&all_vertices));
```

---

### 原则 4：生产者-消费者解耦 —— 多线程架构

**架构模式**：

```
┌──────────────────────┐      ┌───────────────────────┐
│  采集线程 (Rust)      │      │  环形缓冲区 (Rust)     │
│  tokio::spawn /      │ ───→ │  Arc<RwLock<          │
│  std::thread         │      │    RingBuffer<f64>>   │
│  ~1ms 采样周期       │      │                       │
└──────────────────────┘      └───────────┬───────────┘
                                          │ 读取 (read lock)
                                          ▼
                                 ┌───────────────────────┐
                                 │  Flutter UI 线程       │
                                 │  Timer.periodic(16ms)  │
                                 │  → FFI 读取数据        │
                                 │  → 降采样              │
                                 │  → setState / 通知重绘 │
                                 └───────────┬───────────┘
                                             │
                                             ▼
                                 ┌───────────────────────┐
                                 │  CustomPaint / wgpu    │
                                 │  实际渲染 (60FPS)      │
                                 └───────────────────────┘
```

**关键约束**：

| 线程 | 职责 | 频率 | 关键技术 |
|------|------|------|---------|
| Rust 采集线程 | 数据生成/采集 + 写入 RingBuffer | ~1kHz | RwLock write, 无阻塞 |
| Rust tokio worker | 可选：数据预处理/降采样缓存 | 按需 | rayon 并行计算 |
| Flutter UI isolate | 定时读取 → 降采样 → 触发重绘 | 60Hz (16ms) | Timer.periodic, FFI |
| Flutter raster thread | 实际绘制（CustomPaint 或 wgpu） | 60Hz | 零拷贝数据传递 |

**反模式警告**：
- ❌ 采集线程直接 setState → UI 卡顿
- ❌ UI 线程内做降采样（耗时 > 2ms 会掉帧）→ 降到 Rust 侧或独立 isolate
- ❌ FFI 调用每次全量拷贝数据（应传指针/切片引用，减少内存拷贝）

---

## 三、flutter_rust_bridge 集成要点

### FFI 接口设计原则

```
✅ 批量获取：一次 FFI 调用返回整个视口的 envelope 数据
✅ 零拷贝优先：Rust 侧返回切片引用，Dart 侧用 Pointer 操作
✅ 异步优先：所有 FFI 调用用 async/await，释放 UI 线程
❌ 避免循环内逐点调用 FFI（每帧 3840 次调用 = 巨大开销）
```

### 推荐 FFI 接口签名

```rust
// ✅ 推荐：一次获取视口需要的所有 envelope 数据
pub fn analog_get_envelope(
    device_idx: u8,
    channel_id: u32,
    start_sample: u64,
    end_sample: u64,
    samples_per_pixel: u32,
) -> EnvelopeResult {
    // 返回 Vec<EnvelopeSample { min, max }> + section metadata
}

// ✅ 推荐：快速查询有效数据范围
pub fn analog_sample_count(device_idx: u8, channel_id: u32) -> u64;

// ❌ 避免：逐点查询
// pub fn get_sample(channel: u32, index: u64) -> f64;  // 高频场景下 FFI 开销爆炸
```

### Flutter 侧渲染管线

```dart
/// 视口数据刷新（每帧约 16ms 调用一次）
Future<void> _refreshViewport() async {
  // 1. 并行获取所有通道的 envelope 数据（一次 FFI 批量）
  for (final ch in _channels) {
    final count = RustLib.instance.api.analogSampleCount(
      deviceKey: ch.deviceIdx, channelId: ch.id);
    if (count == 0) continue;

    final result = RustLib.instance.api.analogGetEnvelope(
      deviceKey: ch.deviceIdx,
      channelId: ch.id,
      startSample: _viewportStart,
      endSample: _viewportEnd,
      samplesPerPixel: _viewportSamples ~/ _widgetWidth,
    );

    // 2. 映射到像素坐标 + 写入 GPU 缓冲区（或通知 CustomPaint 重绘）
    ch.updateEnvelopeData(result);
  }

  // 3. 触发重绘
  _repaintNotifier.value++;
}
```

---

## 四、性能问题排查清单

遇到波形渲染性能问题时，按以下顺序逐层排查：

| 优先级 | 检查项 | 症状 | 典型根因 |
|--------|--------|------|---------|
| P0 | **数据源是否有数据** | 波形完全空白 | RingBuffer 为空，或 FFI 路径未连接 |
| P0 | **降采样是否生效** | 百万点时卡顿 | 还在全量遍历原始数据绘制 |
| P1 | **FFI 调用频率** | 每帧卡顿 10ms+ | 循环内逐点 FFI 调用，应批量化 |
| P1 | **yScale 计算** | 波形几乎是直线 | `size.height / (2 * scale * 8)` 导致振幅被压缩，检查 Y 轴变换 |
| P1 | **shouldRepaint** | 不刷新 | 比较逻辑不精确，建议加 viewportRefreshCount |
| P2 | **GPU 缓冲区更新方式** | GPU 渲染仍卡 | 每帧全量 write_buffer 而非增量 |
| P2 | **setState 范围** | 帧率低 | setState 触发整个 Widget 树重建，改用 ValueNotifier/ChangeNotifier 局部刷新 |
| P2 | **Rust 侧锁争用** | FPS 波动 | RwLock 写锁持有时间过长，改用无锁结构 |
| P3 | **内存泄漏** | 长时间运行 OOM | Vec 无限 append，未使用固定容量 RingBuffer |

### 波形不显示的排查顺序（重要）

```
1. 先确认数据源 → Rust 侧 analogSampleCount() 是否返回 >0
2. 再检查 UI 调用 → paint() 是否被实际调用（加 debugPrint/counter）
3. 最后检查坐标计算 → yScale 是否太小导致波形缩成直线
```

---

## 五、优化决策树

```
数据量评估
│
├─ < 50万点 + 单通道
│   └─ CustomPainter + Canvas.drawPoints/drawLine ✅
│       + 降采样（减少计算量）
│       + ValueNotifier 局部刷新（减少 setState 范围）
│
├─ 50万~100万点 或 2~4通道
│   └─ CustomPainter ✅ 但必须降采样
│       + 降采样放 Rust 侧（rayon 并行）
│       + Timer 合并去抖（避免高频更新竞态）
│
├─ > 100万点 或 4~8通道
│   └─ 必须 wgpu GPU 渲染 ✅
│       + Rust 侧 ray/crossbeam 多线程降采样
│       + GPU buffer 增量更新（write_buffer offset）
│       + IndexedStack 页面切换时显式预初始化引擎（避免 lazy_static 竞态）
│
└─ > 500万点
    └─ wgpu 唯一选择 ✅
        + GPU buffer 流式更新（STREAM_DRAW 等价用法）
        + 可考虑异步 compute shader 做降采样
```

---

## 六、代码审查检查清单

在 Rust + Flutter 实时曲线代码 review 时，逐项检查：

### Rust 侧

- [ ] 数据存储是否使用固定容量 RingBuffer（而非 Vec::push 无限增长）
- [ ] 跨线程共享是否用 Arc<RwLock<T>> 或 lock-free 结构
- [ ] 降采样算法是否用 Min-Max（非平均值，避免丢失尖峰）
- [ ] 降采样是否考虑了环形缓冲区跨越边界的情况
- [ ] wgpu buffer 是否预分配 + 增量写入（而非每帧全量重建）
- [ ] FFI 接口是否批量化（一次调用返回视口全部数据）
- [ ] lazy_static / OnceLock 初始化是否有竞态风险

### Flutter 侧

- [ ] 是否避免在 build()/paint() 中做 FFI 调用（应前置到 Timer 回调）
- [ ] setState 是否触发范围过大（应用 ValueNotifier 局部刷新）
- [ ] shouldRepaint 是否精确比较（加 viewportRefreshCount 等标识）
- [ ] Timer 周期是否合理（60FPS = 16ms，数据采集周期可更短）
- [ ] 多通道是否并行 FFI 获取（而非串行逐通道等待）
- [ ] IndexedStack 页面切换时是否预初始化引擎

### 通用

- [ ] 内存占用是否随时间恒定（运行 10 分钟后检查）
- [ ] 60FPS 是否稳定（Profile mode 实测，非 Debug mode）
- [ ] 缩放/平移时 FPS 是否保持（spp 随视口动态变化）
- [ ] 7×24h 连续运行是否有内存泄漏迹象

---

## 七、关键词速查

| 问题 | 关键词 | 解决方向 |
|------|--------|---------|
| 内存持续增长 | ring buffer, fixed capacity, preallocate | 固定容量环形缓冲区 |
| CPU 渲染卡顿 | decimation, envelope, min-max, LOD | 视口降采样 + 多级金字塔 |
| GPU 渲染仍卡 | incremental update, write_buffer offset | 增量更新 GPU buffer |
| FFI 调用慢 | batch ffi, one-shot query | 批量接口设计 |
| 画面闪烁 | double buffer, offscreen, vsync | Flutter 原生双缓冲 |
| 线程阻塞 | producer-consumer, rwlock, lock-free | 采集与渲染解耦 |
| 波形不显示 | data source first, sample_count check | 数据源 → UI → 坐标逐层排查 |
| 波形被压缩 | yScale, amplitude, envelope metadata | 检查 Y 轴变换 + section start/scale |
| 缩放后卡顿 | pyramid level, spp adaptive, LOD | 根据 spp 自动选金字塔层级 |
