// FFI Bridge — dart:ffi zero-copy bindings to Rust C-ABI
// 
// Active data path:
//   Serial → Rust pipeline::push_sample_batch_with_x → FFI_CH_PYRAMIDS → Ticker query → paint
//
// Bound symbols: per-channel pyramid + pipeline lifecycle + init/shutdown.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ══════════════════════════════════════════════════════════════════════
// C-ABI Structs (must match Rust repr(C) layout exactly)
// ══════════════════════════════════════════════════════════════════════

/// Matches Rust: CDataPoint { timestamp_ms: f64, value: f64 }
final class CDataPoint extends Struct {
  @Double()
  external double timestampMs;

  @Double()
  external double value;
}

/// Matches Rust: CBucketStats { timestamp_ms, min, max, avg, count, _pad }
final class CBucketStats extends Struct {
  @Double()
  external double timestampMs;

  @Double()
  external double minValue;

  @Double()
  external double maxValue;

  @Double()
  external double avgValue;

  @Uint32()
  external int count;

  @Uint32()
  external int pad;
}

// ══════════════════════════════════════════════════════════════════════
// Native Function Type Definitions
// ══════════════════════════════════════════════════════════════════════

// Init / lifecycle
typedef _InitNative = Bool Function();
typedef _InitDart = bool Function();
typedef _IsReadyNative = Bool Function();
typedef _IsReadyDart = bool Function();
typedef _ShutdownNative = Void Function();
typedef _ShutdownDart = void Function();

// Per-channel pyramid
typedef _PyramidChPushNative = Void Function(Uint32 channelId, Double timestampMs, Double value);
typedef _PyramidChPushDart = void Function(int channelId, double timestampMs, double value);
typedef _PyramidChPushBatchNative = Bool Function(Uint32 channelId, Pointer<CDataPoint> data, Uint32 count);
typedef _PyramidChPushBatchDart = bool Function(int channelId, Pointer<CDataPoint> data, int count);
typedef _PyramidChQueryNative = Uint32 Function(Uint32 channelId, Double tMin, Double tMax, Uint32 targetPoints, Pointer<CBucketStats> out, Uint32 maxBuckets);
typedef _PyramidChQueryDart = int Function(int channelId, double tMin, double tMax, int targetPoints, Pointer<CBucketStats> out, int maxBuckets);
typedef _PyramidChQueryPointsNative = Uint32 Function(Uint32 channelId, Double tMin, Double tMax, Uint32 targetPoints, Pointer<CDataPoint> out, Uint32 maxPoints);
typedef _PyramidChQueryPointsDart = int Function(int channelId, double tMin, double tMax, int targetPoints, Pointer<CDataPoint> out, int maxPoints);
typedef _PyramidChClearNative = Void Function(Uint32 channelId);
typedef _PyramidChClearDart = void Function(int channelId);
typedef _PyramidChClearAllNative = Void Function();
typedef _PyramidChClearAllDart = void Function();

// Pipeline control
typedef _PipelineStartNative = Bool Function();
typedef _PipelineStartDart = bool Function();
typedef _PipelineStopNative = Bool Function();
typedef _PipelineStopDart = bool Function();
typedef _PipelineResetNative = Void Function();
typedef _PipelineResetDart = void Function();

// Render envelope (pipeline pre-computation)
typedef _EnvelopeSetViewportNative = Void Function(Double tMin, Double tMax, Uint32 maxPoints);
typedef _EnvelopeSetViewportDart = void Function(double tMin, double tMax, int maxPoints);
typedef _EnvelopeGetChannelOffsetNative = Uint32 Function(Uint32 channelId);
typedef _EnvelopeGetChannelOffsetDart = int Function(int channelId);
typedef _EnvelopeGetChannelCountNative = Uint32 Function(Uint32 channelId);
typedef _EnvelopeGetChannelCountDart = int Function(int channelId);
typedef _EnvelopeGetDataPtrNative = Pointer<Double> Function();
typedef _EnvelopeGetDataPtrDart = Pointer<Double> Function();
typedef _EnvelopeGetGenerationNative = Uint64 Function();
typedef _EnvelopeGetGenerationDart = int Function();
typedef _EnvelopeGetNumChannelsNative = Uint32 Function();
typedef _EnvelopeGetNumChannelsDart = int Function();

