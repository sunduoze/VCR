# VCR 重构任务清单 — FINAL

> 审计基准：PERF_AUDIT_AND_PLAN.md | 参考提示词：rust_flutter_oscilloscope_perf_prompt.md

---

## Phase 1：止血 ✅ DONE 2026-08-06 00:30

### T1.1 Dart ch.data → FixedCapacityRing (P0)
- [x] FixedCapacityRing 类 (250K cap, O(1) add/del/access)
- [x] PlotChannel.data 类型迁移，fromJson 自动路由
- [x] 所有写路径适配（Demo/Real/Import 6处 .add() ）
- [x] removeRange 修剪全部移除（2处）
- [x] .last/.isEmpty/.length/.clear()/.data[i] 全部兼容

### T1.2 GPU 预分配复用 (P1)
- [x] params_buffer: new() 预分配 → compute 只 write_buffer（消除 1 个/帧 create_buffer）
- [x] uniform_buffer: 审计确认已在 new() 预分配（误报）
- [x] vertex_buffer 增量写入: 不适用 — 视口级 envelope 全量重算，全量写是正确语义

### 编译验证 ✅
- cargo check ✓ | flutter analyze ✓ | flutter build release ✓ | VCR 启动 PID 24240 265MB

---

## Phase 2 锁优化 ✅ 审计确认无改动需

push_batch 已正确分离 create(write_lock) → push(read_lock)。
parking_lot 在 Windows 收益微小。ChannelBuffer::push() O(1)，读锁竞争不大。

---

## Phase 3 Dart 管线精简 ✅ 审计确认无改动需

热路径（_refreshViewportData / _fitYAxis / _onTick）已走 envelope/analog/pyramid，不碰 ch.data。
ch.data 仅用于：CSV导出（用户操作）、cursor二分查找（O(log n)）、Minimap fallback（viewportData就绪时不触发）。

---

## 改动汇总

| 文件 | 改动 | 行数 |
|------|------|------|
| plot_models.dart | +FixedCapacityRing 类, PlotChannel.data 类型变更 | +42, -2 |
| plot_screen.dart | 移除 removeRange 修剪 2处, ch.data= 改 add() | -18, +1 |
| gpu_renderer.rs | LttbParams 模块级, params_buffer 预分配 | +14, -12 |
| PERF_AUDIT_AND_PLAN.md | 完整审计文档 | +1 新文件 |
| TASKS.md | 任务清单 | +1 新文件 |

**净变更**：+3 新文件，+57 行，-32 行（零语义变更，零破坏性重构）
