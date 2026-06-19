# VCR 部分通道无波形 - Bug Root Cause Analysis & Fix

**日期**: 2026-06-16 00:35
**问题**: 17个 demo 通道中，大部分曲线正常，但红框内几个通道看不到波形曲线（网格、Y轴标签、通道面板均正常显示）

## Root Cause

### 主因：Demo Timer 的 scroll mode 分支缺失 `_fitYAxis()`

**位置**: plot_screen.dart 第 567-573 行

`_updateRealDataUI()` (line 885) 已经在 RC3/RC4 中修复了这个问题，但 **demo timer 的回调没有同步修复**。

**结果**: scroll 模式下，各通道的 `ch.yMin`/`ch.yMax` 保持默认值 `[0, 1]`。所有数据值超出此范围的通道（如 ch3 的 [15..35]、ch7 的 [1500..4500]）波形全部被 `yTransform()` 映射到绘图区域外 → 不可见。

## 修复

### Fix 1: Demo Timer Y轴适配（plot_screen.dart line ~567-573）
在 `_scrollMode` 分支内添加 `if (_autoScaleY) _fitYAxis();`，与 `_updateRealDataUI` 保持一致。

### Fix 2: 调试日志（plot_screen.dart line ~712）
在 `_refreshViewportData` 中为每个通道输出：
- viewportData Y 数据范围
- ch.yMin / ch.yMax 对比
- 金字塔查询的 tMin/tMax

## 分析过程（工具链调用）

1. 完整读取 plot_screen.dart (3918 行) — 搜索所有渲染管线关键词
2. 对比 draw_utils.dart 的 yTransform 实现 — 已确认 RC4 修复正确
3. 验证 _drawEnvelope 数据格式和绘制顺序 — 无问题
4. 追踪 Rust 金字塔 pipeline：push → query → query_as_datapoints → _refreshViewportData → _drawChannel → _drawEnvelope + _drawLine
5. 排查 per-channel Y 轴、PictureRecorder 缓存、shouldRepaint 逻辑、canvas clip — 均无 bug
6. 最终定位：demo timer 与 _updateRealDataUI 行为不一致

## Build Status
- ✅ dart analyze 通过（0 issues）
- ✅ flutter build windows --debug 成功
- 输出: build/windows/x64/runner/Debug/vcr.exe
