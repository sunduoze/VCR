# VCR AnalogSegment 渲染路径修复 (2026-06-28)

## 目标
修复 Plot 中"调整滑块到小值(放大)后看老数据被压缩"的 bug。

## 双迭代修复

### 迭代 1 (`801f7f4`) — 无效
- 将 `_analogEnvelopeEnabled` 改为默认 `true`
- initState 中调用 `_ensureAnalogSegments()`
- Demo timer 中 `analogPushSample()`
- 修正 `samplesPerPixel` 公式、坐标映射
- **失效原因**：`_refreshViewportFromAnalogImpl()` 入口守卫 `bridge.envelopeGetNumChannels()` 始终为 0（`RENDER_ENVELOPE.num_channels` 只有 pipeline 线程设置，而 pipeline 从未启动）

### 迭代 2 (`be52119`) — 修复
- **关键改动**：`_refreshViewportFromAnalogImpl()` 绕过 `RENDER_ENVELOPE`，直接遍历 Flutter `_channels` 列表，每个 channel 独立调用 `analogSampleCount()` / `analogGetTrace()` / `analogGetEnvelope()`
- 移除对 pipeline 专属的 generation-counter 和 num_channels 的依赖

## 最终数据流
```
Demo Tick → analogPushSample() → AnalogSegment(10级全量金字塔)
                                    ↓
_refreshViewportData() → _refreshViewportFromAnalog() → 遍历 _channels
                                    ↓
                           analogGetEnvelope(start, end, spp)
                                    ↓
                           ch.viewportData / ch.envelopeData
```

## 文件修改
- `lib/screens/plot_screen.dart` — 主要修改文件
