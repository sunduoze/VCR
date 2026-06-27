// Plot data models — part of plot_screen.dart
part of 'plot_screen.dart';

enum LineStyle { dot, dotLine, line, filled }

extension LineStyleLabel on LineStyle {
  String get label {
    switch (this) {
      case LineStyle.dot: return 'Dot';
      case LineStyle.dotLine: return 'Dot-Line';
      case LineStyle.line: return 'Line';
      case LineStyle.filled: return 'Filled';
    }
  }
}

enum AntiAliasingLevel { off, x2, x4, x8 }

extension AALevelLabel on AntiAliasingLevel {
  String get label {
    switch (this) {
      case AntiAliasingLevel.off: return 'Off';
      case AntiAliasingLevel.x2: return '2×';
      case AntiAliasingLevel.x4: return '4×';
      case AntiAliasingLevel.x8: return '8×';
    }
  }

  double get scale {
    switch (this) {
      case AntiAliasingLevel.off: return 1.0;
      case AntiAliasingLevel.x2: return 2.0;
      case AntiAliasingLevel.x4: return 4.0;
      case AntiAliasingLevel.x8: return 8.0;
    }
  }

  int get rasterizerTraces {
    switch (this) {
      case AntiAliasingLevel.off: return 0;
      case AntiAliasingLevel.x2: return 1;
      case AntiAliasingLevel.x4: return 2;
      case AntiAliasingLevel.x8: return 3;
    }
  }
}

/// A Plot Group — a vertical slice of the plot area with its own Y-axis.
/// Channels assigned to the same group share the same plot area.
class PlotGroup {
  String id;
  String name;
  double heightRatio; // relative height ratio (default 1.0)
  bool syncXAxis; // when true, X-axis is synced with other groups

  PlotGroup({
    required this.id,
    required this.name,
    this.heightRatio = 1.0,
    this.syncXAxis = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'heightRatio': heightRatio,
    'syncXAxis': syncXAxis,
  };

  factory PlotGroup.fromJson(Map<String, dynamic> json) => PlotGroup(
    id: json['id'] as String? ?? 'default',
    name: json['name'] as String? ?? 'Default',
    heightRatio: (json['heightRatio'] as num?)?.toDouble() ?? 1.0,
    syncXAxis: json['syncXAxis'] as bool? ?? true,
  );
}

/// Threshold for envelope vs trace rendering mode.
/// samplesPerPixel < ENVELOPE_THRESHOLD -> trace mode (raw polyline)
/// samplesPerPixel >= ENVELOPE_THRESHOLD -> envelope mode (min-max band)
const double ENVELOPE_THRESHOLD = 2.0;

class PlotChannel {
  final String deviceId;
  String deviceName;
  String channelName;
  Color color;
  bool visible;
  int decimals;
  bool showYAxis;
  LineStyle lineStyle;
  double lineWidth;
  List<_DataPoint> data; // Full data (for scale/cursor) — keeps _DataPoint (not on hot path)
  _DataBuf viewportData; // P0-2: GC-free Float64List for avg line painting
  _DataBuf envelopeData; // P0-2: GC-free Float64List for min-max fill
  double currentValue;
  double yMin; // Per-channel Y range
  double yMax;
  double yMinManual; // User-specified Y range (if not auto)
  double yMaxManual;
  bool autoScaleY; // Per-channel auto-scale
  String plotGroupId; // Which PlotGroup this channel belongs to
  double? _smoothedYMin; // DIAG: EMA-smoothed Y-axis range for glitch-free rendering
  double? _smoothedYMax;

  PlotChannel({
    required this.deviceId,
    required this.deviceName,
    required this.channelName,
    this.color = AppTheme.primary,
    this.visible = true,
    this.decimals = 3,
    this.showYAxis = true,
    this.lineStyle = LineStyle.line,
    this.lineWidth = 1.5,
    List<_DataPoint>? data,
    this.currentValue = 0.0,
    this.yMin = 0,
    this.yMax = 1,
    this.yMinManual = -1,
    this.yMaxManual = 1,
    this.autoScaleY = true,
    this.plotGroupId = 'default',
  }) : data = data ?? [],
       viewportData = _DataBuf(),
       envelopeData = _DataBuf();

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'channelName': channelName,
    'visible': visible,
    'decimals': decimals,
    'showYAxis': showYAxis,
    'lineStyle': lineStyle.name,
    'lineWidth': lineWidth,
    'autoScaleY': autoScaleY,
    'yMinManual': yMinManual,
    'yMaxManual': yMaxManual,
    'plotGroupId': plotGroupId,
    'color': color.toARGB32(),
  };

