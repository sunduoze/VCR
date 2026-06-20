# VCR High-Throughput Architecture Migration Plan

**Goal**: Apply architecture (B) to achieve 200K+ pts/sec throughput and stable 60fps rendering.
**Total Time**: ~24 hours across 6 phases.

---

## Phase 0: Environment Setup [P0] [~0.5h]

Task 0.1: Git backup branch creation — COMPLETED by user
Task 0.2: Flutter/Rust environment check (flutter --version, cargo --version)

---

## Phase 1: Isolate Data Pipeline Optimization [P0] [~4h]

**Core**: Replace Timer-based polling (100ms) with dedicated Isolate running 16ms dead loop. Latency reduction ~6x, CPU reduction ~20%, FPS stability +30%.

Task 1.1: Create lib/chart_isolate.dart
- Import dart:isolate and dart:typed_data
- Define Viewport class (xMin/xMax/yMin/yMax)
- Implement chartIsolateEntry function
- Set up dead loop with 16ms interval
- Implement coordinate transformation

Task 1.2: Modify lib/main.dart to launch Isolate
- Initialize ChartIsolate on startup
- Establish SendPort/ReceivePort communication
- Pass data notifier to ChartPainter

Task 1.3: Modify lib/screens/plot_screen.dart to remove Timer
- Remove Timer.periodic for data fetching
- Replace with Isolate message listener
- Receive Float32List vertex data for rendering

Task 1.4: Add Rust FFI functions for polling
- Add get_points() and set_viewport() to rust/src/api/plot_api.rs
- Run flutter_rust_bridge_codegen generate

---

## Phase 2: Lock-Free Ring Buffer [P0] [~3h]

**Core**: Replace current DataBuffer with LockFreeRingBuffer (12M points pre-allocated, cache-line aligned, no false sharing). Multi-core CPU utilization +30%.

Task 2.1: Implement LockFreeRingBuffer in Rust
- Pre-allocated 12M capacity
- Cache-line aligned (128 bytes padding)
- Atomic operations for producer/consumer
- Zero allocation during data flow

---

## Phase 3: Object Pool + Picture Cache [P1] [~2h]

**Core**: TypedDataPool for Float32List reuse + Picture record caching. GC jitter reduced ~50%, rendering perf +30%.

Task 3.1: Implement TypedDataPool<Float32List> in Dart
Task 3.2: Pre-render static elements (grid/axes) via Picture.record

---

## Phase 4: 4-Level Time Bucket Pyramid + LTTB [P1] [~3h]

**Core**: Pyramid data structure for sub-500us range queries + LTTB downsampling.

Task 4.1: Implement 4-level time bucket pyramid data structure
Task 4.2: Integrate LTTB algorithm for visual-preserving decimation

---

## Phase 5: dart:ffi Zero-Copy Bridge [P2] [~4h] *(optional, risky)*

**Core**: Replace flutter_rust_bridge auto-gen bindings with pure dart:ffi zero-copy memory sharing.

---

## Phase 6: wgpu GPU Render Optimization [P2] [~3h] *(optional)*

**Core**: Fine-tune wgpu rendering pipeline for maximum throughput.

---

**Next Action**: Execute Phase 1 immediately.