import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

/// Simple data point class (duplicated here to avoid part-of issues)
class IsolateDataPoint {
  final double x;
  final double y;
  IsolateDataPoint(this.x, this.y);
}

// ============================================================================
// P0: Data Isolate — Offload viewport decimation + Y-axis fitting to worker
// ============================================================================
// Expected gain: 5-10x by removing O(n) binary search + min/max scan from
// the main thread. The isolate receives raw channel data, computes viewport
// decimation (Min-Max per pixel column), and returns packed Float64List buffers.

/// Message sent from main thread to isolate
class IsolateRequest {
  final double xMin;
  final double xMax;
  final int screenWidth;
  final int qualityLevel; // 0=full, 1=reduced, 2=minimal
  final List<IsolateChannelData> channels;

  IsolateRequest({
    required this.xMin,
    required this.xMax,
    required this.screenWidth,
    required this.qualityLevel,
    required this.channels,
  });
}

/// Per-channel data sent to isolate using Float64List for zero-copy transfer
/// Layout: [x0, y0, x1, y1, x2, y2, ...] — interleaved (x, y) pairs
class IsolateChannelData {
  final int channelIndex;
  final bool visible;
  final Float64List data; // Interleaved (x, y) pairs, length = count * 2

  IsolateChannelData({
    required this.channelIndex,
    required this.visible,
    required this.data,
  });
}

/// Result returned from isolate per channel
class IsolateChannelResult {
  final int channelIndex;
  final Float64List viewportData; // Interleaved (x, y) pairs
  final Float64List envelopeData; // Interleaved (x, min) + (x, max) pairs
  final double yMin;
  final double yMax;
  final int rvdUs; // isolate processing time in microseconds

  IsolateChannelResult({
    required this.channelIndex,
    required this.viewportData,
    required this.envelopeData,
    required this.yMin,
    required this.yMax,
    this.rvdUs = 0,
  });
}

/// Complete result from isolate
class IsolateResponse {
  final List<IsolateChannelResult> channels;
  final int rvdUs; // Processing time in microseconds

  IsolateResponse({
    required this.channels,
    required this.rvdUs,
  });
}

/// Spawned isolate entry point
void _viewportIsolateEntry(SendPort sendPort) {
  final receivePort = ReceivePort();
  sendPort.send(receivePort.sendPort);

  receivePort.listen((message) {
    if (message is IsolateRequest) {
      final sw = Stopwatch()..start();
      final results = _processRequest(message);
      final response = IsolateResponse(
        channels: results,
        rvdUs: sw.elapsedMicroseconds,
      );
      sendPort.send(response);
    }
  });
}

