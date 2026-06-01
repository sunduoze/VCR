// FFI Bridge — Phase 5: dart:ffi zero-copy bindings for Chart Isolate
// Provides direct C-ABI calls to Rust without flutter_rust_bridge serialization.
//
// Usage from Chart Isolate:
//   final bridge = FfiBridge.instance;
//   bridge.pushPoint(ts, val);
//   final count = bridge.readIntoBuffer(buffer);

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ══════════════════════════════════════════════════════════════════════
// C-ABI Structs (must match Rust repr(C) layout exactly)
// ══════════════════════════════════════════════════════════════════════

/// Matches Rust: PointsBuffer { ptr: *const f32, len: u32, generation: u64 }
/// Zero-copy: use ptr.asTypedList(len*2) after each get_points() call.
final class PointsBuffer extends Struct {
  external Pointer<Float> ptr;

  @Uint32()
  external int len;

  @Uint64()
  external int generation;
}

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

// Ring buffer
typedef _PushNative = Bool Function(Double timestampMs, Double value);
typedef _PushDart = bool Function(double timestampMs, double value);
typedef _PushBatchNative = Bool Function(Pointer<CDataPoint> data, Uint32 count);
typedef _PushBatchDart = bool Function(Pointer<CDataPoint> data, int count);
typedef _AvailableNative = Uint32 Function();
typedef _AvailableDart = int Function();
typedef _ReadNative = Uint32 Function(Pointer<CDataPoint> out, Uint32 maxCount);
typedef _ReadDart = int Function(Pointer<CDataPoint> out, int maxCount);
typedef _ClearNative = Void Function();
typedef _ClearDart = void Function();

// Pyramid
// -- Query Bridge (Triple Buffer + PointsBuffer)
typedef _SetViewportNative = Void Function(Double tStart, Double tEnd, Uint32 maxPoints);
typedef _SetViewportDart = void Function(double tStart, double tEnd, int maxPoints);
typedef _GetPointsNative = PointsBuffer Function();
typedef _GetPointsDart = PointsBuffer Function();
typedef _GetGenerationNative = Uint64 Function();
typedef _GetGenerationDart = int Function();
typedef _GetLatestTimestampNative = Double Function();
typedef _GetLatestTimestampDart = double Function();
// -- Pyramid query
typedef _PyramidQueryNative = Uint32 Function(
    Double tMin, Double tMax, Uint32 targetPoints,
    Pointer<CBucketStats> out, Uint32 maxBuckets);
typedef _PyramidQueryDart = int Function(
    double tMin, double tMax, int targetPoints,
    Pointer<CBucketStats> out, int maxBuckets);
typedef _PyramidQueryPointsNative = Uint32 Function(
    Double tMin, Double tMax, Uint32 targetPoints,
    Pointer<CDataPoint> out, Uint32 maxPoints);
typedef _PyramidQueryPointsDart = int Function(
    double tMin, double tMax, int targetPoints,
    Pointer<CDataPoint> out, int maxPoints);
typedef _PyramidPushNative = Void Function(Double timestampMs, Double value);
typedef _PyramidPushDart = void Function(double timestampMs, double value);
typedef _PyramidPushBatchNative = Bool Function(Pointer<CDataPoint> data, Uint32 count);
typedef _PyramidPushBatchDart = bool Function(Pointer<CDataPoint> data, int count);

// ══════════════════════════════════════════════════════════════════════
// FFI Bridge Singleton
// ══════════════════════════════════════════════════════════════════════

class FfiBridge {
  static FfiBridge? _instance;
  late final DynamicLibrary _lib;

  // Bound functions
  late final _InitDart init;
  late final _IsReadyDart isReady;
  late final _ShutdownDart shutdown;

  late final _PushDart bufferPush;
  late final _PushBatchDart bufferPushBatch;
  late final _AvailableDart bufferAvailable;
  late final _ReadDart bufferRead;
  late final _ClearDart bufferClear;

  late final _PyramidQueryDart pyramidQuery;
  late final _PyramidQueryPointsDart pyramidQueryPoints;
  late final _PyramidPushDart pyramidPush;
  late final _PyramidPushBatchDart pyramidPushBatch;

  // Query bridge (zero-copy PointsBuffer)
  late final _SetViewportDart setViewport;
  late final _GetPointsDart getPoints;
  late final _GetGenerationDart getGeneration;
  late final _GetLatestTimestampDart getLatestTimestamp;

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
      // flutter_rust_bridge already loads vcr_lib.dll; this reuses it
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

