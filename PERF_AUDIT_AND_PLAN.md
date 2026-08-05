# VCR 工业级实时曲线性能对照审计与重构路线图

> 参照：`rust_flutter_oscilloscope_perf_prompt.md`（Qt Oscilloscope 三篇文章转译为 Rust+Flutter+wgpu 技术栈）
> 审计日期：2026-08-05
> 审计范围：Rust（data_buffer.rs / pipeline.rs / gpu_renderer.rs / analog_segment.rs）+ Dart（plot_screen.dart ~3700行）

---

## 零、审计总览

| 维度 | 当前得分 | 目标 | 差距 |
|------|---------|------|------|
| 数据存储（固定容量环形缓冲） | 混合 | 全固定 | Dart `ch.data` List 无界 add() |
| 视口降采样（Min-Max Envelope） | 已实现 | OK | AnalogSegment 10级 + TimeBucketPyramid 4级 |
| GPU 加速 | 部分 | 全优化 | 预分配OK，但每帧全量 write + params_buffer 每次创建 |
| 生产者-消费者解耦 | 部分 | 全解耦 | pipeline 线程已解耦，但 Dart `ch.data.add()` 在主 Isolate |
| FFI 批量/零拷贝 | 已实现 | OK | batch push + envelope 零拷贝指针传递 |
| 内存稳定性（7x24h） | 不达标 | 达标 | Dart 端 `ch.data` 无限增长 |

---

## 一、逐项对照审计

### 原则 1：固定容量环形缓冲区（Ring Buffer）

| 检查项 | 现状 | 状态 |
|--------|------|------|
| Rust `ChannelBuffer` | back/front 双缓冲 Vec，满后环形覆盖 | OK |
| Rust 容量固定 | `back_capacity`，`push()` 满后覆盖旧数据 | OK |
| **Dart `ch.data`** | `List<_DataPoint>`，`add()` 不断追加 | **P0** |
| Dart 修剪策略 | 延迟修剪到 110% `_maxPoints`，`removeRange(0, n)` O(n) | WARN |
| 内存 7x24h 测试 | 未验证 | NO |

**问题详析**：
```
Demo mode 数据流：
  50ms timer x 8 sub-samples x 8 channels = 1280 points/sec
  ch.data.add() -> List 无限扩容 -> GC 压力累积

修剪逻辑 (L610)：
  if (ch.data.length > _maxPoints * 11 ~/ 10)  // 110%
    ch.data.removeRange(0, ch.data.length - _maxPoints)  // O(n)
```

**后果**：
- 运行 30min -> `ch.data` 约 2.3M 个 `_DataPoint`（~24 bytes each）= 55MB/channel
- GC STW 暂停 50-200ms -> 掉帧
- `removeRange` O(n)，250K 点约 2ms

### 原则 2：视口级 Min-Max 降采样

| 检查项 | 现状 | 状态 |
|--------|------|------|
| AnalogSegment 10级 envelope | 已实现，envelope_levels RwLock | OK |
| TimeBucketPyramid 4级 | L0/L1/L2/L3 滑动窗口 | OK |
| Min-Max（非平均值） | analog_segment.rs 保留 min/max | OK |
| spp 自适应层级选择 | select_level + query coverage 检查 | OK |
| 环形缓冲区边界处理 | as_slice 考虑 head 环绕 | OK |
| Dart `_refreshViewportData` | envelope/analog/pyramid 三级 fallback | OK |

**评价**：Rust 侧降采样已是工业级。核心问题是 Dart `ch.data` 还保留全量原始数据——降采样本该替代它。

### 原则 3：GPU 加速（wgpu）

| 检查项 | 现状 | 状态 |
|--------|------|------|
| 顶点缓冲区预分配 | `vertex_buffer` 一次性 500K 点 | OK |
| **增量写入** | `write_buffer(vertex_buffer, 0, ...)` 全量 | **P1** |
| **params_buffer 复用** | `run_lttb_compute` 中每帧 `create_buffer` | **P1** |
| **uniform_buffer 复用** | 每帧 `create_buffer` + `write_buffer` | **P1** |
| decimated_buffer 复用 | `ensure_decimated_buffer` 有扩容逻辑 | OK |
| GPU compute LTTB | compute shader 已实现 | OK |
| staging buffer pool | 双缓冲 readback | OK |

**具体问题位置**（`gpu_renderer.rs`）：
```rust
// L327 - 全量写入（应为增量）
self.queue.write_buffer(&self.vertex_buffer, 0, bytemuck::cast_slice(&points[..N]));

// L437 - 每帧创建（应预分配）
let params_buffer = self.device.create_buffer(&BufferDescriptor {...});

// L258 + L345 - uniform 每帧创建 + 写入
let uniform_buffer = device.create_buffer(...);
self.queue.write_buffer(&self.uniform_buffer, 0, bytemuck::cast_slice(&color));
```

