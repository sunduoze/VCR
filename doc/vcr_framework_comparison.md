# VCR 当前框架 vs 参考框架 — 详细架构对比分析

> 生成日期: 2026-06-21
> 核心约束: 每秒采集数百万采样点，渲染帧率稳定 >30fps，绝不丢失极窄毛刺

---

## 参考框架核心设计

```
多线程无锁流水线: 采集线程 → 环形缓冲 → 处理线程 → 降采样 → 渲染队列 → Flutter UI
降采样: Min-Max 按屏幕像素列分组，保留最大值和最小值，保证毛刺可见
FFI 设计: 共享内存 Uint8List 传递顶点数据，零拷贝
Flutter 渲染: CustomPainter 批量绘制 Min-Max 竖线，GPU 密度图（点精灵+加法混合）数字荧光效果
帧率控制: Ticker 驱动 VSync 同步，所有缓冲区预分配杜绝 GC 抖动
缩放: 多级降采样金字塔支持无级缩放 + LTTB 连线模式 + Fragment Shader 在线降采样
```

---

## 一、总体对比概览

| # | 维度 | 当前 VCR 实现 | 参考框架 | 完成度 | 优先级 |
|---|---|---|---|---|---|
| 1 | 采集→缓冲区 | Mutex + HashMap + Vec → 50ms Timer pull | 无锁 SPSC Ring Buffer + 处理线程 push | 30% | 🔴 P0 |
| 2 | FFI 零拷贝 | frb 序列化创建新 Dart List（回退路径） | C-ABI 直写 Float32List | 50% | 🔴 P0 |
| 3 | 降采样毛刺保证 | TimeBucketPyramid 4级 min/max 双通道 envelope | 像素列 Min-Max 分组 | 90% | — |
| 4 | 金字塔增量更新 | ✅ remove_older_than 增量移除 | 惰性重建 | 95% | — |
| 5 | LTTB 降采样 | 均匀步进 (step = N / targetPts) | LTTB 保形降采样 | 0% | 🟡 P1 |
| 6 | Ticker 帧率驱动 | Timer.periodic 50ms (≈20FPS 上限) | SchedulerBinding Ticker VSync (≥30FPS) | 0% | 🟡 P1 |
| 7 | 渲染路径 | drawRawPoints(polygon+lines) + Float32List 复用 | Min-Max 竖线批量 + GPU 密度图 | 80% | 🟢 P2 |
| 8 | 缓冲区预分配复用 | ✅ Float32List Static + PictureRecorder 内容哈希 | 预分配杜绝 GC | 90% | — |
| 9 | GPU 密度图/荧光效果 | ❌ wgpu 已集成但渲染路径未用 | 点精灵 + 加法混合 | 0% | 🟢 P2 |
| 10 | Fragment Shader 降采样 | ❌ | GPU 在线 Min-Max 聚合 | 0% | 🟢 P2 |

**总体完成度: ~60%** — 核心 Min-Max 毛刺保证、多级金字塔、缓冲区复用已就绪，但采集→渲染的流水线解耦和 FFI 零拷贝全链路是性能天花板。

---

## 二、P0 关键差距 — 详细分析

### 🔴 P0-1: 采集→缓冲区流水线解耦

#### 问题现状

```
串口读取 → push_data(device, channel, timestamp, value)
    → plot_data_devices.read()           // 全局 RwLock 读锁
        → channels.get(channel_name)    // HashMap 查找
            → channel_buffer.lock()     // 内层 Mutex 锁
                → back_data[back_write_pos] = DataPoint { ... }  // 写入
                → back_len += 1

50ms Timer 触发:
    _fetchRealData()
        → plotGetAllChannelLatestData()
            → plot_data_devices.read()  // 全局 RwLock 读锁
                → 遍历所有 device → channel
                    → channel_buffer.lock()  // 内层 Mutex
                        → drain front_data → Vec::to_vec()  // 堆拷贝
```

