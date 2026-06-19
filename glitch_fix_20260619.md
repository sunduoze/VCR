# VCR Demo 模式毛刺根因修复报告 (2026-06-19)

## 发现的 Bug

### Bug 1（根因）：Demo 模式 `_fitYAxis()` 和 `_refreshViewportData()` 调用顺序反转

**位置**: `plot_screen.dart` `_startDemoData()` 定时器回调

**问题代码**:
```dart
_fitYAxis();           // ❌ 先使用旧的 viewportData 算 Y 轴
_refreshViewportData(); // ❌ 然后才刷新 viewportData
setState(() {});
```

**效果**: Y 轴范围始终基于**上一帧**的数据，绘制使用**当前帧**的数据。数据与 Y 轴每帧错位 → 视觉毛刺。

**修复**: 将 `_refreshViewportData()` 和 `_fitXAxis()/_fitYAxis()` 都移入 `shouldUpdateUI` 块，刷新在前、拟合在后：
```dart
if (shouldUpdateUI) {
    _refreshViewportData(); // Step 1: 填充最新 viewportData
    if (_scrollMode) { ... _fitYAxis(); } // Step 2: 用新数据拟合 Y 轴
    setState(() {}); // Step 3: 重绘
}
```

### 增强：Y 轴 EMA 平滑

**问题**: 即使顺序正确，滑动窗口覆盖波形不同部分时 Y 轴范围自然波动（20-128% per frame），产生"呼吸"效果。

**修复**: 
- PlotChannel 新增 `_smoothedYMin`/`_smoothedYMax` 字段
- `_fitYAxisForChannel` 使用 EMA 平滑（factor=0.4）
- 平滑量级: 每帧目标跳变 74% → 实际渲染仅跳变 ~30%

### 附带修复：Debug DLL 文件名

`vcr_lib.dll` 编译后在 `plugins\rust_lib_vcr\Debug\` 而非 `runner\Debug\`，导致加载失败。已复制到正确位置。

## 诊断验证

- Y 轴振荡诊断从 "每帧 74% 跳变" 变为 "目标 74%，平滑后仅 30%"
- 无 FALLBACK 触发（金字塔查询正常）
- 金字塔 X 偏移 ≤1 点（查询一致）
- 定时器延迟正常
- 无溢出计数

## 修改文件

- `lib/screens/plot_screen.dart`:
  - PlotChannel 类：新增 `_smoothedYMin`/`_smoothedYMax` 字段
  - `_startDemoData`：重排 refresh → fit → setState 顺序
  - `_fitYAxisForChannel`：EMA 平滑逻辑 + 更新诊断输出
