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

/// Matches Rust: EnvelopeSample { min: f32, max: f32 }
final class CEnvelopeSample extends Struct {
  @Float()
  external double min;

  @Float()
  external double max;
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

// AnalogSegment API
typedef _AnalogEnsureNative = Bool Function(Uint32 channelId);
typedef _AnalogEnsureDart = bool Function(int channelId);
typedef _AnalogPushSampleNative = Void Function(Uint32 channelId, Float value);
typedef _AnalogPushSampleDart = void Function(int channelId, double value);
typedef _AnalogSampleCountNative = Uint64 Function(Uint32 channelId);
typedef _AnalogSampleCountDart = int Function(int channelId);
typedef _AnalogGetMinMaxNative = Void Function(Uint32 channelId, Pointer<Float> out);
typedef _AnalogGetMinMaxDart = void Function(int channelId, Pointer<Float> out);
typedef _AnalogGetEnvelopeNative = Uint32 Function(Uint32 channelId, Uint64 startSample, Uint64 endSample, Float samplesPerPixel, Pointer<CEnvelopeSample> out, Uint32 maxSamples);
typedef _AnalogGetEnvelopeDart = int Function(int channelId, int startSample, int endSample, double samplesPerPixel, Pointer<CEnvelopeSample> out, int maxSamples);
// AnalogSegment trace query
typedef _AnalogGetTraceNative = Uint32 Function(Uint32 channelId, Uint64 start, Uint64 end, Pointer<Float> out, Uint32 maxSamples);
typedef _AnalogGetTraceDart = int Function(int channelId, int start, int end, Pointer<Float> out, int maxSamples);
// AnalogSegment samplerate
typedef _AnalogSetSamplerateNative = Void Function(Uint32 channelId, Double rate);
typedef _AnalogSetSamplerateDart = void Function(int channelId, double rate);
typedef _AnalogGetSamplerateNative = Double Function(Uint32 channelId);
typedef _AnalogGetSamplerateDart = double Function(int channelId);
typedef _AnalogSetLevelCountNative = Void Function(Uint32 levelCount);
typedef _AnalogSetLevelCountDart = void Function(int levelCount);
typedef _AnalogGetLevelCountNative = Uint32 Function();
typedef _AnalogGetLevelCountDart = int Function();
typedef _AnalogResetNative = Void Function(Uint32 channelId);
typedef _AnalogResetDart = void Function(int channelId);
typedef _AnalogResetAllNative = Void Function();
typedef _AnalogResetAllDart = void Function();
typedef _AnalogSetEnvelopeEnabledNative = Void Function(Bool enabled);
typedef _AnalogSetEnvelopeEnabledDart = void Function(bool enabled);
typedef _AnalogIsEnvelopeEnabledNative = Bool Function();
typedef _AnalogIsEnvelopeEnabledDart = bool Function();
typedef _AnalogDumpDebugNative = Uint32 Function(Uint32 channelId, Pointer<Uint8> buf, Uint32 bufLen);
typedef _AnalogDumpDebugDart = int Function(int channelId, Pointer<Uint8> buf, int bufLen);

// Pipeline control
typedef _PipelineStartNative = Bool Function();
typedef _PipelineStartDart = bool Function();
typedef _PipelineStopNative = Bool Function();
typedef _PipelineStopDart = bool Function();
typedef _PipelineResetNative = Void Function();
typedef _PipelineResetDart = void Function();
typedef _PipelineCheckDataReadyNative = Bool Function();
typedef _PipelineCheckDataReadyDart = bool Function();

// Render envelope (pipeline pre-computation)
typedef _EnvelopeSetViewportNative = Void Function(Double tMin, Double tMax, Uint32 maxPoints);
typedef _EnvelopeSetViewportDart = void Function(double tMin, double tMax, int maxPoints);
typedef _EnvelopeGetChannelOffsetNative = Uint32 Function(Uint32 channelId);
typedef _EnvelopeGetChannelOffsetDart = int Function(int channelId);
typedef _EnvelopeGetChannelCountNative = Uint32 Function(Uint32 channelId);
typedef _EnvelopeGetChannelCountDart = int Function(int channelId);
typedef _EnvelopeGetDataPtrNative = Pointer<Double> Function();
typedef _EnvelopeGetDataPtrDart = Pointer<Double> Function();
typedef _EnvelopeGetTotalSizeNative = Uint32 Function();
typedef _EnvelopeGetTotalSizeDart = int Function();
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

  // AnalogSegment API
  late final _AnalogEnsureDart analogEnsure;
  late final _AnalogPushSampleDart analogPushSample;
  late final _AnalogSampleCountDart analogSampleCount;
  late final _AnalogGetMinMaxDart analogGetMinMax;
  late final _AnalogGetEnvelopeDart analogGetEnvelope;
  late final _AnalogGetTraceDart analogGetTrace;
  late final _AnalogSetSamplerateDart analogSetSamplerate;
  late final _AnalogGetSamplerateDart analogGetSamplerate;
  late final _AnalogSetLevelCountDart analogSetLevelCountRaw;
  late final _AnalogGetLevelCountDart analogGetLevelCountRaw;
  late final _AnalogResetDart analogReset;
  late final _AnalogResetAllDart analogResetAll;
  late final _AnalogSetEnvelopeEnabledDart analogSetEnvelopeEnabled;
  late final _AnalogIsEnvelopeEnabledDart analogIsEnvelopeEnabled;
  late final _AnalogDumpDebugDart analogDumpDebugRaw;

  // Pipeline control
  late final _PipelineStartDart pipelineStart;
  late final _PipelineStopDart pipelineStop;
  late final _PipelineResetDart pipelineReset;
  late final _PipelineCheckDataReadyDart checkDataReady;