**瓶颈分析**:
- **双锁嵌套**: 外层 `RwLock<HashMap<String, HashMap<String, Arc<Mutex<ChannelBuffer>>>>>` + 内层 `Mutex<ChannelBuffer>`
- **每次 push 都经历**: RwLock read → HashMap find → Mutex lock → Vec write（4 步）
- **每次 drain 都经历**: RwLock read → 嵌套遍历 → Mutex lock per channel → Vec::to_vec()（堆分配）
- **50ms 间隔 = 每帧最多处理 20 次采集**，高频场景下数据堆积

#### 参考框架设计

```
采集线程:
    LockFreeRingBuffer::push(timestamp, value)  // atomic CAS, 零锁

处理线程 (独立 Rust 线程):
    loop {
        let batch = LockFreeRingBuffer::drain();  // atomic, 零锁
        for each point in batch:
            pyramid.insert(timestamp, value);      // 在线降采样
        render_queue.push(pyramid_viewport);       // 写入渲染队列
    }

Dart Ticker:
    onTick → ffi_read_render_queue(out_buffer)    // 零拷贝读取
           → setState → CustomPainter.paint
```

#### 当前已有基础设施

- ✅ `LockFreeRingBuffer` 已定义于 `ffi_bridge.rs`（容量 12,000,000）
- ✅ `FFI_RING` 全局无锁环形缓冲已就绪
- ✅ C-ABI 零拷贝已部分实现（`pyramid_query_points`）
- ⚠️ 但串口接收路径**未接入** LockFreeRingBuffer，仍走 `ChannelBuffer` 双锁路径

#### 修改计划

1. **Rust 侧**: 创建 `DataPipeline` 结构体，采集线程写 `LockFreeRingBuffer`，处理线程消费后写入 Per-Channel Pyramid
2. **Rust 侧**: 修改串口接收回调，从 `push_data` 改为 `LockFreeRingBuffer::push`
3. **Rust 侧**: 创建渲染队列（`RenderQueue`），处理线程维护最新视口数据
4. **Dart 侧**: Ticker 每帧从渲染队列零拷贝读取，替代 50ms Timer + `get_all_latest_data`

---

### 🔴 P0-2: FFI 零拷贝全链路

#### 问题现状

```
Dart 调用: plotGetAllChannelLatestData()
    → frb_generated 序列化 → Rust 执行
    → 返回值序列化为 Dart List<PlatformChannelData>
    → 每帧创建新 Dart 对象 → GC 累积
```

```dart
// 当前路径 (frb 序列化, 每次创建新 List)
final result = RustLib.instance.api.crateApiPlotApiPlotGetAllChannelLatestData();
for (final entry in result) {
    // entry.channelData 是 List<double> → Dart 堆分配
    ch.data.addAll(entry.channelData.map((v) => _DataPoint(ts, v)));
}
```

#### 参考框架设计

```dart
// 目标路径 (C-ABI 零拷贝)
final nativeBuf = calloc<Float64List>(capacity);
ffi.vcr_read_render_queue(nativeBuf);  // Rust 直接写入 Dart 预分配内存
// nativeBuf 被 CustomPainter 直接使用, 无任何中间分配
```

#### 当前已有基础设施

- ✅ `ffi_bridge.rs` 已定义 `CDataPoint { timestamp_ms: f64, value: f64 }` (repr(C))
- ✅ `vcr_pyramid_query_points` 已实现零分配：`ptr::copy_nonoverlapping` 直接写入 `out` 缓冲
- ✅ Dart 侧 `FfiBridge` 已有 dart:ffi 绑定框架
- ⚠️ 主数据路径 `get_all_latest_data` 仍走 frb 序列化

#### 修改计划

