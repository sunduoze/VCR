# VCR Phase A — Background Data Pipeline Implementation

**Date**: 2026-06-21 00:15 GMT+8
**Status**: Phase A implemented and deployed

## Objective
Implement Phase A of the reference-framework data pipeline to eliminate the Dart→Rust round-trip in the real-time plot data path.

## Architecture Change

### Before (current)
`
Serial → CsvParser → PLOT_DATA (Mutex) → frb serialization → Dart _fetchRealData
                                                              → bridge.pushChannelBatch() (Dart→Rust)
                                                              → FFI_CH_PYRAMIDS
                                                              → _refreshViewportData → queryChannelPointsInto()
`

### After (Phase A)
`
Serial → CsvParser → PLOT_DATA (Mutex, retained for backward compat)
                   → pipeline::push_sample_batch_with_x() (Rust→Rust, zero-copy)
                   → FFI_CH_PYRAMIDS (same Mutex, same pyramid)
Dart _fetchRealData → frb → populate ch.data (X = timestampMs, synced with pipeline)
Dart _refreshViewportData → queryChannelPointsInto() → zero-copy → CustomPainter
`

### Future (Phase B)
`
Serial → LockFreeRingBuffer → Pipeline thread → RenderEnvelope (pre-computed)
Dart Ticker → getRenderEnvelope() → zero-copy Float64List → CustomPainter
`

## Files Modified

### Rust
1. **
ust/src/core/plot/pipeline.rs** (NEW) — Background pipeline module
   - GLOBAL_SAMPLE_IDX: AtomicU64 shared sample counter
   - push_sample_batch_with_x(x, values): Push to FFI_CH_PYRAMIDS with explicit X
   - RENDER_ENVELOPE: Pre-computed render data struct (prepared for Phase B)
   - start/stop/reset_pipeline(): Lifecycle management
   - Pipeline thread (16ms loop, render envelope computation disabled for now)

2. **
ust/src/core/plot/mod.rs** — Added pub mod pipeline;

3. **
ust/src/core/plot/ffi_bridge.rs**
   - Made FFI_CH_PYRAMIDS pub for pipeline access
   - Added C-ABI exports: cr_pipeline_start/stop/push_batch/reset
   - Added render envelope read: cr_get_render_envelope
   - Added sample index getter: cr_get_sample_index

4. **
ust/src/api/debug_api.rs**
   - Import pipeline module
   - In spawn_receive_loop: After PLOT_DATA.push_batch_with_names(), call pipeline::push_sample_batch_with_x(counter, values) with the same X value
   - Added debug_start_pipeline() and debug_stop_pipeline() functions

### Dart
5. **lib/main.dart**
   - Import fi_bridge.dart
   - After RustLib.init(), call FfiBridge.instance.startPipeline()

6. **lib/core/ffi_bridge.dart**
   - Added pipeline control FFI bindings (start/stop/getRenderEnvelope)
   - Added startPipeline(), stopPipeline(), getRenderEnvelope() convenience methods

7. **lib/screens/plot_screen.dart**
   - **Full data initial load**: Use pts[i].timestampMs instead of i - totalPts + 1 for X values
   - **Delta data**: Use latestData[k].timestampMs instead of 
extX + k
   - **Removed**: Dart-side ridge.pushChannelBatch() calls (pipeline handles pyramid push)
   - **Kept**: 
emoveFromChannelPyramidOlderThan for pyramid trimming (uses synced X values)
   - **Kept**: Demo mode pyramid push unchanged (512, 562 lines)

## Key Decisions
1. **X-value sync**: Dart now uses Rust's 	imestampMs for ch.data.x values, matching the pipeline's pyramid X values. This ensures _refreshViewportData queries work correctly.
2. **Pipeline uses FFI_CH_PYRAMIDS**: Instead of creating a separate PIPELINE_PYRAMIDS map, the pipeline pushes directly to FFI_CH_PYRAMIDS (which Dart queries). Single source of truth.
3. **Render envelope deferred**: Pre-computed render envelope code is in place but disabled. Will activate in Phase B when Ticker replaces Timer.
4. **PLOT_DATA retained**: Kept for backward compatibility (channel discovery, historical data queries, Lua callback).

## Build Status
- cargo check: ✅ Clean
- lutter analyze: ✅ 0 errors, 10 warnings (8 pre-existing)
- cargo build --release: ✅ 8.45s
- lutter build windows --release: ✅ 42.2s
- DLL deployed to uild\windowsdunner\Releasecr_lib.dll
- App launched

## Remaining Work (Phase B)
1. Ticker-driven rendering (replace Timer.periodic with Ticker)
2. Render envelope pre-computation in pipeline thread
3. Zero-copy render envelope read path in Dart
4. Lock-free ring buffer integration (feed serial receive → FFI_RING → pipeline)