List<IsolateChannelResult> _processRequest(IsolateRequest req) {
  final results = <IsolateChannelResult>[];

  // Determine target width based on quality level
  int targetW = req.screenWidth.clamp(1, 4096);
  switch (req.qualityLevel) {
    case 1: // reduced
      targetW = (targetW ~/ 2).clamp(500, 4096);
      break;
    case 2: // minimal
      targetW = (targetW ~/ 4).clamp(250, 4096);
      break;
  }

  for (final ch in req.channels) {
    if (!ch.visible || ch.data.isEmpty) {
      results.add(IsolateChannelResult(
        channelIndex: ch.channelIndex,
        viewportData: Float64List(0),
        envelopeData: Float64List(0),
        yMin: double.infinity,
        yMax: double.negativeInfinity,
      ));
      continue;
    }

    final total = ch.data.length ~/ 2; // Number of data points (Float64List has 2x elements: x,y pairs)
    final newestAbsX = ch.data[ch.data.length - 2]; // Last x in interleaved list (index length-2)
    final adjustedXMin = total < targetW
        ? (-total).toDouble().clamp(req.xMin, 0.0)
        : req.xMin;
    final viewMinAbs = newestAbsX + adjustedXMin;
    final viewMaxAbs = newestAbsX + req.xMax;

    // Binary search first index (search in x values at even indices)
    int lo = 0, hi = total;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (ch.data[mid * 2] < viewMinAbs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final firstIdx = lo;
    if (firstIdx >= total) {
      results.add(IsolateChannelResult(
        channelIndex: ch.channelIndex,
        viewportData: Float64List(0),
        envelopeData: Float64List(0),
        yMin: double.infinity,
        yMax: double.negativeInfinity,
      ));
      continue;
    }

    // Binary search last index
    lo = 0;
    hi = total;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (ch.data[mid * 2] <= viewMaxAbs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final lastIdx = lo - 1;
    if (lastIdx < firstIdx) {
      results.add(IsolateChannelResult(
        channelIndex: ch.channelIndex,
        viewportData: Float64List(0),
        envelopeData: Float64List(0),
        yMin: double.infinity,
        yMax: double.negativeInfinity,
      ));
      continue;
    }

    final visibleCount = lastIdx - firstIdx + 1;
    final step = (visibleCount / targetW).ceil().clamp(1, visibleCount);

    // Pre-allocate buffers: targetW columns × 2 values (x, y) for viewport
    // envelope: targetW × 4 values (x, min, x, max)
    final vpBuffer = Float64List(targetW * 2);
    final envBuffer = Float64List(targetW * 4);
    int vpCount = 0;
    int envCount = 0;

    double yMin = double.infinity;
    double yMax = double.negativeInfinity;

    for (int x = 0; x < targetW; x++) {
      final start = firstIdx + x * step;
      if (start > lastIdx) break;
      final end = (start + step).clamp(start, lastIdx + 1);

      // Access y values at odd indices (x*2+1)
      double curMin = ch.data[start * 2 + 1];
      double curMax = ch.data[start * 2 + 1];
      for (int i2 = start + 1; i2 < end; i2++) {
        final v = ch.data[i2 * 2 + 1];
        if (v < curMin) curMin = v;
        if (v > curMax) curMax = v;
      }

      if (curMin < yMin) yMin = curMin;
      if (curMax > yMax) yMax = curMax;

      final xRel = ch.data[(end - 1) * 2] - newestAbsX;

      // Viewport: mid point
      vpBuffer[vpCount++] = xRel;
      vpBuffer[vpCount++] = (curMin + curMax) * 0.5;

      // Envelope: min and max
      envBuffer[envCount++] = xRel;
      envBuffer[envCount++] = curMin;
      envBuffer[envCount++] = xRel;
      envBuffer[envCount++] = curMax;
    }

    // Trim to actual size
    final vpTrimmed = Float64List.sublistView(vpBuffer, 0, vpCount);
    final envTrimmed = Float64List.sublistView(envBuffer, 0, envCount);

    results.add(IsolateChannelResult(
      channelIndex: ch.channelIndex,
      viewportData: vpTrimmed,
      envelopeData: envTrimmed,
      yMin: yMin.isFinite ? yMin - (yMax - yMin) * 0.1 : double.infinity,
      yMax: yMax.isFinite ? yMax + (yMax - yMin) * 0.1 : double.negativeInfinity,
    ));
  }

  return results;
}

/// Manager for the viewport data isolate
class ViewportDataIsolate {
  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _sendPort;
  Completer<IsolateResponse>? _pending;

  bool get isRunning => _isolate != null;

  Future<void> start() async {
    if (_isolate != null) return;

    final receivePort = ReceivePort();
    _receivePort = receivePort;

    final completer = Completer<SendPort>();
    receivePort.listen((message) {
      if (message is SendPort && !completer.isCompleted) {
        completer.complete(message);
      } else if (message is IsolateResponse && _pending != null) {
        _pending!.complete(message);
        _pending = null;
      }
    });

    _isolate = await Isolate.spawn(
      _viewportIsolateEntry,
      receivePort.sendPort,
      debugName: 'ViewportDataIsolate',
    );

    _sendPort = await completer.future;
  }

  Future<IsolateResponse> process(IsolateRequest request) async {
    if (_sendPort == null) await start();
    if (_pending != null) {
      // Cancel previous request if still pending (shouldn't happen with proper flow)
      _pending = null;
    }

    _pending = Completer<IsolateResponse>();
    _sendPort!.send(request);
    return _pending!.future;
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;
    _pending = null;
  }
}