  factory PlotChannel.fromJson(Map<String, dynamic> json) => PlotChannel(
    deviceId: json['deviceId'] as String? ?? '',
    deviceName: json['deviceName'] as String? ?? '',
    channelName: json['channelName'] as String? ?? '',
    visible: json['visible'] as bool? ?? true,
    decimals: json['decimals'] as int? ?? 3,
    showYAxis: json['showYAxis'] as bool? ?? true,
    lineStyle: LineStyle.values.firstWhere(
      (e) => e.name == json['lineStyle'], orElse: () => LineStyle.line),
    lineWidth: (json['lineWidth'] as num?)?.toDouble() ?? 1.5,
    autoScaleY: json['autoScaleY'] as bool? ?? true,
    yMinManual: (json['yMinManual'] as num?)?.toDouble() ?? -1,
    yMaxManual: (json['yMaxManual'] as num?)?.toDouble() ?? 1,
    plotGroupId: json['plotGroupId'] as String? ?? 'default',
  )..color = json['color'] is int
      ? Color(json['color'] as int)
      : AppTheme.primary;
}

class _DataPoint {
  final double x;
  final double y;
  _DataPoint(this.x, this.y);
}

/// P0-2: GC-free data buffer for viewport/envelope rendering.
/// Stores interleaved (x,y) f64 pairs in a pre-allocated Float64List.
/// Zero heap allocation after initial alloc — eliminates per-frame _DataPoint churn.
class _DataBuf {
  Float64List _buf;
  int _len = 0;

  _DataBuf([int initialCapacity = 4096])
      : _buf = Float64List(initialCapacity * 2);

  int get length => _len;
  bool get isNotEmpty => _len > 0;
  bool get isEmpty => _len == 0;

  double x(int i) {
    assert(i >= 0 && i < _len, '_DataBuf.x($i) out of bounds [0, $_len)');
    return _buf[i * 2];
  }
  double y(int i) {
    assert(i >= 0 && i < _len, '_DataBuf.y($i) out of bounds [0, $_len)');
    return _buf[i * 2 + 1];
  }

  double get firstX => _len > 0 ? _buf[0] : 0;
  double get firstY => _len > 0 ? _buf[1] : 0;
  double get midX => _len > 0 ? _buf[(_len ~/ 2) * 2] : 0;
  double get midY => _len > 0 ? _buf[(_len ~/ 2) * 2 + 1] : 0;
  double get lastX => _len > 0 ? _buf[(_len - 1) * 2] : 0;
  double get lastY => _len > 0 ? _buf[(_len - 1) * 2 + 1] : 0;

  void add(double x, double y) {
    final idx = _len * 2;
    if (idx + 1 >= _buf.length) {
      // Geometric growth with amortized O(1): each resize doubles capacity.
      // For real-time rendering, prefer pre-sizing via the constructor.
      final newBuf = Float64List(_buf.length * 2);
      newBuf.setAll(0, _buf);
      _buf = newBuf;
    }
    _buf[idx] = x;
    _buf[idx + 1] = y;
    _len++;
  }

  void clear() => _len = 0;

  /// Create from raw f32 trace values (each value = one sample, y only).
  /// x values are sequential starting from startSample.
  /// Direct write — avoids add() resize loop for known-size batches.
  factory _DataBuf.fromTrace(List<double> values, int startSample) {
    final n = values.length;
    final buf = Float64List(n * 2);
    for (int i = 0; i < n; i++) {
      buf[i * 2] = startSample + i.toDouble();
      buf[i * 2 + 1] = values[i];
    }
    final result = _DataBuf._fromBuffer(buf, n);
    return result;
  }

  _DataBuf._fromBuffer(this._buf, this._len);

  /// Copy of the underlying data buffer (safe — caller cannot mutate internal state).
  Float64List get rawBuf => Float64List.fromList(_buf.sublist(0, _len * 2));
}

/// Scrollbar drag mode
enum _ScrollbarDrag { none, thumb, leftEdge, rightEdge }

/// Min visible X range (prevents zooming to zero)
// ignore: unused_element
const _minVisibleRange = 0.01;

class PlotScreen extends StatefulWidget {
  const PlotScreen({super.key});

  @override
  State<PlotScreen> createState() => _PlotScreenState();
}

// Render mode: auto (threshold-based), trace (always raw polyline), envelope (always min-max band)
enum _RenderMode { auto, trace, envelope }
