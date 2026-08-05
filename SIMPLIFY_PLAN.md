# VCR 架构简化：Min-Max Decimation 替代 10级金字塔

> 日期：2026-08-06
> 方案：移除 AnalogSegment / TimeBucketPyramid / pipeline / envelope / ffi_bridge / lttb 全部降采样层，保留 ChannelBuffer 为唯一 Rust 数据源，在 Dart painter 层按像素做 Min-Max 降采样。

## 为何简化

1. **复杂度不匹配**：10 级 AnalogSegment + 4 级 TimeBucketPyramid + pipeline 线程 + ffi_bridge C-ABI — 约 3000 行 Rust + 500 行 Dart FFI — 服务于"每像素列 min/max"这一目标
2. **降采样位置冗余**：pipeline→envelope→analog→pyramid→Dart fallback 五级 fallback，其中前三层从未被实际使用过（pipeline 线程未启动，RENDER_ENVELOPE.num_channels=0）
3. **Min-Max 像素降采样**：1M 点 → 1920 像素 × 2 点/像素 = 3840 个绘制图元，绘制量减少 260 倍，同时保留峰值细节

## 删除的文件

| 路径 | 大小 | 原因 |
|------|------|------|
| rust/src/core/plot/analog_segment.rs | ~900行 | 10级 envelope 金字塔，完全替代 |
| rust/src/core/plot/time_bucket.rs | ~400行 | 4级 TimeBucketPyramid，完全替代 |
| rust/src/core/plot/pipeline.rs | ~600行 | pipeline 线程 + RenderEnvelope，完全替代 |
| rust/src/core/plot/ffi_bridge.rs | ~800行 | C-ABI 降采样桥接，完全替代 |
| rust/src/core/plot/envelope.rs | ~200行 | EnvelopeLayer/EnvelopeSection 类型定义 |
| rust/src/core/plot/segment.rs | ~200行 | SegmentStorage |
| rust/src/core/plot/lttb.rs | ~100行 | CPU 侧 LTTB |
| rust/src/core/plot/constants.rs | ~30行 | envelope 常量 |
| lib/core/ffi_bridge.dart | ~350行 | Dart FFI 绑定 |

## 保留文件及其改动

| 路径 | 改动 | 说明 |
|------|------|------|
| rust/src/core/plot/data_buffer.rs | 保留 | ChannelBuffer + PlotDataManager，唯一数据源 |
| rust/src/core/plot/mod.rs | 仅导出 data_buffer | 移除 6 个 module + 6 个 pub use |
| rust/src/api/plot_api.rs | 移除 push/pipeline 相关 | 仅保留注册/查询 ChannelBuffer 的 API |
| rust/src/api/debug_api.rs | 移除 analog/pipeline 相关 | - |
| rust/src/core/plot/mod.rs | 清理 | - |
| rust/src/lib.rs | 无改动 | core::plot 保留 |
| lib/screens/plot_screen.dart | ~200行删减 | 移除 pipeline/envelope/analog 分支 |
| lib/screens/plot_models.dart | 移除 plot groups | 简化 DeviceContext |
| lib/screens/plot_painter.dart | +Min-Max | 在 painter 层做像素级降采样 |
| lib/src/rust/api/plot_api.dart | FRB 自动生成 | - |

## 新数据流

```
Demo/Real Timer
   └─> Dart ch.data (FixedCapacityRing, 250K 环形)
       └─> ch.viewportData (Min-Max 降采样，_refreshViewportData)
           └─> PlotPainter.paint() 直接绘制
```

**Min-Max 降采样逻辑**（替换 _refreshViewportData 中所有 pipeline/envelope/analog/pyramid 分支）：

```dart
void _refreshViewportData() {
  final w = _screenWidth.round().clamp(1, 4096);
  for (int ci = 0; ci < _channels.length; ci++) {
    final ch = _channels[ci];
    if (!ch.visible || ch.data.isEmpty) continue;
    
    final total = ch.data.length;
    final step = max(1, total ~/ w);
    ch.viewportData.clear();
    ch.envelopeData.clear();
    
    for (int x = 0; x < w; x++) {
      final start = x * step;
      final end = min(start + step, total);
      if (start >= total) break;
      
      double curMin = ch.data[start].y;
      double curMax = ch.data[start].y;
      for (int i = start + 1; i < end; i++) {
        final v = ch.data[i].y;
        if (v < curMin) curMin = v;
        if (v > curMax) curMax = v;
      }
      final xVal = ch.data[end - 1].x - newestAbsX; // relative X
      ch.viewportData.add(xVal, (curMin + curMax) * 0.5);
      ch.envelopeData.add(xVal, curMin);
      ch.envelopeData.add(xVal, curMax);
    }
  }
}
```

## 性能预期

- 1M 点 × 1920 像素 × 1 次遍历 = 1M 次 f64 比较 → ~2ms（Dart 原生）
- viewportData 从 ~2000 点（原 pyramid 输出）→ ~4000 点（像素列×2），绘制量仍可忽略
- 无 FFI 调用 → 零开销

## 执行顺序

1. 先写 `plot_painter.dart` 的 Min-Max 降采样逻辑（目标文件）
2. 改 `plot_screen.dart` `_refreshViewportData` 为简单的 Dart-only Min-Max 降采样，移除所有 pipeline/envelope/analog 分支
3. 改 `plot_screen.dart` 移除所有 pipeline/envelope/analog UI 控件和状态
4. 改 `plot_models.dart` 简化 DeviceContext
5. 删 Rust 文件 + 改 mod.rs
6. 修复 `plot_api.rs`、`debug_api.rs` 引用
7. `flutter_rust_bridge_codegen generate`
8. `flutter analyze` + `flutter build windows --release`
9. 删除 Dart FFI 绑定文件 `ffi_bridge.dart`
