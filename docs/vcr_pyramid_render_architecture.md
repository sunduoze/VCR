# VCR 数据金字塔 & 渲染管线架构

> 日期：2026-06-28 | 回滚基点：c350fa0 (修复部分bug并且更新readme)

---

## 一、总览：双金字塔 + Ticker 渲染循环

```
  Demo生成器 / 串口 / TCP
         │
         ▼
   push_sample_batch_with_x()  ←── 所有数据路径在此聚合
         │
    ┌────┴──────────────┐
    ▼                   ▼
  TimeBucket         AnalogSegment
  Pyramid            (10级封包金字塔)
  (4级时间桶)        │
    │                │
  FFI_CH_PYRAMIDS   FFI_CH_ANALOG
  (HashMap<u32>)    (HashMap<u32>)
    │                │
    └────────┬───────┘
             ▼
    _refreshViewportData()  [Ticker, ~60fps]
             │
    ┌────────┼────────────┐
    ▼        ▼            ▼
  RENDER_  Analog       Per-channel
  ENVELOPE GetEnvelope  pyramid query
  (零拷贝) (dart:ffi)   (fallback)
             │
             ▼
        _PlotPainter
       (CustomPainter)
```

---

## 二、两套金字塔系统

### A. TimeBucketPyramid（4级时间桶）

- **层级**: Level 0 (1s) → Level 1 (10s) → Level 2 (1min) → Level 3 (10min)
- **存储**: 每个 bucket 存 `{min, max, avg, count}` — 4 字段紧凑
- **写入**: `push_sample_batch_with_x()` → `FFI_CH_PYRAMIDS` → 按 timestamp 装桶
- **用途**: 长时间跨度（分钟级）波形概览，低内存占用
- **查询**: 按时间范围选层，返回 `BucketStats[]`
- **选层逻辑**: 根据时间范围 / 目标点数选择最合适的层级

### B. AnalogSegment（10级封包金字塔）

#### B.1 层级结构

| 层级 | 1个EnvelopeSample= | 积累因子 |
|------|-------------------|---------|
| L0 | 16 raw点 | 16^1 |
| L1 | 256 raw点 | 16^2 |
| L2 | 4,096 raw点 | 16^3 |
| ... | ... | ... |
| L9 | ~1.1×10^12 raw点 | 16^10 |

#### B.2 数据写入（级联压缩）

```
push_sample(value)
  │
  ├→ raw_trace.push(value)        // 全量原始trace（trace mode用）
  ├→ update global min/max        // O(1) Y轴自适应
  └→ raw_buffer.push(value)
       │
       └→ 攒满16个 → compute Level0 EnvelopeSample{min,max}
                       │
                       ├→ Level0.push(envelope)
                       └→ if Level0.len % 16 == 0:
                            compute Level1 envelope...
                            if Level1.len % 16 == 0:
                              → 级联上升（逐层触发）
```

#### B.3 层级选择（数学公式）

```
level = floor( ln(spp) / ln(16) - 1 )
spp   = samplesPerPixel = sampleCount × screenWidthPx / viewportSampleSpan
```

- **spp < 16** → Level 0（最精细）
- **spp越大** → 层级越高（压缩越大，性能越好）

#### B.4 查询：Coverage-aware fallback

```
get_envelope_section(start, end, spp):
  1. ideal_level = select_level_for_spp(spp)
  2. for level in ideal_level..0 (降级循环):
       coverage = actual_samples / requested_samples
       if coverage < 10% && level > 0:
         continue  // 数据未级联到位，降级
       else:
         return section[level][start>>N .. end>>N]
  3. 返回空section
```

#### B.5 关键特性

- **raw_trace**: 全量f32原始值，支持 trace mode (spp<2.0时逐点连线)
- **envelope_levels**: 10级预计算min/max，支持缩放后的envelope渲染
- **coverage-aware**: 新数据尚未级联到高层时自动降级，避免空洞

### C. 两套金字塔的职责分工

| 维度 | TimeBucketPyramid | AnalogSegment |
|------|-------------------|---------------|
| Key | 时间戳(ms) | 样本序号 |
| 用途 | 历史数据概览 | 实时示波器视图 |
| 层级 | 4级(1s~10min) | 10级(16x~16^10) |
| 粒度 | BucketStats{min,max,avg,count} | EnvelopeSample{min,max} |
| 查询 | 时间范围→选层→buckets | 样本范围+spp→选层→section |
| 适用 | 缩小后宽视口 | 放大后窄视口、滚动模式 |

---

## 三、Flutter 端 Ticker 渲染循环