### 原则 4：生产者-消费者解耦

| 检查项 | 现状 | 状态 |
|--------|------|------|
| Rust pipeline 线程 | `pipeline_loop` 独立线程，16ms 唤醒 | OK |
| PENDING_BATCHES 批量缓冲 | `Mutex<Vec<BatchEntry>>` + `std::mem::take` | OK |
| **采集线程锁争用** | `push_batch` 持 `devices.write()` 全局写锁 | **P2** |
| Dart Ticker 定时器 | `_onTick` 50ms（Demo）/ 100ms（Real） | OK |
| 帧预算守卫 | `_tickBusy` 防堆积 | OK |
| idleSkip 优化 | 版本号比较跳过无变化帧 | OK |

---

## 二、分阶段执行计划

### Phase 1：止血（P0 + P1，预计 2-3h）

**目标**：消除内存无限增长 + 修复 GPU 每帧浪费

| # | 优先级 | 任务 | 文件 | 改动 |
|---|--------|------|------|------|
| P0-1 | P0 | Dart `ch.data` 替换为固定容量环形缓冲 | `plot_screen.dart` + `plot_models.dart` | ~100行 |
| P0-2 | P0 | 移除 `removeRange` 延迟修剪 | `plot_screen.dart` L610-620 | -30行 |
| P1-1 | P1 | GPU `params_buffer` 预分配复用 | `gpu_renderer.rs` | ~25行 |
| P1-2 | P1 | GPU `uniform_buffer` 预分配复用 | `gpu_renderer.rs` | ~15行 |
| P1-3 | P1 | GPU `write_buffer` 增量写入 | `gpu_renderer.rs` | ~30行 |

**验证标准**：
- 运行 30min 内存稳定 < 200MB（当前 > 1GB）
- GPU `create_buffer` 调用从 3次/帧 -> 0次/帧

### Phase 2：锁优化（P2，预计 1-2h）

**目标**：消除采集线程与 UI 读取的锁争用

| # | 优先级 | 任务 | 文件 | 改动 |
|---|--------|------|------|------|
| P2-1 | P2 | `push_data/push_batch`：分离创建与写入路径 | `data_buffer.rs` | ~40行 |
| P2-2 | P2 | 统一使用 `parking_lot::RwLock` | `data_buffer.rs` | ~10行 |

**验证标准**：
- `push_batch` 写锁持有时间 < 1us
- Profile mode FPS 波动 < 5%

### Phase 3：Dart 数据管线精简（P3，预计 2-3h）

**目标**：Dart 侧只维护视口级 envelope，不保留全量数据

| # | 任务 | 文件 | 改动 |
|---|------|------|------|
| P3-1 | Demo 模式：`ch.data` 改为仅 cursor 追踪 | `plot_screen.dart` | ~50行 |
| P3-2 | Real 模式：确认数据完全走 Rust 侧金字塔 | `plot_screen.dart` | ~20行 |
| P3-3 | 保留 `ch.currentValue`（数值面板需要） | `plot_models.dart` | 不变 |
| P3-4 | 验证 minimap 仍可用（viewportData 替代 ch.data） | `plot_painter.dart` | ~30行 |

**验证标准**：
- 8ch x 250K 配置下 Dart 堆 < 20MB
- 数值面板实时更新
- Minimap 缩放粒度正确

---

## 三、不改动的部分（已达标）

以下模块已达到工业级标准：

- `analog_segment.rs`：10级 16^n envelope 金字塔
- `time_bucket.rs`：4级滑动窗口 + select_level + coverage
- `pipeline.rs`：PENDING_BATCHES + pipeline_loop + RenderEnvelope 零拷贝
- `ffi_bridge.rs`：dev_ch_key 复合键 + C-ABI 批量接口
- `lttb.rs`：CPU 侧 LTTB 降采样
- `lockfree_buffer.rs`：feature-gate 控制的 LockFreeRingBuffer

---

## 四、风险提示

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| Dart 环形缓冲导致数据丢失 | 低 | 中 | Demo 模式验证 30min |
| GPU params_buffer 生命周期 | 低 | 低 | 编译时检查 |
| `push_batch` 锁分离竞态 | 中 | 中 | 单线程先验证，再加并发测试 |
| Minimap 依赖 `ch.data` 全量 | 中 | 中 | P3-4 专门验证 |