1. **Rust 侧**: 新增 `vcr_get_render_envelope(out: *mut f64, out_len: *mut u32)` C-ABI 函数，将信封数据直接写入 Dart 预分配的 Float32List
2. **Dart 侧**: 在 `FfiBridge` 添加 `getRenderEnvelope` dart:ffi 绑定
3. **Dart 侧**: `_updateRealDataUI` 直接使用 FFI 指针数据，消除 List 创建

---

## 三、P1 增量改进

### 🟡 P1-1: Ticker 驱动帧率

| 项目 | 当前 Timer 50ms | 目标 Ticker |
|---|---|---|
| 机制 | `Timer.periodic(Duration(ms: 50))` | `SchedulerBinding.instance.addPersistentFrameCallback` |
| 帧率 | 最高 20FPS，实际受 paint 阻塞影响 | 与屏幕刷新率同步 (60Hz → 30/60FPS) |
| 帧预算 | 无 VSync 对齐，可能跳帧或重复渲染 | 天然 VSync 对齐，按需渲染 |
| 实现复杂度 | — | 低（替换 Timer 为 Ticker） |

### 🟡 P1-2: LTTB 降采样

| 项目 | 当前均匀步进 | 目标 LTTB |
|---|---|---|
| 算法 | `step = N / targetPts`，每 step 取一个点 | Largest Triangle Three Buckets，选取最能代表局部形状的点 |
| 波形保真度 | 可能丢失快速变化的尖峰 | 保留视觉关键转折点 |
| 实现复杂度 | — | 中（需在 Rust 侧实现 LTTB 算法，金字塔查询返回 LTTB 结果） |

---

## 四、P2 视觉增强

### 🟢 P2-1: GPU 密度图渲染

wgpu 已集成（`gpu_renderer.rs` / `gpu_api.rs`），但目前渲染路径未使用。目标：
- 点精灵 (Point Sprite) + 加法混合 (Additive Blending) → 数字荧光效果
- 高频数据区域自动变亮，模拟模拟示波器余辉

### 🟢 P2-2: Fragment Shader 在线降采样

将 Min-Max 聚合卸载到 GPU：
- 原始数据一次性上传到 GPU Buffer
- Fragment Shader 按像素列实时计算 min/max
- CPU 侧只维护金字塔元数据（用于缩放级别选择）

---

## 五、实施路线图

| 阶段 | 内容 | 预计工作 | 前置依赖 |
|---|---|---|---|
| **Phase A - P0 双核心** | 无锁流水线 + FFI 零拷贝全链路 | 8-12 文件修改 | 无 |
| **Phase B - P1 帧率质量** | Ticker 驱动 + LTTB 降采样 | 3-5 文件修改 | Phase A |
| **Phase C - P2 GPU** | GPU 密度图 + Shader 降采样 | 4-6 文件修改 | Phase A |
| **Phase D - 验证调优** | 170K pts × 17ch 压测 FPS >30 | 测试 + 调优 | Phase B/C |

---

## 六、关键代码路径

| 文件 | 当前职责 | Phase A 变更 |
|---|---|---|
| `rust/src/core/transport/serial.rs` | 串口 Win32 API 读写 | 采集线程接入 LockFreeRingBuffer |
| `rust/src/core/plot/data_buffer.rs` | 双缓冲 ChannelBuffer + PlotDataManager | 简化/废弃，由无锁流水线替代 |
| `rust/src/core/plot/ffi_bridge.rs` | C-ABI 零拷贝桥接 | 新增 RenderQueue FFI 函数 |
| `rust/src/core/plot/time_bucket.rs` | TimeBucketPyramid 4 级 | 对接处理线程在线插入 |
| `rust/src/api/plot_api.rs` | flutter_rust_bridge API | 新增 pipeline 控制 API |
| `lib/screens/plot_screen.dart` | Dart 渲染层 | Ticker 替换 Timer，零拷贝读取 |
| `lib/core/ffi_bridge.dart` | Dart dart:ffi 绑定 | 新增零拷贝读取绑定 |
