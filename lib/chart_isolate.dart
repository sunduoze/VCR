// chart_isolate.dart - Dedicated Isolate for high-throughput data pipeline
// Phase 7: Zero-copy FFI integration via PointsBuffer
// Dead loop: 16ms cycle → FFI get_points() → coordinate transform → SendPort

import 'dart:isolate';
import 'dart:typed_data';

import 'core/ffi_bridge.dart';

/// Global SendPort for communicating with the Chart Isolate.
SendPort? chartIsolatePort;

/// ChartViewport definition - visible X/Y range in data coordinates.
class ChartViewport {
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;
  final double screenWidth;
  final double screenHeight;

  const ChartViewport({
    this.xMin = -1000.0,
    this.xMax = 0.0,
    this.yMin = -1.0,
    this.yMax = 1.0,
    this.screenWidth = 800.0,
    this.screenHeight = 600.0,
  });

  ChartViewport copyWith({
    double? xMin,
    double? xMax,
    double? yMin,
    double? yMax,
    double? screenWidth,
    double? screenHeight,
  }) {
    return ChartViewport(
      xMin: xMin ?? this.xMin,
      xMax: xMax ?? this.xMax,
      yMin: yMin ?? this.yMin,
      yMax: yMax ?? this.yMax,
      screenWidth: screenWidth ?? this.screenWidth,
      screenHeight: screenHeight ?? this.screenHeight,
    );
  }
}

/// Chart Isolate entry point.
///
/// Lifecycle:
/// 1. Initialize FFI bridge (DynamicLibrary loaded in Isolate context)
/// 2. Set initial viewport
/// 3. Async pipeline loop: get_points() → transform → send, yielding to event loop
/// 4. On 'shutdown': break loop
void chartIsolateEntry(SendPort sendPort) async {
  final receivePort = ReceivePort();
  sendPort.send(receivePort.sendPort);

  // Initialize FFI in this isolate context
  final bridge = FfiBridge.instance;
  bridge.init();

  // State
  var currentViewport = const ChartViewport();
  bool running = true;
  bool paused = false;

  // Pre-computed transform state (cache to avoid per-frame allocation)
  int lastGeneration = 0;

  receivePort.listen((message) {
    switch (message) {
      case 'shutdown':
        running = false;
        receivePort.close();
      case 'pause':
        paused = true;
      case 'resume':
        paused = false;
      default:
        if (message is ChartViewport) {
          currentViewport = message;
          bridge.setViewport(
            currentViewport.xMin,
            currentViewport.xMax,
            4096, // max points per frame
          );
        }
    }
  });

  // ── Main Pipeline Loop (async, yields to event loop) ──
  final sw = Stopwatch();
  while (running) {
    sw.reset();

    if (!paused) {
      // 1. Get zero-copy PointsBuffer from Rust
      final (:data, :generation) = bridge.readPointsBuffer();

      if (data.isNotEmpty) {
        // 2. Detect ring buffer overwrites
        final dataLost = (lastGeneration != 0 && generation != lastGeneration);
        lastGeneration = generation;

        // 3. Copy from native memory into owned buffer (prevents race)
        final owned = Float32List.fromList(data);

        // 4. Coordinate transform: data coords → screen pixels
        final transformed = transformCoordinates(
          owned,
          currentViewport,
        );

        // 5. Send to main isolate
        sendPort.send(_FrameData(
          vertices: transformed,
          generation: generation,
          dataLost: dataLost,
        ));
      }
    }

    // Yield to event loop for ~16ms (60fps), allowing message processing
    final elapsed = sw.elapsedMicroseconds;
    final remaining = 16000 - elapsed;
    if (remaining > 0) {
      await Future.delayed(Duration(microseconds: remaining));
    } else {
      await Future.delayed(Duration.zero); // yield to event loop even if over budget
    }
  }

  bridge.shutdown();
}

/// Frame data sent from Chart Isolate to Main Isolate.
class _FrameData {
  final Float32List vertices; // transformed screen coords [x,y,x,y,...]
  final int generation;
  final bool dataLost;

  const _FrameData({
    required this.vertices,
    required this.generation,
    this.dataLost = false,
  });
}

/// Coordinate transformation from data coords to screen pixels.
/// Returns a Float32List of [x0,y0, x1,y1, ...] in pixel coordinates.
Float32List transformCoordinates(
  Float32List dataPoints,
  ChartViewport viewport,
) {
  if (dataPoints.isEmpty ||
      viewport.screenWidth <= 0 ||
      viewport.screenHeight <= 0) {
    return Float32List(0);
  }

  final xRange = viewport.xMax - viewport.xMin;
  final yRange = viewport.yMax - viewport.yMin;

  if (xRange == 0 || yRange == 0) {
    return Float32List(0);
  }

  final pointCount = dataPoints.length ~/ 2;
  final result = Float32List(pointCount * 2);

  for (int i = 0; i < pointCount; i++) {
    final x = dataPoints[i * 2];
    final y = dataPoints[i * 2 + 1];

    result[i * 2] = ((x - viewport.xMin) / xRange) * viewport.screenWidth;
    result[i * 2 + 1] =
        viewport.screenHeight - ((y - viewport.yMin) / yRange) * viewport.screenHeight;
  }

  return result;
}

/// Spawns the Chart Isolate and returns its SendPort.
Future<SendPort> spawnChartIsolate() async {
  final receivePort = ReceivePort();
  await Isolate.spawn(chartIsolateEntry, receivePort.sendPort);
  final sendPort = await receivePort.first as SendPort;
  return sendPort;
}