class FfiBridge {
  static FfiBridge? _instance;
  late final DynamicLibrary _lib;

  // Lifecycle
  late final _InitDart init;
  late final _IsReadyDart isReady;
  late final _ShutdownDart shutdown;

  // Per-channel pyramid
  late final _PyramidChPushDart pyramidChPush;
  late final _PyramidChPushBatchDart pyramidChPushBatch;
  late final _PyramidChQueryDart pyramidChQuery;
  late final _PyramidChQueryPointsDart pyramidChQueryPoints;
  late final _PyramidChClearDart pyramidChClear;
  late final _PyramidChClearAllDart pyramidChClearAll;

  // Pipeline control
  late final _PipelineStartDart pipelineStart;
  late final _PipelineStopDart pipelineStop;
  late final _PipelineResetDart pipelineReset;

  // Render envelope (pipeline pre-computation)
  late final _EnvelopeSetViewportDart envelopeSetViewport;
  late final _EnvelopeGetChannelOffsetDart envelopeGetChannelOffset;
  late final _EnvelopeGetChannelCountDart envelopeGetChannelCount;
  late final _EnvelopeGetDataPtrDart envelopeGetDataPtr;
  late final _EnvelopeGetGenerationDart envelopeGetGeneration;
  late final _EnvelopeGetNumChannelsDart envelopeGetNumChannels;

  FfiBridge._() {
    _lib = _loadLibrary();
    _bindFunctions();
  }

  /// Singleton accessor
  static FfiBridge get instance {
    _instance ??= FfiBridge._();
    return _instance!;
  }

  // ── DLL loading ───────────────────────────────────────────────

  static DynamicLibrary _loadLibrary() {
    if (Platform.isWindows) {
      try {
        return DynamicLibrary.open('vcr_lib.dll');
      } catch (_) {
        return DynamicLibrary.open('rust_lib_vcr.dll');
      }
    } else if (Platform.isLinux) {
      return DynamicLibrary.open('libvcr_lib.so');
    } else if (Platform.isMacOS) {
      return DynamicLibrary.open('libvcr_lib.dylib');
    }
    throw UnsupportedError('FFI bridge not supported on this platform');
  }

  // ── Symbol binding ────────────────────────────────────────────

