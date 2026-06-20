// chart_isolate.dart — REMOVED (dead code, superseded by Ticker rendering + pipeline)
// This file was part of Phase 7 experimental Isolate-based rendering.
// The chart isolate spawned an Isolate that called vcr_get_points() loop,
// but the rendered data was never consumed by CustomPainter.
// Replaced by: P0-2 Ticker vsync + _refreshViewportData → FFI_CH_PYRAMIDS query.