  // Render envelope (pipeline pre-computation)
  late final _EnvelopeSetViewportDart envelopeSetViewport;
  late final _EnvelopeGetChannelOffsetDart envelopeGetChannelOffset;
  late final _EnvelopeGetChannelCountDart envelopeGetChannelCount;
  late final _EnvelopeGetDataPtrDart envelopeGetDataPtr;
  late final _EnvelopeGetTotalSizeDart envelopeGetTotalSize;
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

    // AnalogSegment API — best-effort bind (graceful degrade if DLL lacks exports)
    try {
      analogEnsure = _lib.lookupFunction<_AnalogEnsureNative, _AnalogEnsureDart>('vcr_analog_ensure');
      analogPushSample = _lib.lookupFunction<_AnalogPushSampleNative, _AnalogPushSampleDart>('vcr_analog_push_sample');
      analogSampleCount = _lib.lookupFunction<_AnalogSampleCountNative, _AnalogSampleCountDart>('vcr_analog_sample_count');
      analogGetMinMax = _lib.lookupFunction<_AnalogGetMinMaxNative, _AnalogGetMinMaxDart>('vcr_analog_get_min_max');
      analogGetEnvelope = _lib.lookupFunction<_AnalogGetEnvelopeNative, _AnalogGetEnvelopeDart>('vcr_analog_get_envelope');
      analogGetTrace = _lib.lookupFunction<_AnalogGetTraceNative, _AnalogGetTraceDart>('vcr_analog_get_trace');
      analogSetSamplerate = _lib.lookupFunction<_AnalogSetSamplerateNative, _AnalogSetSamplerateDart>('vcr_analog_set_samplerate');
      analogGetSamplerate = _lib.lookupFunction<_AnalogGetSamplerateNative, _AnalogGetSamplerateDart>('vcr_analog_get_samplerate');
      analogSetLevelCountRaw = _lib.lookupFunction<_AnalogSetLevelCountNative, _AnalogSetLevelCountDart>('vcr_analog_set_level_count');
      analogGetLevelCountRaw = _lib.lookupFunction<_AnalogGetLevelCountNative, _AnalogGetLevelCountDart>('vcr_analog_get_level_count');
      analogReset = _lib.lookupFunction<_AnalogResetNative, _AnalogResetDart>('vcr_analog_reset');
      analogResetAll = _lib.lookupFunction<_AnalogResetAllNative, _AnalogResetAllDart>('vcr_analog_reset_all');
      analogSetEnvelopeEnabled = _lib.lookupFunction<_AnalogSetEnvelopeEnabledNative, _AnalogSetEnvelopeEnabledDart>('vcr_analog_set_envelope_enabled');
      analogIsEnvelopeEnabled = _lib.lookupFunction<_AnalogIsEnvelopeEnabledNative, _AnalogIsEnvelopeEnabledDart>('vcr_analog_is_envelope_enabled');
      analogDumpDebugRaw = _lib.lookupFunction<_AnalogDumpDebugNative, _AnalogDumpDebugDart>('vcr_analog_dump_debug');
    } catch (e) {
      print('[FfiBridge] AnalogSegment bindings unavailable (DLL may be outdated), degrade gracefully: $e');
    }

    // Pipeline control
    pipelineStart = _lib.lookupFunction<_PipelineStartNative, _PipelineStartDart>('vcr_pipeline_start');
    pipelineStop = _lib.lookupFunction<_PipelineStopNative, _PipelineStopDart>('vcr_pipeline_stop');
    pipelineReset = _lib.lookupFunction<_PipelineResetNative, _PipelineResetDart>('vcr_pipeline_reset');
    try {
      checkDataReady = _lib.lookupFunction<_PipelineCheckDataReadyNative, _PipelineCheckDataReadyDart>('vcr_pipeline_check_data_ready');
    } catch (e) {
      print('[FfiBridge] checkDataReady binding unavailable, degrade gracefully');
    }

    // Render envelope (pipeline pre-computation) — best-effort bind (graceful degrade if DLL lacks exports)
    try {
      envelopeSetViewport = _lib.lookupFunction<_EnvelopeSetViewportNative, _EnvelopeSetViewportDart>('vcr_envelope_set_viewport');
      envelopeGetChannelOffset = _lib.lookupFunction<_EnvelopeGetChannelOffsetNative, _EnvelopeGetChannelOffsetDart>('vcr_envelope_get_channel_offset');
      envelopeGetChannelCount = _lib.lookupFunction<_EnvelopeGetChannelCountNative, _EnvelopeGetChannelCountDart>('vcr_envelope_get_channel_count');
      envelopeGetDataPtr = _lib.lookupFunction<_EnvelopeGetDataPtrNative, _EnvelopeGetDataPtrDart>('vcr_envelope_get_data_ptr');
      envelopeGetTotalSize = _lib.lookupFunction<_EnvelopeGetTotalSizeNative, _EnvelopeGetTotalSizeDart>('vcr_envelope_get_total_size');
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

  /// Dump AnalogSegment debug info for a channel as a String.
  String analogDumpDebug(int channelId) {
    final buf = calloc<Uint8>(8192);
    try {
      final len = analogDumpDebugRaw(channelId, buf, 8192);
      if (len == 0) return 'Channel $channelId: no data';
      return String.fromCharCodes(buf.asTypedList(len));
    } finally {
      calloc.free(buf);
    }
  }

  // ── Configurable AnalogSegment Pyramid Levels ───────────────────

  /// Get the current default pyramid level count (3-10).
  int get analogLevelCount => analogGetLevelCountRaw();

  /// Set the default pyramid level count for newly created AnalogSegments.
  /// Valid range: 3-10. Existing segments must be cleared and recreated.
  set analogLevelCount(int v) => analogSetLevelCountRaw(v);
}