  void _bindFunctions() {
    init = _lib.lookupFunction<_InitNative, _InitDart>('vcr_ffi_init');
    isReady = _lib.lookupFunction<_IsReadyNative, _IsReadyDart>('vcr_ffi_is_ready');
    shutdown = _lib.lookupFunction<_ShutdownNative, _ShutdownDart>('vcr_ffi_shutdown');

    // Per-channel pyramid
    pyramidChPush = _lib.lookupFunction<_PyramidChPushNative, _PyramidChPushDart>('vcr_pyramid_ch_push');
    pyramidChPushBatch = _lib.lookupFunction<_PyramidChPushBatchNative, _PyramidChPushBatchDart>('vcr_pyramid_ch_push_batch');
    pyramidChQuery = _lib.lookupFunction<_PyramidChQueryNative, _PyramidChQueryDart>('vcr_pyramid_ch_query');
    pyramidChQueryPoints = _lib.lookupFunction<_PyramidChQueryPointsNative, _PyramidChQueryPointsDart>('vcr_pyramid_ch_query_points');
    pyramidChClear = _lib.lookupFunction<_PyramidChClearNative, _PyramidChClearDart>('vcr_pyramid_ch_clear');
    pyramidChClearAll = _lib.lookupFunction<_PyramidChClearAllNative, _PyramidChClearAllDart>('vcr_pyramid_ch_clear_all');

    // Pipeline control
    pipelineStart = _lib.lookupFunction<_PipelineStartNative, _PipelineStartDart>('vcr_pipeline_start');
    pipelineStop = _lib.lookupFunction<_PipelineStopNative, _PipelineStopDart>('vcr_pipeline_stop');
    pipelineReset = _lib.lookupFunction<_PipelineResetNative, _PipelineResetDart>('vcr_pipeline_reset');

    // Render envelope (pipeline pre-computation) — best-effort bind (graceful degrade if DLL lacks exports)
    try {
      envelopeSetViewport = _lib.lookupFunction<_EnvelopeSetViewportNative, _EnvelopeSetViewportDart>('vcr_envelope_set_viewport');
      envelopeGetChannelOffset = _lib.lookupFunction<_EnvelopeGetChannelOffsetNative, _EnvelopeGetChannelOffsetDart>('vcr_envelope_get_channel_offset');
      envelopeGetChannelCount = _lib.lookupFunction<_EnvelopeGetChannelCountNative, _EnvelopeGetChannelCountDart>('vcr_envelope_get_channel_count');
      envelopeGetDataPtr = _lib.lookupFunction<_EnvelopeGetDataPtrNative, _EnvelopeGetDataPtrDart>('vcr_envelope_get_data_ptr');
      envelopeGetGeneration = _lib.lookupFunction<_EnvelopeGetGenerationNative, _EnvelopeGetGenerationDart>('vcr_envelope_get_generation');
      envelopeGetNumChannels = _lib.lookupFunction<_EnvelopeGetNumChannelsNative, _EnvelopeGetNumChannelsDart>('vcr_envelope_get_num_channels');
    } catch (e) {
      print('[FfiBridge] Envelope bindings unavailable (DLL may be outdated), degrade gracefully: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // Convenience API — Per-Channel Pyramid
  // ══════════════════════════════════════════════════════════════════

  /// Push a batch of points into channel's pyramid.
  void pushChannelBatch(int channelId, List<(double, double)> points) {
    if (points.isEmpty) return;
    final ptr = calloc<CDataPoint>(points.length);
    try {
      for (var i = 0; i < points.length; i++) {
        ptr[i]
          ..timestampMs = points[i].$1
          ..value = points[i].$2;
      }
      pyramidChPushBatch(channelId, ptr, points.length);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Query channel pyramid into Float64List as [ts, val, ts, val, ...] pairs.
  /// Format: min+max interleaved per bucket — always even count.
  int queryChannelPoints(
    int channelId,
    double tMin,
    double tMax,
    int targetPoints,
    Float64List buffer,
  ) {
    final maxPoints = buffer.length ~/ 2;
    final nativePtr = calloc<CDataPoint>(maxPoints);
    try {
      return queryChannelPointsInto(channelId, tMin, tMax, targetPoints, nativePtr, maxPoints, buffer);
    } finally {
      calloc.free(nativePtr);
    }
  }

  /// Query per-channel pyramid with pre-allocated native buffer (zero alloc).
  int queryChannelPointsInto(
    int channelId,
    double tMin,
    double tMax,
    int targetPoints,
    Pointer<CDataPoint> nativeBuf,
    int maxPoints,
    Float64List buffer,
  ) {
    final count = pyramidChQueryPoints(channelId, tMin, tMax, targetPoints, nativeBuf, maxPoints);
    for (var i = 0; i < count; i++) {
      final pt = nativeBuf[i];
      buffer[i * 2] = pt.timestampMs;
      buffer[i * 2 + 1] = pt.value;
    }
    return count;
  }

  /// Clear a channel's pyramid (on device disconnect).
  void clearChannelPyramid(int channelId) {
    pyramidChClear(channelId);
  }

  /// Clear all per-channel pyramids.
  void clearAllChannelPyramids() {
    pyramidChClearAll();
  }

  // ── Pipeline Lifecycle ─────────────────────────────────────────

  /// Start the background data pipeline processing thread.
  bool startPipeline() => pipelineStart();

  /// Stop the background data pipeline processing thread.
  bool stopPipeline() => pipelineStop();

  /// Reset pipeline state (clear all pyramids and counters).
  void resetPipeline() => pipelineReset();
}