    bufferPush = _lib.lookupFunction<_PushNative, _PushDart>('vcr_buffer_push');
    bufferPushBatch = _lib.lookupFunction<_PushBatchNative, _PushBatchDart>('vcr_buffer_push_batch');
    bufferAvailable = _lib.lookupFunction<_AvailableNative, _AvailableDart>('vcr_buffer_available');
    bufferRead = _lib.lookupFunction<_ReadNative, _ReadDart>('vcr_buffer_read');
    bufferClear = _lib.lookupFunction<_ClearNative, _ClearDart>('vcr_buffer_clear');

    pyramidQuery = _lib.lookupFunction<_PyramidQueryNative, _PyramidQueryDart>('vcr_pyramid_query');
    pyramidQueryPoints = _lib.lookupFunction<_PyramidQueryPointsNative, _PyramidQueryPointsDart>('vcr_pyramid_query_points');
    pyramidPush = _lib.lookupFunction<_PyramidPushNative, _PyramidPushDart>('vcr_pyramid_push');
    pyramidPushBatch = _lib.lookupFunction<_PyramidPushBatchNative, _PyramidPushBatchDart>('vcr_pyramid_push_batch');

    // Query bridge (zero-copy PointsBuffer)
    setViewport = _lib.lookupFunction<_SetViewportNative, _SetViewportDart>('vcr_set_viewport');
    getPoints = _lib.lookupFunction<_GetPointsNative, _GetPointsDart>('vcr_get_points');
    getGeneration = _lib.lookupFunction<_GetGenerationNative, _GetGenerationDart>('vcr_get_generation');
    getLatestTimestamp = _lib.lookupFunction<_GetLatestTimestampNative, _GetLatestTimestampDart>('vcr_get_latest_timestamp');
  }

  // ══════════════════════════════════════════════════════════════════
  // Convenience API
  // ══════════════════════════════════════════════════════════════════

  /// Push a single point
  bool pushPoint(double timestampMs, double value) {
    return bufferPush(timestampMs, value);
  }

  /// Push a list of (timestampMs, value) pairs (heap batch)
  bool pushPoints(List<(double, double)> points) {
    if (points.isEmpty) return false;

    final ptr = calloc<CDataPoint>(points.length);
    try {
      for (var i = 0; i < points.length; i++) {
        ptr[i]
          ..timestampMs = points[i].$1
          ..value = points[i].$2;
      }
      return bufferPushBatch(ptr, points.length);
    } finally {
      calloc.free(ptr);
    }
  }

  /// How many points are available in the ring buffer?
  int get availablePoints => bufferAvailable();

  /// Zero-copy read via PointsBuffer (primary hot path).
  /// Returns a Float32List backed by native memory — no allocation, no copy.
  /// The returned list is valid until the next getPoints() call.
  ///
  /// Format: interleaved [x0, y0, x1, y1, ...] in data coordinates.
  ({Float32List data, int generation}) readPointsBuffer() {
    final pb = getPoints();
    final data = pb.ptr.asTypedList(pb.len * 2);
    return (data: data, generation: pb.generation);
  }

  /// Read available data into pre-allocated Float64List [ts, val, ts, val, ...]
  /// Returns: number of POINTS read
  int readIntoBuffer(Float64List buffer) {
    final maxPoints = buffer.length ~/ 2;
    final nativePtr = calloc<CDataPoint>(maxPoints);
    try {
      final count = bufferRead(nativePtr, maxPoints);
      // Copy from native memory to Dart-managed buffer (memcpy-equivalent)
      for (var i = 0; i < count; i++) {
        final pt = nativePtr[i];
        buffer[i * 2] = pt.timestampMs;
        buffer[i * 2 + 1] = pt.value;
      }
      return count;
    } finally {
      calloc.free(nativePtr);
    }
  }

  /// Query pyramid into Float64List as [ts, val, ts, val, ...] pairs
  int queryPyramidIntoBuffer(
    double tMin,
    double tMax,
    int targetPoints,
    Float64List buffer,
  ) {
    final maxPoints = buffer.length ~/ 2;
    final nativePtr = calloc<CDataPoint>(maxPoints);
    try {
      final count = pyramidQueryPoints(tMin, tMax, targetPoints, nativePtr, maxPoints);
      for (var i = 0; i < count; i++) {
        final pt = nativePtr[i];
        buffer[i * 2] = pt.timestampMs;
        buffer[i * 2 + 1] = pt.value;
      }
      return count;
    } finally {
      calloc.free(nativePtr);
    }
  }

  /// Query pyramid into CBucketStats buffer
  int queryPyramidStats(
    double tMin,
    double tMax,
    int targetPoints,
    Pointer<CBucketStats> out,
    int maxBuckets,
  ) {
    return pyramidQuery(tMin, tMax, targetPoints, out, maxBuckets);
  }
}