```
Ticker.onTick() @~60fps (plot_screen.dart)

  1. _fetchRealData()
     ├─ 50ms独立定时器，通过 FRB plotGetChannelLatestData()
     ├─ 维护 ch.data: List<_DataPoint> (用于scale/cursor/legend)
     └─ 不阻塞渲染循环

  2. _refreshViewportData()  ← 核心入口
     │
     ├─ 路径1: RENDER_ENVELOPE (pipeline双缓冲零拷贝)
     │    if analogSetEnvelopeEnabled && gen counter even
     │    → envelopeReadData() → 零拷贝 Float64List
     │    → 直接填充 ch.viewportData / ch.envelopeData
     │    └── [状态] 已实现但写入端未连接数据源
     │
     ├─ 路径2: _refreshViewportFromAnalogImpl() (AnalogSegment C-ABI)
     │    for each channel:
     │      spp = sampleCount × widthPx / (_xMax - _xMin)
     │      startSample = 相对坐标→绝对索引
     │      clampedEnd = min(end, sampleCount)
     │
     │      if trace mode (spp < 2.0):
     │        → analogGetTrace(start, end) → f32列表
     │        → _DataBuf.fromTrace(values, relStart)
     │
     │      if envelope mode (spp >= 2.0):
     │        → analogGetEnvelope(start, end, spp)
     │        → section拼接循环 (跨level边界)
     │        → viewportData.add(xRel, yAvg)   // 平均线
     │        → envelopeData.add(xRel, yMin)   // 封包填充(下沿)
     │        → envelopeData.add(xRel, yMax)   // 封包填充(上沿)
     │    └── [当前问题] AnalogSegment需 ensure + push 才有效
     │
     └─ 路径3: Per-channel pyramid fallback
          if channel has no analog data
          → queryPerChannelPyramid(channelId, xMin, xMax)
          → List<BucketStats> → 构建 viewportData

  3. setState() → _PlotPainter.shouldRepaint()
     ├─ viewportRefreshCount 变化 → 必须重绘
     ├─ xMin/xMax/yMin/yMax 变化 → 必须重绘
     ├─ channel visible/color/lineStyle 变化 → 必须重绘
     └─ 否则 → 复用 PictureRecorder 缓存 (P2-2优化)

  4. _PlotPainter.paint()
     ├─ _drawStaticLayer()     // 网格/坐标轴 (PictureRecorder缓存)
     ├─ for each channel:
     │    if ch.viewportData.isNotEmpty:
     │      if envelope mode: _drawEnvelope()  // min-max半透明填充
     │                        _drawMinMaxLines() // 竖线结构
     │      _drawChannel()     // avg线 (折线或点)
     │    else if ch.data.isNotEmpty:
     │      → 降级用 ch.data 直接绘图 (O(n)遍历)
     ├─ _drawCrosshair()       // 光标十字线
     └─ _drawOverlay()         // FPS/点数信息
```

---

## 四、samplesPerPixel (SPP) 的数学含义

```
spp = sampleCount × screenWidthPx / (_xMax - _xMin)

其中:
  sampleCount = AnalogSegment中的总样本数
  screenWidthPx = 绘图区域宽度(像素)
  _xMax - _xMin = 当前视口覆盖的样本数跨度
```

| 用户操作 | _xMax-_xMin 变化 | spp 变化 | 金字塔层级 | 渲染模式 | 视觉效果 |
|---------|-----------------|---------|-----------|---------|---------|
| 放大(缩窄滑块) | 减小 | spp↑ | 升到高层 | envelope | 粗粒度的min-max带 |
| 缩小(拉宽滑块) | 增大 | spp↓ | 降到低层 | envelope/trace | 精细的封包 |
| 极致放大 | 极小(<2×screenWidth) | spp<2.0 | Level 0 | trace | 原始折线(逐点连线) |
| 极致缩小 | 极大 | spp很大 | L9 | envelope | 极粗粒度的概览 |

**核心设计理念**: 视口越窄(放大)，越可以用粗粒度的envelope；视口越宽(缩小)，越需要精细数据但屏幕像素有限，高层级envelope正好匹配。

---

## 五、Dart ↔ Rust 数据结构映射

```
Rust AnalogSegment                Dart PlotChannel
─────────────────                ─────────────────
raw_trace: Vec<f32>              .data: List<_DataPoint>
                                  (scale/legend/cursor查询)

envelope_levels[N]:               .viewportData: _DataBuf
  Vec<EnvelopeSample{min,max}>     (每tick填充，avg线)
    │
    ▼ getEnvelope → section
                                  .envelopeData: _DataBuf
                                   (每tick填充，min-max交错)

push_count: AtomicU64             生成时通过analogSampleCount()读取

EnvelopeSample{min, max}          _DataBuf中交错存储:
                                   [x0,y0, x1,y1, ...]  // viewport
                                   [x0,ymin0, x0,ymax0, x1,ymin1, ...]
                                   // envelope (每2个点一组min-max)
```

---

## 六、当前回滚状态 (c350fa0) 的问题与状态

### 已知问题

1. **AnalogSegment初始化时序**: `_analogEnvelopeEnabled = true` 默认开启，但 `_ensureAnalogSegments()` 只在用户点 toggle 时调用，`initState` 中未调用，导致启动后 AnalogSegment 为空的 Rust HashMap
2. **Demo数据推送**: Demo timer 中仅调用 `pushChannelBatch()` 推 TimeBucketPyramid，未调用 `analogPushSample()` 推 AnalogSegment
3. **RENDER_ENVELOPE零拷贝路径**: 读取端已实现，但 pipeline 线程写入端未连接 AnalogSegment 数据源

### 修复方向

- `initState` 中：`if (_analogEnvelopeEnabled) { _ensureAnalogSegments(); }`
- Demo timer 中：`for each sample: bridge.analogPushSample(i, val)`
- RENDER_ENVELOPE 写入端：pipeline 线程迭代 FFI_CH_ANALOG 并将 envelope section 写入双缓冲
