import 'dart:math';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:ffi' hide Size; // 🚀 Phase C: Pointer for native buffer reuse (hide Size to avoid dart:ui conflict)
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart';
import 'package:file_picker/file_picker.dart';
import '../app/theme.dart';
import '../src/rust/api/device_api.dart';
import '../src/rust/api/debug_api.dart';
import '../src/rust/api/plot_api.dart';
import '../src/rust/frb_generated.dart';
import '../core/ffi_bridge.dart';
import 'package:ffi/ffi.dart' show calloc;

// ============================================================================
// Plot Screen — Oscilloscope-style waveform viewer
// ============================================================================

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

/// Feature flag: enable AnalogSegment envelope reads (parallel to TimeBucketPyramid).
/// When true, reads envelope from AnalogSegment; when false, uses existing RENDER_ENVELOPE.
const bool USE_ANALOG_ENVELOPE = true;

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
  double? _smoothedYMin; // 🩺 EMA-smoothed Y-axis range for glitch-free rendering
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

  double x(int i) => _buf[i * 2];
  double y(int i) => _buf[i * 2 + 1];

  double get firstX => _len > 0 ? _buf[0] : 0;
  double get firstY => _len > 0 ? _buf[1] : 0;
  double get midX => _len > 0 ? _buf[(_len ~/ 2) * 2] : 0;
  double get midY => _len > 0 ? _buf[(_len ~/ 2) * 2 + 1] : 0;
  double get lastX => _len > 0 ? _buf[(_len - 1) * 2] : 0;
  double get lastY => _len > 0 ? _buf[(_len - 1) * 2 + 1] : 0;

  void add(double x, double y) {
    final idx = _len * 2;
    if (idx + 1 >= _buf.length) {
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
  factory _DataBuf.fromTrace(List<double> values, int startSample) {
    final buf = _DataBuf(values.length);
    for (int i = 0; i < values.length; i++) {
      buf.add(startSample + i.toDouble(), values[i]);
    }
    return buf;
  }

  Float64List get rawBuf => _buf;
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

class _PlotScreenState extends State<PlotScreen> with SingleTickerProviderStateMixin {
  // ── Data source ──
  bool _useRealData = false; // false = demo, true = real device
  Timer? _realDataTimer; // 🚀 单定时器：合并 data fetch + UI update，消除竞态
  
  // ── Plot Groups ──
  List<PlotGroup> _plotGroups = [
    PlotGroup(id: 'default', name: 'Default'),
  ];

  // ── Data ──
  List<PlotChannel> _demoChannels = [];
  List<PlotChannel> _realChannels = [];
  /// Active channel list based on current mode
  List<PlotChannel> get _channels => _useRealData ? _realChannels : _demoChannels;
  set _channels(List<PlotChannel> value) {
    if (_useRealData) { _realChannels = value; } else { _demoChannels = value; }
  }
  int _maxPoints = 250000;  // Configurable max points (default 250000, range 1000-500000)
  double _deltaTime = 1.0;  // Time per sample in ms (default 1ms, connects sample index to time)

  // ── Axis config ──
  bool _autoScaleX = true;
  bool _autoScaleY = true; // Global Y auto-scale (fallback)
  double _xMin = -1000;
  double _xMax = 0;
  double _yMin = -1; // Global Y range (used when no per-channel axis)
  double _yMax = 1;
  int _globalDecimals = 3; // Global decimal precision for axes

  // ── Scroll (oscilloscope) mode ──
  bool _scrollMode = false;         // true = oscilloscope sweep mode
  double _scrollWindowWidth = 0.0;  // visible X range in samples; 0 means auto (= _maxPoints)
  double get _effectiveScrollWindowWidth => _scrollWindowWidth > 0 ? _scrollWindowWidth : _maxPoints.toDouble();
  double _scrollMinTime = 0.0;       // left edge of visible window
  double _screenWidth = 800.0;       // plot area width for ChartViewport decimation

  // ── Scrollbar drag state ──
  _ScrollbarDrag _scrollbarDrag = _ScrollbarDrag.none;
  double _scrollbarDragStartX = 0;
  double _scrollbarDragStartXMin = 0;
  double _scrollbarDragStartXMax = 10;

  // ── Protocol parser ──
  bool _autoAddChannels = true; // Auto-add channels from received data

  // ── Display state ──
  bool _isPlaying = true;

  // Render mode: auto (threshold-based), trace (always raw polyline), envelope (always min-max band)
  _RenderMode _renderMode = _RenderMode.auto;
  String _pyramidDebugText = '';
  int _fps = 0;
  int _totalPoints = 0;
  DateTime _lastFpsTime = DateTime.now();
  int _fpsFrameCount = 0;

  // ── GPU state ──
  bool _gpuInitialized = false;
  bool _useGpuAcceleration = true;
  ui.Image? _gpuWaveformImage;
  bool _isGpuRendering = false;

  // 🚀 P2-B 优化：增量更新版本号
  // ignore: unused_field
  BigInt _lastDataVersion = BigInt.zero;

  // 🚀 P3-B 优化：ChartViewport 刷新计数器（用于 shouldRepaint 优化）
  int _viewportRefreshCount = 0;

  // 🩺 Diagnostic: set true to enable verbose per-frame logging (DISABLE for production)
  static const bool _verbose = false;
  int _frameCount = 0;

  // 🚀 Phase C: Reusable query buffers (allocated once, resized lazily)
  Float64List? _queryBuffer;        // Reusable Float64List for _refreshViewportData
  Pointer<CDataPoint>? _queryNative; // Reusable native buffer for FFI queries
  int _queryNativeCap = 0;           // Current native buffer capacity (in CDataPoint elements)

  // ── Interaction state ──
  Offset? _mousePosition;
  bool _isDragging = false;
  Offset? _dragStart;
  double _dragStartXMin = 0;
  double _dragStartXMax = 10;
  double _dragStartYMin = -1;
  double _dragStartYMax = 1;
  // Drag state for scroll-mode ChartViewport (X-axis only drag in scroll mode)
  double _dragStartScrollMin = 0.0;

  // ── Numeric panel ──
  double _panelWidth = 220.0;

  // ── Max points controller ──
  final _maxPointsController = TextEditingController();
  final _deltaTimeController = TextEditingController();  // Time per sample in ms

  // ── Y axis share ──
  bool _shareYAxis = false; // Each channel uses its own Y range

  // ── Per-group Y ranges (for multi-group mode) ──
  Map<String, double> _groupYMin = {};
  Map<String, double> _groupYMax = {};

  // ── Anti-aliasing ──
  AntiAliasingLevel _aaLevel = AntiAliasingLevel.off;

  // ── Animation ──
  late Ticker _ticker;
  bool _tickBusy = false; // P0-2: frame budget guard — skip tick if previous frame still rendering
  int _lastVpGen = -1; // Idle skip: track last viewport generation to skip expensive refresh when idle

  // ── Demo ──
  double _demoPhase = 0;  // Demo phase for waveform generation (time in seconds)
  int _sampleIndex = 0;  // Sample index counter for X-axis (displayed as index * deltaTime)
  bool _plotThemeDark = true;  // dark (true) / light (false)
  Timer? _demoTimer;

  // ── Channel colors pool (oscilloscope-grade, 16 perceptually distinct hues) ──
  // Span the full hue circle with even spacing; tuned for L=45-65 against dark bg.
  static const _channelColors = [
    Color(0xFF5CADFF),  // #01 Bright Blue        H=210° S=90% L=65%
    Color(0xFFE85C6C),  // #02 Warm Red           H=355° S=85% L=58%
    Color(0xFF48C878),  // #03 Medium Green       H=135° S=70% L=56%
    Color(0xFFD8B030),  // #04 Gold               H=45°  S=90% L=58%
    Color(0xFFB468D8),  // #05 Violet             H=280° S=70% L=62%
    Color(0xFFE87040),  // #06 Orange             H=20°  S=90% L=58%
    Color(0xFF40C0D0),  // #07 Cyan               H=185° S=80% L=58%
    Color(0xFFD860A0),  // #08 Rose Pink          H=325° S=75% L=60%
    Color(0xFF8888D8),  // #09 Indigo             H=245° S=65% L=65%
    Color(0xFF80C848),  // #10 Lime               H=90°  S=75% L=55%
    Color(0xFF48B898),  // #11 Mint Teal          H=160° S=65% L=54%
    Color(0xFFA858B8),  // #12 Magenta            H=295° S=60% L=55%
    Color(0xFFE0C820),  // #13 Bright Yellow      H=55°  S=95% L=60%
    Color(0xFFB05838),  // #14 Rust Brown         H=25°  S=70% L=45%
    Color(0xFF8C98A8),  // #15 Steel Gray         H=210° S=15% L=60%
    Color(0xFFF058A0),  // #16 Hot Pink           H=340° S=85% L=65%
  ];

  /// Assign colors sequentially from the palette so adjacent channels always
  /// get contrasting hues.  Wraps at palette length for 17+ channels.
  Color _assignChannelColor() {
    return _channelColors[_channels.length % _channelColors.length];
  }

  // ── Config persistence ──
  static String get _configPath {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return '$exeDir\\VCR\\plot_config.json';
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _ticker.start();
    _initDemoChannels();
    // ── AnalogSegment: create per-channel segments + enable envelope toggle ──
    if (USE_ANALOG_ENVELOPE) {
      _ensureAnalogSegments();
    }
    _startDemoData();
    _loadConfig();
    // Apply buffer size to Rust immediately when page loads
    try {
      RustLib.instance.api.crateApiPlotApiPlotSetBufferCapacity(capacity: BigInt.from(_maxPoints));
    } catch (_) {}

    // Real data timers are started on-demand by _startRealData() / _toggleDataSource().
    // Not started here — avoid wasting main thread in demo mode (50 function calls/sec).
    // GPU 加速初始化（添加 try-catch 避免崩溃）
    try {
      _initGpu();
    } catch (e) {
      print('⚠️ GPU 初始化失败，将使用 CPU 渲染: $e');
      setState(() {
        _gpuInitialized = false;
      });
    }
    _maxPointsController.text = _maxPoints.toString();
    _deltaTimeController.text = _deltaTime.toString();
    // Start data receiver (required for real device data flow)
    RustLib.instance.api.crateApiDataReceiverStartDataReceiver();
    // Load Flutter log settings asynchronously (don't block initState)
    _loadFlutterLogSettings();
  }

  /// Ensure AnalogSegment instances exist for every visible channel
  /// and set the pipeline's envelope source to AnalogSegment.
  /// Also sets samplerate based on _deltaTime (time-per-sample in ms).
  void _ensureAnalogSegments() {
    final bridge = FfiBridge.instance;
    bridge.analogSetEnvelopeEnabled(true);
    final samplerateHz = 1000.0 / _deltaTime; // deltaTime=1ms → 1000Hz
    for (int i = 0; i < _channels.length; i++) {
      bridge.analogEnsure(i);
      bridge.analogSetSamplerate(i, samplerateHz);
    }
  }

  void _initDemoChannels() {
    final devices = listDevices();
    final deviceName = devices.isNotEmpty ? devices.first.name : 'Demo';
    // Sequential index for max perceptual distance between adjacent channels
    Color c(int i) => _channelColors[i % _channelColors.length];
    _channels = [
      PlotChannel(
        deviceId: 'demo_ch1', deviceName: deviceName, channelName: 'Voltage',
        color: c(0), decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch2', deviceName: deviceName, channelName: 'Current',
        color: c(1), decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch3', deviceName: deviceName, channelName: 'Power',
        color: c(2), decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch4', deviceName: deviceName, channelName: 'Temp',
        color: c(3), decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch5', deviceName: deviceName, channelName: 'Pressure',
        color: c(4), decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch6', deviceName: deviceName, channelName: 'Flow',
        color: c(5), decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch7', deviceName: deviceName, channelName: 'Torque',
        color: c(6), decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch8', deviceName: deviceName, channelName: 'RPM',
        color: c(7), decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      // Fourier square wave approximations (5+ terms)
      PlotChannel(
        deviceId: 'demo_ch9', deviceName: deviceName, channelName: 'Square_1Hz',
        color: c(8), decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch10', deviceName: deviceName, channelName: 'Square_3Hz',
        color: c(9), decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch11', deviceName: deviceName, channelName: 'PWM_2Hz',
        color: c(10), decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch12', deviceName: deviceName, channelName: 'Step_0.5Hz',
        color: c(11), decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
    ];
  }

  /// Fourier series square wave approximation with n terms
  /// square(t) ≈ (4/π) Σ sin((2k-1)ωt) / (2k-1), k=1..n
  static double _fourierSquare(double t, double freq, int terms) {
    double sum = 0;
    for (int k = 1; k <= terms; k++) {
      final n = 2 * k - 1;
      sum += sin(n * 2 * pi * freq * t) / n;
    }
    return (4 / pi) * sum;
  }

  // Sub-samples per timer tick for smooth curves
  static const int _demoSubSamples = 10;

  double _demoEval(int channel, double t, double noise) {
    switch (channel) {
      case 0: return 3.3 * sin(2 * pi * 0.5 * t) + 0.3 * sin(2 * pi * 5.1 * t) + 0.15 * sin(2 * pi * 13.7 * t) + noise;
      case 1: return 2.0 * sin(2 * pi * 0.3 * t + pi / 4) + 0.2 * sin(2 * pi * 4.3 * t) + 0.1 * cos(2 * pi * 11.1 * t) + noise;
      case 2: return 3.3 * sin(2 * pi * 0.5 * t) * 2.0 * sin(2 * pi * 0.3 * t + pi / 4) + 0.4 * sin(2 * pi * 7.7 * t) + noise;
      case 3: return 25.0 + 10.0 * sin(2 * pi * 0.1 * t) + 3.0 * sin(2 * pi * 1.3 * t) + 1.5 * sin(2 * pi * 6.3 * t) + 0.8 * cos(2 * pi * 15.1 * t) + noise;
      case 4: return 101.3 + 5.0 * sin(2 * pi * 0.07 * t + pi / 3) + 2.0 * cos(2 * pi * 0.8 * t) + 0.8 * sin(2 * pi * 4.7 * t) + noise;
      case 5: return 5.0 + 2.0 * sin(2 * pi * 0.2 * t) + 1.0 * sin(2 * pi * 1.5 * t + pi / 6) + 0.5 * sin(2 * pi * 8.9 * t) + noise;
      case 6: return 50.0 * sin(2 * pi * 0.15 * t) + 20.0 * cos(2 * pi * 0.9 * t) + 8.0 * sin(2 * pi * 3.7 * t) + 3.0 * cos(2 * pi * 9.3 * t) + noise;
      case 7: return 3000.0 + 1500.0 * sin(2 * pi * 0.25 * t + pi / 2) + 500.0 * sin(2 * pi * 2.0 * t) + 200.0 * sin(2 * pi * 8.5 * t) + noise * 100;
      // Fourier square wave approximations
      case 8: return 3.3 * _fourierSquare(t, 1.0, 7) + noise;
      case 9: return 2.0 * _fourierSquare(t, 3.0, 7) + noise;
      case 10: return 1.0 + 0.8 * _fourierSquare(t, 2.0, 5) + noise;
      case 11: return 5.0 * _fourierSquare(t, 0.5, 9) + noise;
      default: return sin(t) + noise;
    }
  }

  
  // 每通道独立的样本索引，确保X值连续
  final List<int> _demoSampleIndices = <int>[];
  
  void _startDemoData() {
    _debugLog('[START] _startDemoData called, _useRealData=$_useRealData, _isPlaying=$_isPlaying, _maxPoints=$_maxPoints');
    _debugLog('[START] _demoChannels.length=${_demoChannels.length}, _realChannels.length=${_realChannels.length}');
    _demoTimer?.cancel();
    
    // 初始化每通道样本索引
    _demoSampleIndices.clear();
    for (int i = 0; i < _channels.length; i++) {
      _demoSampleIndices.add(0);
    }
    
    final dt = 0.008 / _demoSubSamples; // sub-sample interval
    _demoTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {  // ~20fps timer
      if (!mounted || !_isPlaying) return;
      
      final rng = Random();
      
      // Generate sub-samples per tick for smooth curves
      // Performance: batch-push to pyramid via single FFI call per channel (not per-point)
      final batchPerChannel = List.generate(_channels.length, (_) => <(double, double)>[]);
      for (int s = 0; s < _demoSubSamples; s++) {
        _demoPhase += dt;
        final t = _demoPhase;
        for (int i = 0; i < _channels.length; i++) {
          final noise = 0.05 * (rng.nextDouble() - 0.5);
          final val = _demoEval(i, t, noise);
          // Append at end: data[0]=oldest, data[last]=newest
          // Store per-channel sample index (continuous); displayed X = data.x(i) - data.lastX (offset from newest)
          final x = _demoSampleIndices[i].toDouble();
          _channels[i].data.add(_DataPoint(x, val));
          _channels[i].currentValue = val;
          batchPerChannel[i].add((x, val));
          _demoSampleIndices[i]++;
        }
      }
      // 🚀 Batch push all sub-samples at once: 1 FFI call per channel instead of N×sub-samples
      final bridge = FfiBridge.instance;
      for (int i = 0; i < _channels.length; i++) {
        if (batchPerChannel[i].isNotEmpty) {
          bridge.pushChannelBatch(i, batchPerChannel[i]);
        }
      }
      // Trim: only when data exceeds _maxPoints by a safe margin to avoid O(n) per tick.
      // Using sublist() on a large list is O(n) — we defer trimming until 110% capacity.
      if (_channels.isNotEmpty && _channels.first.data.length > _maxPoints * 11 ~/ 10) {
        _debugLog('[TRIM] Trimming data: first.data.length=${_channels.first.data.length}, _maxPoints=$_maxPoints');
        for (final ch in _channels) {
          if (ch.data.length > _maxPoints) {
            ch.data.removeRange(0, ch.data.length - _maxPoints);
          }
        }
      }
      // Demo mode: incremental count (sum of all sub-samples across all channels)
      _totalPoints += _channels.length * _demoSubSamples;
      // 每100帧输出一次调试信息
      if (_sampleIndex % 100 == 0) {
        _debugLog('[TICK] sampleIndex=$_sampleIndex, totalPoints=$_totalPoints, first.ch.data.length=${_channels.isNotEmpty ? _channels.first.data.length : 0}');
      }

      // 🩺 Fix: _refreshViewportData() MUST run BEFORE _fitYAxis() to ensure
      // Y-axis uses the same data that will be rendered (not stale data from previous frame).
      // This eliminates a one-frame Y-axis↔data mismatch glitch.
      _refreshViewportData(); // Step 1: populate ch.viewportData with fresh data
        
        if (_scrollMode) {
          // Auto-track: always show the latest data at the right edge (x=0)
          _xMax = 0.0;
          _xMin = -_effectiveScrollWindowWidth;
          _scrollMinTime = _xMin;
          if (_autoScaleY) _fitYAxis(); // Step 2: use fresh viewportData
        } else {
          if (_autoScaleX) _fitXAxis(); // Step 2: use fresh data
          if (_autoScaleY) _fitYAxis(); // Step 2: use fresh viewportData
        }
        setState(() {});
    });
  }

  // Debug log to file with level control
  // Levels (matches Settings UI): off=0, trace=1, debug=2, info=3, warn=4, error=5
  int _flutterLogLevel = 3; // default: info (same as Settings)
  String _flutterLogPath = 'debug_log.txt';
  bool _flutterFileLogging = false; // default: off (same as Settings)

  void _debugLog(String msg, {int level = 2}) {
    // Check if logging is enabled and level is sufficient
    if (!_flutterFileLogging || _flutterLogLevel == 0 || level < _flutterLogLevel) return;
    
    try {
      final file = File(_flutterLogPath);
      final levelStr = ['OFF', 'TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR'][level.clamp(0, 5)];
      file.writeAsStringSync('${DateTime.now()} [$levelStr] $msg\n', mode: FileMode.append);
    } catch (_) {
      // Ignore file write errors
    }
  }

  /// Refresh viewportData for all channels using current _xMin/_xMax.
  /// Called after scrollbar drag, zoom, or any ChartViewport change.
  /// 🚀 Phase A: Uses per-channel Rust LOD pyramid (pre-computed bucket aggregation)
  /// instead of O(n) binary search + sublist + step decimation.
  void _clearViewportCaches() {
    for (final ch in _channels) {
      ch.viewportData.clear();
      ch.envelopeData.clear();
    }
  }

  /// Feed current viewport range to pipeline for async envelope pre-computation.
  /// Cheap: just atomics, no locks. Pipeline reads this and computes envelopes at ~60Hz.
  void _notifyPipelineViewport() {
    if (_xMin == _xMax || _screenWidth <= 0) return;
    final maxPts = _screenWidth.round().clamp(500, 4000);
    // Convert relative x range to absolute timestamps for Rust pyramid query
    double anchorX = 0;
    for (final ch in _channels) {
      if (ch.data.isNotEmpty) { anchorX = ch.data.last.x; break; }
    }
    final tMinAbs = anchorX + _xMin;
    final tMaxAbs = anchorX + _xMax;
    try {
      FfiBridge.instance.envelopeSetViewport(tMinAbs, tMaxAbs, maxPts);
    } catch (_) {}
  }

  /// Read pre-computed envelope from Rust pipeline (P1: zero-copy via Pointer.asTypedList).
  /// Instead of O(N) individual dataPtr[index] FFI boundary crosses, we create a single
  /// Float64List view over the Rust Vec memory, then access it in pure Dart.
  /// Returns true if envelope data was successfully read and populated.
  bool _refreshViewportDataFromEnvelope() {
    final bridge = FfiBridge.instance;

    // Check generation — odd means pipeline is currently updating the envelope
    final gen1 = bridge.envelopeGetGeneration();
    if (gen1 & 1 != 0) return false;

    final dataPtr = bridge.envelopeGetDataPtr();
    if (dataPtr.address == 0) return false;

    final numCh = bridge.envelopeGetNumChannels();
    if (numCh == 0) return false;

    // P1: Zero-copy — map entire envelope buffer as a Dart Float64List.
    // Eliminates ~8000 individual FFI boundary crosses per frame.
    final totalSize = bridge.envelopeGetTotalSize();
    final envelopeBuf = dataPtr.asTypedList(totalSize);

    for (int ci = 0; ci < numCh && ci < _channels.length; ci++) {
      final ch = _channels[ci];
      if (!ch.visible || ch.data.isEmpty) {
        ch.viewportData.clear();
        ch.envelopeData.clear();
        continue;
      }

      final offset = bridge.envelopeGetChannelOffset(ci);
      final count = bridge.envelopeGetChannelCount(ci);
      if (count == 0) {
        ch.viewportData.clear();
        ch.envelopeData.clear();
        continue;
      }

      final newestAbsX = ch.data.last.x;
      ch.viewportData.clear();
      ch.envelopeData.clear();

      // Envelope format: [ts0,lo0, ts0+ϵ,hi0, ts1,lo1, ts1+ϵ,hi1, ...] alternating min/max per bucket
      // P1: Direct Float64List index — pure Dart, zero FFI boundary cross
      for (int i = 0; i < count; i += 2) {
        if (i + 1 >= count) break;
        final tsMin = envelopeBuf[offset + i * 2];
        final yMin = envelopeBuf[offset + i * 2 + 1];
        final yMax = envelopeBuf[offset + (i + 1) * 2 + 1];
        final yAvg = (yMin + yMax) * 0.5;
        final xRel = tsMin - newestAbsX;

        ch.viewportData.add(xRel, yAvg);
        ch.envelopeData.add(xRel, yMin);
        ch.envelopeData.add(xRel, yMax);
      }
      if (count % 2 != 0 && count > 0) {
        final lastX = envelopeBuf[offset + (count - 1) * 2] - newestAbsX;
        final lastY = envelopeBuf[offset + (count - 1) * 2 + 1];
        ch.viewportData.add(lastX, lastY);
      }
    }

    // Verify generation didn't change during read (pipeline update mid-read)
    // Note: asTypedList provides a live view; pipeline writes are atomic (generation check)
    final gen2 = bridge.envelopeGetGeneration();
    if (gen1 != gen2) return false; // Mid-update, discard

    _viewportRefreshCount++;
    return true;
  }

  void _refreshViewportData() {
    if (_xMin == _xMax || _screenWidth <= 0) return;

    // 🚀 P0-4: Try zero-copy envelope read first (pre-computed by Rust pipeline thread)
    // When USE_ANALOG_ENVELOPE, pipeline routes AnalogSegment data into RENDER_ENVELOPE
    // → _refreshViewportDataFromEnvelope() reads it through the same zero-copy C-ABI
    if (_refreshViewportDataFromEnvelope()) return;

    // Fallback: try per-channel AnalogSegment direct query (legacy, kept for debugging)
    if (USE_ANALOG_ENVELOPE && _refreshViewportFromAnalog()) return;

    // Fallback: per-channel pyramid query
    final maxPts = _screenWidth.round().clamp(500, 4000);
    final bridge = FfiBridge.instance;

    // 🚀 Reusable Float64List buffer for pyramid query results
    final maxDatapoints = maxPts * 2;
    if (_queryBuffer == null || _queryBuffer!.length != maxDatapoints * 2) {
      _queryBuffer = Float64List(maxDatapoints * 2);
    }
    final fb = _queryBuffer!;

    // 🚀 Phase C: Reuse native CDataPoint buffer
    Pointer<CDataPoint> nativeBuf;
    if (_queryNative != null && _queryNativeCap >= maxDatapoints) {
      nativeBuf = _queryNative!;
    } else {
      // Free old buffer if it exists (resize up)
      if (_queryNative != null) {
        calloc.free(_queryNative!);
      }
      _queryNative = calloc<CDataPoint>(maxDatapoints);
      _queryNativeCap = maxDatapoints;
      nativeBuf = _queryNative!;
    }

    for (int ci = 0; ci < _channels.length; ci++) {
      final ch = _channels[ci];
      if (!ch.visible || ch.data.isEmpty) {
        ch.viewportData.clear();
        ch.envelopeData.clear();
        continue;
      }

      final newestAbsX = ch.data.last.x;
      final tMin = newestAbsX + _xMin;
      final tMax = newestAbsX + _xMax;

      final count = bridge.queryChannelPointsInto(ci, tMin, tMax, maxPts, nativeBuf, maxDatapoints, fb);

      if (count == 0) {
        ch.viewportData.clear();
        ch.envelopeData.clear();
        continue;
      }

      ch.viewportData.clear();
      ch.envelopeData.clear();
      for (int i = 0; i < count; i += 2) {
        if (i + 1 >= count) break;
        final xMin = fb[i * 2] - newestAbsX;
        final yMin = fb[i * 2 + 1];
        final yMax = fb[(i + 1) * 2 + 1];
        final yAvg = (yMin + yMax) * 0.5;
        ch.viewportData.add(xMin, yAvg);
        ch.envelopeData.add(xMin, yMin);
        ch.envelopeData.add(xMin, yMax);
      }
      if (count % 2 != 0 && count > 0) {
        final lastX = fb[(count - 1) * 2] - newestAbsX;
        final lastY = fb[(count - 1) * 2 + 1];
        ch.viewportData.add(lastX, lastY);
      }

    }
    _viewportRefreshCount++;
  }

  // ── AnalogSegment envelope read (alternative to RENDER_ENVELOPE) ──
  // Called when USE_ANALOG_ENVELOPE is true.
  // Reads per-channel envelope from AnalogSegment via C-ABI (f32 min/max pairs).
  // When samplesPerPixel < ENVELOPE_THRESHOLD, uses trace mode (raw f32 values).
  bool _refreshViewportFromAnalog() {
    final bridge = FfiBridge.instance;

    // Use the existing render envelope's viewport range
    final gen1 = bridge.envelopeGetGeneration();
    if (gen1 & 1 != 0) return false;

    final numCh = bridge.envelopeGetNumChannels();
    if (numCh == 0) return false;

    // per-sample CEnvelopeSample output buffer (f32 min/max), max 8000 samples
    final maxSamples = _screenWidth.round().clamp(500, 8000);
    final sampleBuf = calloc<CEnvelopeSample>(maxSamples);
    // Trace mode buffer: raw f32 values (one per pixel)
    Pointer<Float>? traceBuf;

    // Compute samplesPerPixel from viewport and total sample count
    bool anyData = false;
    for (int ci = 0; ci < numCh && ci < _channels.length; ci++) {
      final ch = _channels[ci];
      if (!ch.visible || ch.data.isEmpty) {
        ch.viewportData.clear();
        ch.envelopeData.clear();
        continue;
      }

      final sampleCount = bridge.analogSampleCount(ci);
      if (sampleCount == 0) {
        ch.viewportData.clear();
        ch.envelopeData.clear();
        continue;
      }

      // Calculate samplesPerPixel: total samples / num pixels in viewport
      final timeRange = _xMax - _xMin;
      final timePerPx = timeRange > 0 ? timeRange / _screenWidth : 0.0;
      final samplesPerPixelDouble = timePerPx > 0
          ? sampleCount * timePerPx / timeRange
          : ENVELOPE_THRESHOLD.toDouble();

      // Map viewport [xMin, xMax] to sample indices [0, sampleCount)
      // Uses proportional mapping within ch.data x-range (works for both Demo
      // x=sample_index and Real x=timestamp)      
      final chDataFirst = ch.data.isNotEmpty ? ch.data.first.x : 0.0;
      final chDataLast = ch.data.isNotEmpty ? ch.data.last.x : 1.0;
      final chXSpan = chDataLast - chDataFirst;
      final invSpan = chXSpan > 0.0 ? 1.0 / chXSpan : 0.0;
      final startSample = ((_xMin - chDataFirst) * invSpan * sampleCount)
          .round().clamp(0, sampleCount - 1);
      final clampedEnd = ((_xMax - chDataFirst) * invSpan * sampleCount)
          .round().clamp(startSample + 1, sampleCount);

      ch.viewportData.clear();
      ch.envelopeData.clear();

      final useTrace = _renderMode == _RenderMode.trace ||
          (_renderMode == _RenderMode.auto && samplesPerPixelDouble < ENVELOPE_THRESHOLD);
      // ── Trace mode: raw f32 values ──
      if (useTrace) {
        traceBuf ??= calloc<Float>(maxSamples);
        final traceCount = bridge.analogGetTrace(
          ci, startSample, clampedEnd, traceBuf, maxSamples,
        );
        if (traceCount > 0) {
          final values = List<double>.generate(traceCount, (i) => traceBuf![i].toDouble());
          ch.viewportData = _DataBuf.fromTrace(values, startSample);
          anyData = true;
        }
        continue;
      }

      // ── Envelope mode (samplesPerPixel >= ENVELOPE_THRESHOLD): min/max pairs ──
      final sectionStartPtr = calloc<Uint64>();
      final sectionScalePtr = calloc<Uint32>();
      final count = bridge.analogGetEnvelope(
        ci, startSample, clampedEnd, samplesPerPixelDouble, sampleBuf, maxSamples,
        sectionStartPtr, sectionScalePtr,
      );
      final sectionStart = sectionStartPtr.value;
      final sectionScale = sectionScalePtr.value;
      calloc.free(sectionStartPtr);
      calloc.free(sectionScalePtr);

      if (count > 0) {
        for (int i = 0; i < count; i++) {
          final sample = sampleBuf[i];
          final yMin = sample.min.toDouble();
          final yMax = sample.max.toDouble();
          final yAvg = (yMin + yMax) * 0.5;
          // Section-aware x: section.start + i * section.scale is the actual sample position
          final xRel = (sectionStart + (i * sectionScale)).toDouble();

          ch.viewportData.add(xRel, yAvg);
          ch.envelopeData.add(xRel, yMin);
          ch.envelopeData.add(xRel, yMax);
        }
        anyData = true;
      }
    }

    calloc.free(sampleBuf);
    if (traceBuf != null) calloc.free(traceBuf);

    final gen2 = bridge.envelopeGetGeneration();
    if (gen1 != gen2) return false;

    return anyData;
  }

  /// 分离的数据轮询（策略 B: 减少 FRB 调用）
  /// 后台快速轮询，不触发 UI 更新
  void _fetchRealData() {
    // 🚀 P3-B 双缓冲：每次获取数据前，先 swap 缓冲区
    RustLib.instance.api.crateApiPlotApiPlotSwapBuffers();
    
    if (!_useRealData) return; // Skip in demo mode
    if (!_isPlaying) return; // Pause: stop data fetching

    try {
      final activeDevices = debugGetActiveSessions();

      // Build device-id → human-readable name lookup
      final allDevices = listDevices();
      final deviceNameMap = <String, String>{};
      for (final d in allDevices) {
        deviceNameMap[d.id] = d.name;
      }

      // Clean up channels for disconnected devices
      _channels.removeWhere((ch) {
        if (!activeDevices.contains(ch.deviceId) && ch.deviceId != 'demo_ch1' && !ch.deviceId.startsWith('imported_') && !ch.deviceId.startsWith('manual_')) {
          return true; // Device disconnected — remove channel
        }
        return false;
      });

      if (activeDevices.isEmpty) return;

      for (final deviceId in activeDevices) {
        // 只获取通道列表（轻量级）
        final channelNames = plotGetChannels(deviceId: deviceId);
        final devName = deviceNameMap[deviceId] ?? deviceId;

        for (final chName in channelNames) {
          // Find or create channel
          final chIdx = _channels.indexWhere(
            (c) => c.deviceId == deviceId && c.channelName == chName,
          );
          
          if (chIdx == -1) {
            if (!_autoAddChannels) continue;
            _channels.add(PlotChannel(
              deviceId: deviceId,
              deviceName: devName,
              channelName: chName,
              color: _assignChannelColor(),
              decimals: 3,
              lineStyle: LineStyle.line,
              showYAxis: false,
              plotGroupId: 'default',
            ));
            if (USE_ANALOG_ENVELOPE) {
              final newChId = _channels.length - 1;
              FfiBridge.instance.analogEnsure(newChId);
              FfiBridge.instance.analogSetSamplerate(newChId, 1000.0 / _deltaTime);
            }
          }
          
          // 获取该通道全量数据（首次）
          final targetIdx = _channels.indexWhere(
            (c) => c.deviceId == deviceId && c.channelName == chName,
          );
          if (targetIdx == -1) continue;
          
          final ch = _channels[targetIdx];
          // 只在 ch.data 为空时拉一次全量（避免每帧传输 250K 点）
          if (ch.data.isEmpty) {
            final allPoints = plotGetAllChannels(deviceId: deviceId);
            final pts = allPoints[chName];
            if (pts != null && pts.isNotEmpty) {
              // 🚀 P0-1: Use Rust timestampMs as X value (synced with pipeline pyramid)
              ch.data = pts.map((p) => _DataPoint(p.timestampMs, p.value)).toList();
              ch.currentValue = pts.last.value;
              // Pipeline pushes from receive loop — no Dart push needed
            }
          } else {
            // Get delta data: all new points since last swap (front buffer has delta only)
            try {
              final latestData = plotGetChannelLatestData(deviceId: deviceId, channel: chName);
              if (latestData.isNotEmpty) {
                // 🚀 P0-1: Use Rust timestampMs (synced with pipeline::push_sample_batch_with_x)
                for (int k = 0; k < latestData.length; k++) {
                  ch.data.add(_DataPoint(latestData[k].timestampMs, latestData[k].value));
                }
                ch.currentValue = latestData.last.value;
                // Keep only _maxPoints points (trim from front, keep newest)
                if (ch.data.length > _maxPoints) {
                  ch.data.removeRange(0, ch.data.length - _maxPoints);
                  // Pyramid self-manages via TimeBucket::max_buckets — no Dart trimming needed
                }
                // 🚀 Incremental point counting (avoid O(all_data) fold)
                _totalPoints += latestData.length;
              }
            } catch (_) {}
          }
        }
      }
    } catch (e) {
    }
  }

  /// UI 更新节流（策略 A: 分离数据轮询和 UI 更新）
  /// 每 33ms 更新一次 UI，而非每次数据轮询都更新


  void _startRealData() {
    _realDataTimer?.cancel();

    // 🚀 单定时器架构：数据获取 + UI 更新在同一回调中顺序执行
    // 消除 _fetchTimer / _realDataTimer 双定时器竞态：
    // - 旧架构：两个独立 100ms Timer，执行顺序不确定
    // - 新架构：单个 50ms Timer，先 fetch → 再 UI update，保证 pyramid 数据就绪
    // _updateRealDataUI 内部保留 33ms 节流，控制实际 UI 刷新率
    _realDataTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _fetchRealData();
      // 🩺 Diagnostic: track viewportData population
      if (_channels.isNotEmpty) {
        final hasData = _channels.where((c) => c.visible && c.data.isNotEmpty);
        final noViewport = hasData.where((c) => c.viewportData.isEmpty);
        if (noViewport.isNotEmpty && _frameCount % 20 == 0) {
          if (_verbose) print('[DIAG] ${noViewport.length}/${hasData.length} channels have empty viewportData (frame $_frameCount)');
        }
        _frameCount++;
      }
      // 🩺 Diagnostic: check Rust-side overflow counts every 200 frames (~10s)
      if (_frameCount % 200 == 0) {
        try {
          final overflow = RustLib.instance.api.crateApiPlotApiPlotGetOverflowCounts();
          if (overflow.isNotEmpty) {
            if (_verbose) print('[DIAG-OVERFLOW] ChannelBuffer overflow detected:');
            for (final entry in overflow) {
              if (_verbose) print('  ${entry.$1} / ${entry.$2}: ${entry.$3} drops');
            }
          }
        } catch (_) {}
      }
    });
  }

  void _toggleDataSource() {
    setState(() {
      _useRealData = !_useRealData;
      _saveConfig();

      // 🚀 Phase C: Clear all per-channel pyramids to prevent demo↔real data mixing.
      // Pyramids are keyed by channel index; switching modes reuses the same indices
      // but with different channel lists (_demoChannels vs _realChannels).
      FfiBridge.instance.clearAllChannelPyramids();
      // 🚀 Also bump viewportRefreshCount to invalidate _PlotPainter cached picture
      // (otherwise shouldRepaint returns false, reusing stale demo rendering).
      _viewportRefreshCount++;

      if (_useRealData) {
        // Switch to real data: stop demo timer, start real data timer
        _demoTimer?.cancel();
        // Init real channels if empty
        if (_realChannels.isEmpty) {
          _startRealData();
        } else {
          // Resume real data timer
          _realDataTimer?.cancel();
          _realDataTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
            _fetchRealData();
          });
        }
      } else {
        // Switch to demo: stop real data timer, start demo timer
        _realDataTimer?.cancel();
        // Init demo channels if empty
        if (_demoChannels.isEmpty) {
          _initDemoChannels();
        }
        _startDemoData();
      }
    });
  }

  void _fitXAxis() {
    _debugLog('[FITX] called, _scrollMode=$_scrollMode, _useRealData=$_useRealData, _maxPoints=$_maxPoints');
    if (_scrollMode) return; // X axis is controlled by scroll window
    final bufMin = -_maxPoints.toDouble();
    
    // 统一 Demo 和 Real 模式的 X 轴范围计算
    // 两种模式都使用相同的坐标系统：X 值是相对索引（-N+1 到 0）
    if (_channels.isNotEmpty) {
      final firstCh = _channels.first;
      if (firstCh.data.isNotEmpty) {
        // 使用实际数据点数计算范围，确保滑块与波形一致
        final numPoints = firstCh.data.length;
        _xMin = (-numPoints).toDouble().clamp(bufMin, 0.0);
        _xMax = 0.0;
        _debugLog('[FITX] Unified mode: numPoints=$numPoints, bufMin=$bufMin, xMin=$_xMin, _maxPoints=$_maxPoints');
        return;
      }
      // 数据为空，使用默认范围
      _debugLog('[FITX] Unified mode: no data, setting xMin=$bufMin, _maxPoints=$_maxPoints');
      _xMin = bufMin;
      _xMax = 0.0;
      return;
    }
    
    // 没有通道时的默认范围
    _xMin = bufMin;
    _xMax = 0.0;
    _debugLog('[FITX] Default: no channels, xMin=$bufMin');
  }

  // 🚀 性能优化：计算绘图区域尺寸（用于GPU渲染）
  double _plotWidth() {
    final yAxisChannels = _channels.where((ch) => ch.visible && ch.showYAxis).toList();
    final leftYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 0).length;
    final rightYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 1).length;
    final plotLeft = 50.0 + leftYAxes * 45.0;
    final plotRight = 10.0 + rightYAxes * 45.0;
    return MediaQuery.of(context).size.width - plotLeft - plotRight;
  }

  double _plotHeight() {
    final plotBottom = 40.0;
    final plotTop = 10.0;
    return MediaQuery.of(context).size.height - plotTop - plotBottom;
  }

  void _fitYAxisForChannel(PlotChannel ch) {
    if (!ch.visible) return;

    final prevYMin = ch.yMin;
    final prevYMax = ch.yMax;
    double minVal = double.infinity;
    double maxVal = double.negativeInfinity;

    // P0-2: Prefer GC-free viewportData, fallback to ch.data (List<_DataPoint>)
    if (ch.viewportData.isNotEmpty) {
      for (int i = 0; i < ch.viewportData.length; i++) {
        final y = ch.viewportData.y(i);
        if (y < minVal) minVal = y;
        if (y > maxVal) maxVal = y;
      }
    } else if (ch.data.isNotEmpty) {
      for (final pt in ch.data) {
        if (pt.y < minVal) minVal = pt.y;
        if (pt.y > maxVal) maxVal = pt.y;
      }
    } else {
      return;
    }
    if (minVal.isInfinite) { minVal = -1; maxVal = 1; }
    final range = maxVal - minVal;
    final padding = range * 0.1;
    final targetMin = minVal - padding;
    final targetMax = maxVal + padding;
    
    // 🩺 EMA-smooth Y-axis to eliminate 1-frame range oscillation glitches.
    // Smoothing factor 0.4: ~40% new + 60% old. Smaller = more stable, larger = faster adaptation.
    const double ySmooth = 0.4;
    if (ch._smoothedYMin == null) {
      ch._smoothedYMin = targetMin;
      ch._smoothedYMax = targetMax;
    } else {
      ch._smoothedYMin = ch._smoothedYMin! * (1.0 - ySmooth) + targetMin * ySmooth;
      ch._smoothedYMax = ch._smoothedYMax! * (1.0 - ySmooth) + targetMax * ySmooth;
    }
    ch.yMin = ch._smoothedYMin!;
    ch.yMax = ch._smoothedYMax!;
    ch.autoScaleY = true;
    // 🩺 Diagnostic: detect Y-axis oscillation (target range change > 5%)
    // Note: smoothed values are used for rendering; this detects raw target oscillations
    if (prevYMax != double.negativeInfinity) {
      final yRangeDelta = ((targetMax - targetMin) - (prevYMax - prevYMin)).abs();
      final oldRange = (prevYMax - prevYMin).abs();
      if (oldRange > 0.001 && yRangeDelta / oldRange > 0.05) {
        final smoothDelta = ((ch.yMax - ch.yMin) - (prevYMax - prevYMin)).abs();
        final smoothPct = (smoothDelta / oldRange * 100).toStringAsFixed(1);
        if (_verbose) print('[DIAG-Y-OSC] ${ch.channelName}: target ${((yRangeDelta/oldRange)*100).toStringAsFixed(1)}% but smoothed only $smoothPct% (prev [${prevYMin.toStringAsFixed(3)}, ${prevYMax.toStringAsFixed(3)}] → target [${targetMin.toStringAsFixed(3)}, ${targetMax.toStringAsFixed(3)}] → rendered [${ch.yMin.toStringAsFixed(3)}, ${ch.yMax.toStringAsFixed(3)}]) dataLen=${ch.viewportData.length}');
      }
    }
    // Update global Y range to encompass this channel's new range
    if (minVal - padding < _yMin) _yMin = minVal - padding;
    if (maxVal + padding > _yMax) _yMax = maxVal + padding;
  }

  void _fitYAxis() {
    _yMin = double.infinity;
    _yMax = double.negativeInfinity;
    for (final ch in _channels) {
      _fitYAxisForChannel(ch);
    }
    if (_yMin.isInfinite) { _yMin = -1; _yMax = 1; }
  }


  // Dynamic Y-axis slot layout matching _paintInternal
  // slot 0,2,4... = left, slot 1,3,5... = right
  // slot N x-offset from plotLeft edge = (N+1)*45 (left) or (N+1)*45 (right)
  int _leftSlotCount() {
    final yAxisChannels = _channels.where((ch) => ch.visible && ch.showYAxis).toList();
    return (yAxisChannels.length + 1) ~/ 2;
  }

  int _rightSlotCount() {
    final yAxisChannels = _channels.where((ch) => ch.visible && ch.showYAxis).toList();
    return yAxisChannels.length ~/ 2;
  }

  double _plotLeft() => 50.0 + _leftSlotCount() * 45.0;
  double _plotRight() => 10.0 + _rightSlotCount() * 45.0;
  double _plotTop() => 10;
  double _plotBottom() => 40;

  /// Get total X data range (earliest → latest across all visible channels)
  /// Get total X data range (earliest → latest across all visible channels)
  /// Data X values are sample indices (0, 1, 2, ...)
  /// X axis displays time = sample_index * Δt (in ms)
  /// X axis range: [-缓冲区大小, 0]
  (double, double) _getDataXRange() {
    // X轴范围固定为 [-缓冲区大小, 0]
    // 无论数据多少，范围始终固定，用户通过滑块宽度控制显示范围
    if (_maxPoints <= 0) _maxPoints = 250000;
    return (-_maxPoints.toDouble(), 0.0);
  }

  /// Find which channel's Y-axis is closest to cursor X position.
  /// Returns -1 if none.
  PlotChannel? _findYAxisChannelAtX(double cursorX, double plotLeft, double plotW, [List<PlotChannel>? channels]) {
    final chList = channels ?? _channels;
    final yAxisChannels = chList.asMap().entries
        .where((e) => e.value.visible && e.value.showYAxis)
        .map((e) => e.key)
        .toList();
    if (yAxisChannels.isEmpty) return null;
    const hitHalfW = 30.0;

    for (int ci = 0; ci < yAxisChannels.length; ci++) {
      final isLeft = ci % 2 == 0;
      final slotIdx = ci ~/ 2;
      double axisX;
      if (isLeft) {
        axisX = plotLeft - slotIdx * 45.0 - 2.0;
      } else {
        axisX = plotLeft + plotW + slotIdx * 45.0 + 2.0;
      }
      if ((cursorX - axisX).abs() < hitHalfW) {
        return chList[yAxisChannels[ci]];
      }
    }
    return null;
  }


  void _onTick(Duration elapsed) {
    // P0-2: Frame budget guard — skip if prev tick still rendering (prevents cascading lag)
    if (_tickBusy) return;
    if (!mounted || !_isPlaying) return;
    _tickBusy = true;
    try {
      // Skip expensive refresh if viewport unchanged AND no new data arrived
      bool idleSkip = false;
      try {
        final vpGen = FfiBridge.instance.envelopeGetGeneration();
        final hasNewData = FfiBridge.instance.checkDataReady();
        if (!hasNewData && vpGen == _lastVpGen && _lastVpGen >= 0) {
          _lastVpGen = vpGen;
          idleSkip = true;
        } else {
          _lastVpGen = vpGen;
        }
      } catch (_) {
        // checkDataReady or envelopeGetGeneration not available — fall through to normal refresh
      }
      if (idleSkip) {
        // Only tick FPS counter, skip data refresh
        _fpsFrameCount++;
        final now = DateTime.now();
        if (now.difference(_lastFpsTime).inMilliseconds >= 1000) {
          _fps = _fpsFrameCount;
          _fpsFrameCount = 0;
          _lastFpsTime = now;
        }
        setState(() {}); // Still need FPS display update
        return;
      }
      _fpsFrameCount++;
      final now = DateTime.now();
      if (now.difference(_lastFpsTime).inMilliseconds >= 1000) {
        _fps = _fpsFrameCount;
        _fpsFrameCount = 0;
        _lastFpsTime = now;
      }
      // P0-2: Ticker-driven vsync rendering — lightweight pyramid query + repaint
      // Timer still handles data generation/fetching; Ticker provides smooth 60fps rendering
      if (_useRealData) {
        _notifyPipelineViewport(); // Feed viewport BEFORE refresh → pipeline computes async
        _refreshViewportData(); // Reads envelope (from prev frame) or falls back to pyramid query
        if (_autoScaleY) _fitYAxis();
        if (!_scrollMode && _autoScaleX) _fitXAxis();
        setState(() {});
      } else {
        _notifyPipelineViewport(); // Feed viewport BEFORE refresh
        _refreshViewportData(); // Reads envelope (from prev frame) or falls back to pyramid query
        if (_scrollMode) {
          _xMax = 0.0;
          _xMin = -_effectiveScrollWindowWidth;
          _scrollMinTime = _xMin;
        }
        if (_autoScaleY) _fitYAxis();
        if (!_scrollMode && _autoScaleX) _fitXAxis();
        setState(() {});
      }
    } finally {
      _tickBusy = false;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _demoTimer?.cancel();
    _realDataTimer?.cancel();
    // GPU 𫔰阌
    if (_gpuInitialized) {
      RustLib.instance.api.crateApiGpuApiGpuCleanup();
    }
    // 停止 Rust 独立线程（方案3）
    RustLib.instance.api.crateApiDataReceiverStopDataReceiver();
    // 🚀 Phase C: Free reusable native query buffer
    if (_queryNative != null) {
      calloc.free(_queryNative!);
      _queryNative = null;
    }
    _queryBuffer = null;
    super.dispose();
  }

  // ── Config persistence ──

  Future<void> _loadConfig() async {
    try {
      final file = File(_configPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final chConfigs = json['channels'] as List?;
        if (chConfigs != null) {
          for (final chJson in chConfigs) {
            try {
              final c = chJson as Map<String, dynamic>;
              final cDevId = c['deviceId'] as String? ?? '';
              final cName = c['channelName'] as String? ?? '';
              // Match by deviceId + channelName (not index) so config survives reordering
              final matchIdx = _channels.indexWhere(
                (ch) => ch.deviceId == cDevId && ch.channelName == cName,
              );
              if (matchIdx == -1) continue;
              _channels[matchIdx].visible = c['visible'] as bool? ?? true;
              _channels[matchIdx].decimals = c['decimals'] as int? ?? 3;
              _channels[matchIdx].showYAxis = c['showYAxis'] as bool? ?? true;
              _channels[matchIdx].lineStyle = LineStyle.values.firstWhere(
                (e) => e.name == c['lineStyle'], orElse: () => LineStyle.line);
              _channels[matchIdx].plotGroupId = c['plotGroupId'] as String? ?? 'default';
              _channels[matchIdx].autoScaleY = c['autoScaleY'] as bool? ?? true;
              _channels[matchIdx].yMinManual = (c['yMinManual'] as num?)?.toDouble() ?? -1;
              _channels[matchIdx].yMaxManual = (c['yMaxManual'] as num?)?.toDouble() ?? 1;
              _channels[matchIdx].lineWidth = (c['lineWidth'] as num?)?.toDouble() ?? 1.5;
              _channels[matchIdx].color = c['color'] is int
                  ? Color(c['color'] as int)
                  : _channels[matchIdx].color;
            } catch (e) {
              debugPrint('Failed to load channel config: $e');
            }
          }
        }
        // Load plot groups
        final groupConfigs = json['plotGroups'] as List?;
        if (groupConfigs != null && groupConfigs.isNotEmpty) {
          try {
            _plotGroups = groupConfigs
                .map((g) => PlotGroup.fromJson(g as Map<String, dynamic>))
                .toList();
            // Ensure 'default' group always exists
            if (!_plotGroups.any((g) => g.id == 'default')) {
              _plotGroups.insert(0, PlotGroup(id: 'default', name: 'Default'));
            }
          } catch (e) {
            debugPrint('Failed to load plot groups: $e');
            _plotGroups = [PlotGroup(id: 'default', name: 'Default')];
          }
        }
        final aaIdx = json['aaLevel'] as int?;
        if (aaIdx != null && aaIdx >= 0 && aaIdx < AntiAliasingLevel.values.length) {
          _aaLevel = AntiAliasingLevel.values[aaIdx];
        }
        _panelWidth = (json['panelWidth'] as num?)?.toDouble() ?? 220.0;
        _shareYAxis = json['shareYAxis'] as bool? ?? false;
        _scrollMode = json['scrollMode'] as bool? ?? false;
        _scrollWindowWidth = (json['scrollWindowWidth'] as num?)?.toDouble() ?? 0.0;
        _scrollMinTime = (json['scrollMinTime'] as num?)?.toDouble() ?? 0.0;
        _maxPoints = (json['maxPoints'] as num?)?.toInt() ?? 250000;
        _deltaTime = (json['deltaTime'] as num?)?.toDouble() ?? 1.0;
        _plotThemeDark = json['plotThemeDark'] as bool? ?? true;
        _autoAddChannels = json['autoAddChannels'] as bool? ?? true;
        _useRealData = json['useRealData'] as bool? ?? false;
        _maxPointsController.text = _maxPoints.toString();
        _deltaTimeController.text = _deltaTime.toString();
        // Load Flutter log settings from app_config.json
        try {
          final exeDir = File(Platform.resolvedExecutable).parent.path;
          final appFile = File('$exeDir\\VCR\\app_config.json');
          if (await appFile.exists()) {
            final appConfig = jsonDecode(await appFile.readAsString()) as Map<String, dynamic>;
            final logLevel = appConfig['logLevel'] as String? ?? 'info';
            _flutterLogLevel = ['off', 'trace', 'debug', 'info', 'warn', 'error'].indexOf(logLevel);
            if (_flutterLogLevel < 0) _flutterLogLevel = 3;
            _flutterLogPath = appConfig['logPath'] as String? ?? 'debug_log.txt';
            _flutterFileLogging = appConfig['fileLoggingEnabled'] as bool? ?? false;
          }
        } catch (e) {
          debugPrint('Failed to load Flutter log settings: $e');
        }
        // Refresh all UI with loaded config values
        if (mounted) setState(() {});
      }
    } catch (e) {
      debugPrint('Failed to load plot config: $e');
    }
  }

  Future<void> _loadFlutterLogSettings() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final appFile = File('$exeDir\\VCR\\app_config.json');
      if (await appFile.exists()) {
        final appConfig = jsonDecode(await appFile.readAsString()) as Map<String, dynamic>;
        final logLevel = appConfig['logLevel'] as String? ?? 'info';
        _flutterLogLevel = ['off', 'trace', 'debug', 'info', 'warn', 'error'].indexOf(logLevel);
        if (_flutterLogLevel < 0) _flutterLogLevel = 3;
        _flutterLogPath = appConfig['logPath'] as String? ?? 'debug_log.txt';
        _flutterFileLogging = appConfig['fileLoggingEnabled'] as bool? ?? false;
      }
    } catch (e) {
      debugPrint('Failed to load Flutter log settings: $e');
    }
  }

  Future<void> _saveConfig() async {
    try {
      final file = File(_configPath);
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      await file.writeAsString(JsonEncoder.withIndent('  ').convert({
        'channels': _channels.map((ch) => ch.toJson()).toList(),
        'plotGroups': _plotGroups.map((g) => g.toJson()).toList(),
        'aaLevel': _aaLevel.index,
        'panelWidth': _panelWidth,
        'shareYAxis': _shareYAxis,
        'scrollMode': _scrollMode,
        'scrollWindowWidth': _scrollWindowWidth,
        'scrollMinTime': _scrollMinTime,
        'maxPoints': _maxPoints,
        'deltaTime': _deltaTime,
        'plotThemeDark': _plotThemeDark,
        'autoAddChannels': _autoAddChannels,
        'useRealData': _useRealData,
      }));
      // Also sync to app_config.json so settings screen picks it up
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final appFile = File('$exeDir\\VCR\\app_config.json');
      Map<String, dynamic> appConfig = {};
      if (await appFile.exists()) {
        try {
          appConfig = jsonDecode(await appFile.readAsString()) as Map<String, dynamic>;
        } catch (e) {
          debugPrint('Failed to parse app_config.json: $e');
        }
      }
      appConfig['plotAALevel'] = _aaLevel.index;
      if (!await appFile.parent.exists()) await appFile.parent.create(recursive: true);
      await appFile.writeAsString(JsonEncoder.withIndent('  ').convert(appConfig));
    } catch (e) {
      debugPrint('Failed to save plot config: $e');
    }
  }

  void _setAALevel(AntiAliasingLevel level) {
    setState(() => _aaLevel = level);
    _saveConfig();
  }

  // ── GPU Acceleration ──
  // 启用GPU渲染
  Future<void> _initGpu() async {
    try {
      await RustLib.instance.api.crateApiGpuApiGpuInit();
      setState(() {
        _gpuInitialized = true;
        _useGpuAcceleration = true;
      });
    } catch (e) {
      print('GPU init error: $e');
      setState(() {
        _gpuInitialized = false;
        _useGpuAcceleration = false;
      });
    }
  }

  Future<ui.Image> _createImageFromRgba(Uint8List rgbaBytes, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgbaBytes,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (image) => completer.complete(image),
    );
    return completer.future;
  }

  // ignore: unused_element
  Future<void> _renderWaveformOnGpu() async {
    if (!_useGpuAcceleration || !_gpuInitialized || _isGpuRendering) return;
    if (_channels.isEmpty) return;

    _isGpuRendering = true;
    try {
      final points = <double>[];
      for (final ch in _channels.where((c) => c.visible && c.viewportData.isNotEmpty)) {
        final vd = ch.viewportData;
        for (int i = 0; i < vd.length; i++) {
          points.add(vd.x(i));
          points.add(vd.y(i));
        }
      }

      if (points.isEmpty) {
        _isGpuRendering = false;
        return;
      }

      final pointCount = points.length ~/ 2;
      // 使用实际绘图区域尺寸，而非硬编码的800x600
      final renderWidth = _plotWidth().toInt().clamp(100, 4096);
      final renderHeight = _plotHeight().toInt().clamp(100, 4096);

      print('[GPU] Rendering ${renderWidth}x$renderHeight, points=$pointCount');

      final imageData = await RustLib.instance.api.crateApiGpuApiGpuRenderWaveform(
        width: renderWidth,
        height: renderHeight,
        points: Float32List.fromList(points),
        pointCount: pointCount,
        r: 255,
        g: 0,
        b: 0,
        a: 255,
      );

      final image = await _createImageFromRgba(imageData, renderWidth, renderHeight);

      setState(() {
        _gpuWaveformImage = image;
      });
    } catch (e) {
      print('GPU render error: $e');
    } finally {
      _isGpuRendering = false;
    }
  }

  // ── CSV Export/Import ──

  void _clearData() {
    // Reset sample counter so X axis starts from 0 again
    plotClearCounter();
    // Clear Rust-side data for all active devices
    final deviceIds = _channels.map((c) => c.deviceId).toSet();
    for (final deviceId in deviceIds) {
      plotClearDevice(deviceId: deviceId);
    }
    setState(() {
      _sampleIndex = 0;
      _demoPhase = 0;
      // Reset per-channel demo sample indices
      _demoSampleIndices.clear();
      for (int i = 0; i < _channels.length; i++) {
        _demoSampleIndices.add(0);
      }
      for (final ch in _channels) {
        ch.data.clear();
        ch.viewportData.clear();
        ch.envelopeData.clear();
        ch.currentValue = 0.0;
      }
      // 🚀 Phase A: Clear per-channel pyramids on data reset
      FfiBridge.instance.clearAllChannelPyramids();
      _totalPoints = 0;
      if (_scrollMode) {
        _scrollMinTime = 0;
      }
      _autoScaleX = true;
      _autoScaleY = true;
      _fitXAxis();
      _fitYAxis();
    });
  }

  Future<void> _exportCsv() async {
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Waveform Data',
        fileName: 'waveform_${DateTime.now().millisecondsSinceEpoch}.csv',
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (path == null) return;

      final visibleChannels = _channels.where((ch) => ch.visible && ch.data.isNotEmpty).toList();
      if (visibleChannels.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No visible channels with data to export'), duration: Duration(seconds: 2)),
          );
        }
        return;
      }

      // Wide format CSV: Time,Ch1,Time,Ch2,Time,Ch3,...
      // Each channel writes its own X (timestamp) + Y value
      final sb = StringBuffer();
      for (int c = 0; c < visibleChannels.length; c++) {
        if (c > 0) sb.write(',');
        sb.write('Time,${visibleChannels[c].deviceName} - ${visibleChannels[c].channelName}');
      }
      sb.writeln();

      int maxLen = visibleChannels.fold(0, (m, ch) => max(m, ch.data.length));
      for (int i = 0; i < maxLen; i++) {
        for (int c = 0; c < visibleChannels.length; c++) {
          if (c > 0) sb.write(',');
          final ch = visibleChannels[c];
          if (i < ch.data.length) {
            sb.write('${ch.data[i].x.toStringAsFixed(6)},${ch.data[i].y.toStringAsFixed(ch.decimals)}');
          } else {
            sb.write(',');
          }
        }
        sb.writeln();
      }

      final file = File(path);
      await file.writeAsString(sb.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported to $path'), duration: const Duration(seconds: 2)),
        );
      }
    } catch (e) {
      debugPrint('Failed to export CSV: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), duration: const Duration(seconds: 3)),
        );
      }
    }
  }

  Future<void> _importCsv() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import Waveform Data',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (result == null || result.files.isEmpty) return;

    final path = result.files.single.path;
    if (path == null) return;

    try {
      final content = await File(path).readAsString();
      final lines = content.trim().split('\n');
      if (lines.isEmpty) return;

      final header = lines[0].split(',');
      final importedChannels = <PlotChannel>[];

      for (int col = 1; col < header.length; col++) {
        importedChannels.add(PlotChannel(
          deviceId: 'imported_$col',
          deviceName: 'Imported',
          channelName: header[col].trim(),
          color: _channelColors[(col - 1) % _channelColors.length],
        ));
      }

      for (int row = 1; row < lines.length; row++) {
        final parts = lines[row].split(',');
        if (parts.isEmpty) continue;
        final x = double.tryParse(parts[0].trim()) ?? row.toDouble();
        for (int col = 1; col < parts.length && col - 1 < importedChannels.length; col++) {
          final y = double.tryParse(parts[col].trim());
          if (y != null) {
            importedChannels[col - 1].data.add(_DataPoint(x, y));
            importedChannels[col - 1].currentValue = y;
          }
        }
      }

      setState(() {
        _channels = importedChannels;
        _isPlaying = false;
        _autoScaleX = true;
        _autoScaleY = true;
        _fitXAxis();
        _fitYAxis();
      });
      if (USE_ANALOG_ENVELOPE) {
        final bridge = FfiBridge.instance;
        for (int ci = 0; ci < _channels.length; ci++) {
          bridge.analogEnsure(ci);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e'), duration: const Duration(seconds: 3)),
        );
      }
    }
  }

  // ── Channel management ──

  void _addChannel() {
    final idx = _channels.length;
    setState(() {
      _channels.add(PlotChannel(
        deviceId: 'manual_$idx',
        deviceName: 'Manual',
        channelName: 'Channel ${idx + 1}',
        color: _channelColors[idx % _channelColors.length],
        plotGroupId: _plotGroups.isNotEmpty ? _plotGroups.first.id : 'default',
      ));
    });
    if (USE_ANALOG_ENVELOPE) {
      FfiBridge.instance.analogEnsure(idx);
    }
    _saveConfig();
  }

  void _removeChannel(int index) {
    setState(() {
      _channels.removeAt(index);
    });
    _saveConfig();
  }

  // ── Plot Group management ──
  void _addPlotGroup() {
    final idx = _plotGroups.length;
    final id = 'group_$idx';
    setState(() {
      _plotGroups.add(PlotGroup(
        id: id,
        name: 'Group ${idx + 1}',
      ));
    });
    _saveConfig();
  }

  void _removePlotGroup(String groupId) {
    if (groupId == 'default') return; // Can't remove default group
    setState(() {
      _plotGroups.removeWhere((g) => g.id == groupId);
      // Move channels from removed group to default
      for (final ch in _channels) {
        if (ch.plotGroupId == groupId) {
          ch.plotGroupId = 'default';
        }
      }
    });
    _saveConfig();
  }

  void _renamePlotGroup(String groupId, String newName) {
    setState(() {
      final g = _plotGroups.firstWhere((g) => g.id == groupId);
      g.name = newName;
    });
    _saveConfig();
  }

  /// Get list of groups that have at least one visible channel
  List<PlotGroup> _activeGroups() {
    final activeGroupIds = <String>{};
    for (final ch in _channels) {
      if (ch.visible) {
        activeGroupIds.add(ch.plotGroupId);
      }
    }
    // Always include groups that exist, even if no visible channels
    // (so user can see empty groups they created)
    return _plotGroups.where((g) => activeGroupIds.contains(g.id) || g.id == 'default').toList();
  }

  // ── Scroll mode settings dialog ──
  void _showScrollModeSettings() {
    final widthCtrl = TextEditingController(text: _effectiveScrollWindowWidth.round().toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(_scrollMode ? Icons.waves : Icons.timeline, color: _scrollMode ? Colors.amber : AppTheme.textSecondary),
          const SizedBox(width: 8),
          Text(_scrollMode ? 'Scroll Mode Settings' : 'Enable Scroll Mode?'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_scrollMode)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  'Oscilloscope mode continuously sweeps the waveform like a real scope. '
                  'The window auto-scrolls to show the latest data.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                ),
              ),
            const Text('Window Width (seconds):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: widthCtrl,
                  decoration: const InputDecoration(
                    hintText: 'e.g. 10',
                    border: OutlineInputBorder(),
                    suffixText: 's',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onSubmitted: (v) {
                    final w = double.tryParse(v);
                    if (w != null && w > 0) {
                      setState(() => _scrollWindowWidth = w);
                      _saveConfig();
                    }
                  },
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6, runSpacing: 6,
              children: [100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0, 10000.0].map((w) => ActionChip(
                label: Text(w.round().toString(), style: const TextStyle(fontSize: 12)),
                onPressed: () { widthCtrl.text = w.toStringAsFixed(w == w.roundToDouble() ? 0 : 1); },
              )).toList(),
            ),
            if (_scrollMode) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Text('Current window: ${_scrollMinTime.toStringAsFixed(2)}s → ${(_scrollMinTime + _effectiveScrollWindowWidth).toStringAsFixed(2)}s',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ],
          ],
        ),
        actions: [
          if (_scrollMode)
            TextButton(
              onPressed: () {
                setState(() => _scrollMode = false);
                _saveConfig();
                Navigator.of(ctx).pop();
              },
              child: const Text('Disable Scroll Mode', style: TextStyle(color: Colors.red)),
            ),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final w = double.tryParse(widthCtrl.text);
              if (w != null && w > 0) {
                setState(() {
                  _scrollMode = true;
                  _scrollWindowWidth = w;
                  // Reset window to show latest data
                  if (_channels.isNotEmpty && _channels.first.data.isNotEmpty) {
                    final latest = _channels.first.data.last.x;
                    _scrollMinTime = (latest - _effectiveScrollWindowWidth).clamp(0.0, latest);
                    _xMin = _scrollMinTime;
                    _xMax = latest;
                  }
                });
                _saveConfig();
              }
              Navigator.of(ctx).pop();
            },
            child: Text(_scrollMode ? 'Apply' : 'Enable Scroll Mode'),
          ),
        ],
      ),
    );
  }

  void _showPyramidDebug() {
    if (USE_ANALOG_ENVELOPE) {
      final buf = StringBuffer();
      for (var i = 0; i < _channels.length; i++) {
        final info = FfiBridge.instance.analogDumpDebug(i);
        buf.writeln('═══ Channel $i ═══');
        buf.writeln(info);
        buf.writeln();
      }
      _pyramidDebugText = buf.toString();
    } else {
      _pyramidDebugText = 'AnalogSegment envelope is DISABLED.\nSet USE_ANALOG_ENVELOPE = true to view pyramid state.';
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.bug_report, size: 20),
            const SizedBox(width: 8),
            const Text('Pyramid Debug', style: TextStyle(fontSize: 16)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () {
                Navigator.of(ctx).pop();
                _showPyramidDebug(); // Refresh
              },
            ),
          ],
        ),
        content: SizedBox(
          width: 600,
          height: 500,
          child: SingleChildScrollView(
            child: SelectableText(
              _pyramidDebugText,
              style: const TextStyle(
                fontFamily: 'Consolas',
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ── Build UI ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Δt 输入框
            Tooltip(
              message: '采样间隔(Δt): 相邻采样点之间的时间间隔(毫秒)。X轴显示范围 = -缓冲区大小 × Δt 到 0。',
              child: SizedBox(
                width: 70,
                height: 32,
                child: TextField(
                  controller: _deltaTimeController,
                  decoration: const InputDecoration(
                    labelText: 'Δt (ms)',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  ),
                  style: const TextStyle(fontSize: 11),
                  onSubmitted: (value) {
                    final parsed = double.tryParse(value);
                    if (parsed != null && parsed > 0) {
                      setState(() => _deltaTime = parsed);
                      _saveConfig();
                    }
                  },
                ),
              ),
            ),
            const SizedBox(width: 6),
            // 缓冲区大小输入框
            Tooltip(
              message: '缓冲区大小(点/通道): 每个通道的最大数据点数。控制缓冲区大小和X轴范围。',
              child: SizedBox(
                width: 140,
                height: 32,
                child: TextField(
                  controller: _maxPointsController,
                  decoration: const InputDecoration(
                    labelText: '缓冲区大小(点/通道)',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  ),
                  style: const TextStyle(fontSize: 11),
                  onSubmitted: (value) {
                    final parsed = int.tryParse(value);
                    if (parsed != null && parsed > 0) {
                      setState(() {
                        _maxPoints = parsed.clamp(1000, 500000);
                        _maxPointsController.text = _maxPoints.toString();
                        // If scroll window was auto, it auto-adjusts via _effectiveScrollWindowWidth
                        // If manual, update proportionally
                        // Reset X range to new [-MaxPoints, 0]
                        _xMin = -_maxPoints.toDouble();
                        _xMax = 0.0;
                      });
                      _saveConfig();
                      // 同步到 Rust 缓冲区
                      RustLib.instance.api.crateApiPlotApiPlotSetBufferCapacity(capacity: BigInt.from(_maxPoints));
                    }
                  },
                ),
              ),
            ),
          ],
        ),
        centerTitle: false,
        actions: [
          // Auto-scale button
          IconButton(
            icon: Icon(Icons.fit_screen, color: _autoScaleX || _autoScaleY ? AppTheme.primary : AppTheme.textSecondary),
            onPressed: () {
              setState(() {
                _autoScaleX = true;
                _autoScaleY = true;
                _fitXAxis();
                _fitYAxis();
              });
            },
            tooltip: 'Auto Scale',
          ),
          // Share Y Axis toggle
          IconButton(
            icon: Icon(
              _shareYAxis ? Icons.vertical_align_center : Icons.vertical_align_bottom,
              color: _shareYAxis ? AppTheme.primary : AppTheme.textSecondary,
              size: 20,
            ),
            onPressed: () {
              setState(() => _shareYAxis = !_shareYAxis);
              _saveConfig();
            },
            tooltip: _shareYAxis ? 'Share Y Axis (ON)' : 'Share Y Axis (OFF)',
          ),
          // Render mode toggle (Auto → Trace → Envelope)
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _renderMode != _RenderMode.auto
                    ? (_renderMode == _RenderMode.trace
                        ? Colors.blue.withValues(alpha: 0.2)
                        : Colors.purple.withValues(alpha: 0.2))
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(
                _renderMode == _RenderMode.trace
                    ? Icons.show_chart
                    : _renderMode == _RenderMode.envelope
                        ? Icons.area_chart
                        : Icons.auto_graph,
                color: _renderMode != _RenderMode.auto
                    ? (_renderMode == _RenderMode.trace ? Colors.blue : Colors.purple)
                    : AppTheme.textSecondary,
                size: 20,
              ),
            ),
            onPressed: () {
              setState(() {
                _renderMode = _RenderMode.values[
                    (_renderMode.index + 1) % _RenderMode.values.length];
              });
            },
            tooltip: 'Render Mode: ${_renderMode.name.toUpperCase()}',
          ),
          // Pyramid Debug
          IconButton(
            icon: Icon(Icons.bug_report, size: 20, color: AppTheme.textSecondary),
            onPressed: _showPyramidDebug,
            tooltip: 'Pyramid Debug',
          ),
          // Data source toggle
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _useRealData ? AppTheme.primary.withValues(alpha: 0.2) : AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(
                _useRealData ? Icons.sensors : Icons.science,
                color: _useRealData ? AppTheme.primary : AppTheme.textSecondary,
                size: 20,
              ),
            ),
            onPressed: _toggleDataSource,
            tooltip: _useRealData ? 'Real Data Mode' : 'Demo Mode',
          ),
          // Play/Pause with filled icon
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _isPlaying ? AppTheme.secondary.withValues(alpha: 0.2) : AppTheme.error.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(
                _isPlaying ? Icons.play_arrow : Icons.pause,
                color: _isPlaying ? AppTheme.secondary : AppTheme.error,
                size: 20,
              ),
            ),
            onPressed: () {
            setState(() {
              _isPlaying = !_isPlaying;
            });
            if (!_isPlaying) {
              // Pause: cancel timer to stop all updates
              _realDataTimer?.cancel();
            } else if (_useRealData) {
              // Resume: restart timers
              _startRealData();
            }
          },
            tooltip: _isPlaying ? 'Pause Display' : 'Resume Display',
          ),
          // Export
          IconButton(
            icon: const Icon(Icons.file_download),
            onPressed: _exportCsv,
            tooltip: 'Export CSV',
          ),
          // Import
          IconButton(
            icon: const Icon(Icons.file_upload),
            onPressed: _importCsv,
            tooltip: 'Import CSV',
          ),
          // Clear data
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: _clearData,
            tooltip: 'Clear Data',
          ),
          // Theme toggle
          IconButton(
            icon: Icon(_plotThemeDark ? Icons.dark_mode : Icons.light_mode, size: 20),
            onPressed: () => setState(() { _plotThemeDark = !_plotThemeDark; _saveConfig(); }),
            tooltip: _plotThemeDark ? 'Plot Theme: Dark' : 'Plot Theme: Light',
          ),
          // Scroll mode (oscilloscope sweep) toggle + settings
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _scrollMode ? Colors.amber.withValues(alpha: 0.2) : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(
                _scrollMode ? Icons.waves : Icons.timeline,
                color: _scrollMode ? Colors.amber : AppTheme.textSecondary,
                size: 20,
              ),
            ),
            onPressed: _showScrollModeSettings,
            tooltip: _scrollMode
                ? 'Scroll Mode ON — ${_effectiveScrollWindowWidth.toStringAsFixed(1)}s window'
                : 'Scroll Mode (Oscilloscope Sweep)',
          ),
          // Channel config
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showChannelConfig,
            tooltip: 'Channel Config',
          ),
          // Add Plot Group
          IconButton(
            icon: const Icon(Icons.dashboard_customize),
            onPressed: () => _showPlotGroupManager(),
            tooltip: 'Plot Groups',
          ),
          // Anti-aliasing level toggle
          PopupMenuButton<AntiAliasingLevel>(
            icon: Icon(
              Icons.blur_on,
              color: _aaLevel != AntiAliasingLevel.off ? AppTheme.primary : AppTheme.textSecondary,
              size: 22,
            ),
            tooltip: 'Anti-Aliasing: ${_aaLevel.label}',
            onSelected: (level) => _setAALevel(level),
            itemBuilder: (context) => AntiAliasingLevel.values.map((level) {
              return PopupMenuItem(
                value: level,
                child: Row(
                  children: [
                    Icon(
                      _aaLevel == level ? Icons.check : null,
                      size: 16,
                      color: AppTheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(level.label),
                    const SizedBox(width: 12),
                    if (level != AntiAliasingLevel.off)
                      Text('${level.scale.toInt()}×', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
      body: Row(
        children: [
          // Main plot area
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  Expanded(child: _buildPlotArea()),
                  _buildWaveformScrollbar(constraints),
                ],
              ),
            ),
          ),
          // Resize handle (optimized for visibility)
          GestureDetector(
            onHorizontalDragUpdate: (details) {
              setState(() {
                _panelWidth = (_panelWidth - details.delta.dx).clamp(150.0, 400.0);
              });
            },
            onHorizontalDragEnd: (_) {
              _saveConfig();
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: Container(
                width: 8,
                color: Colors.transparent,
                child: Center(
                  child: Container(
                    width: 4,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 2,
                          spreadRadius: 0,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Right panel: numeric values
          SizedBox(
            width: _panelWidth,
            child: _buildNumericPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildPlotArea() {
    final activeGroups = _activeGroups();
    // If only 1 active group with all channels → single plot (original behavior)
    if (activeGroups.length <= 1) {
      return _buildSinglePlotArea(_channels);
    }

    // Multiple groups → vertically stacked plots
    final totalRatio = activeGroups.fold(0.0, (sum, g) => sum + g.heightRatio);
    return Container(
      color: const Color(0xFF0A0E14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalHeight = constraints.maxHeight;
          return Column(
            children: activeGroups.asMap().entries.map((entry) {
              final group = entry.value;
              final groupChannels = _channels.where((ch) => ch.plotGroupId == group.id).toList();
              final height = (totalHeight * group.heightRatio / totalRatio);
              return SizedBox(
                height: height,
                child: Column(
                  children: [
                    // Group label bar
                    Container(
                      height: 20,
                      color: const Color(0xFF161B22),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Text(
                            group.name,
                            style: const TextStyle(
                              color: Color(0xFF8B949E),
                              fontSize: 16,
                              fontFamily: 'DS-Digital',
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${groupChannels.where((c) => c.visible).length} ch',
                            style: const TextStyle(
                              color: Color(0xFF8B949E),
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // The actual plot for this group
                    Expanded(
                      child: _buildSinglePlotArea(groupChannels, groupId: group.id),
                    ),
                  ],
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  /// Build a single plot area for the given list of channels.
  /// This is the original _buildPlotArea logic, now parameterized.
  Widget _buildSinglePlotArea(List<PlotChannel> channels, {String groupId = 'default'}) {
    return Container(
      color: const Color(0xFF0A0E14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Track plot area width for ChartViewport decimation
          final plotLeftPx = 50.0; // approximate, matches painter
          final plotRightPx = 10.0;
          _screenWidth = (constraints.maxWidth - plotLeftPx - plotRightPx).clamp(100.0, 4000.0);
          return MouseRegion(
            onHover: (details) {
              setState(() => _mousePosition = details.localPosition);
            },
            onExit: (_) {
              setState(() => _mousePosition = null);
            },
            child: GestureDetector(
              onDoubleTapDown: (details) {
                final pos = details.localPosition;
                final h = constraints.maxHeight;
                final w = constraints.maxWidth;
                final plotTop = _plotTop().toDouble();
                final plotBottom = _plotBottom().toDouble();
                // Bottom 40px = X axis zone → auto-scale X
                if (pos.dy > h - plotBottom) {
                  setState(() {
                    _autoScaleX = true;
                    _fitXAxis();
                  });
                  return;
                }
                // Check if near a specific Y axis
                final plotLeft = _plotLeft().toDouble();
                final plotRight = _plotRight().toDouble();
                final plotW = w - plotLeft - plotRight;
                final targetCh = _findYAxisChannelAtX(pos.dx, plotLeft, plotW, channels);
                if (targetCh != null) {
                  setState(() {
                    _fitYAxisForChannel(targetCh);
                  });
                  return;
                }
                // Top margin = Y axis zone → global Y
                if (pos.dy < plotTop) {
                  setState(() {
                    _autoScaleY = true;
                    _fitYAxis();
                  });
                  return;
                }
              },
              onPanStart: (details) {
                _isDragging = true;
                _dragStart = details.localPosition;
                _dragStartXMin = _xMin;
                _dragStartXMax = _xMax;
                _dragStartYMin = _yMin;
                _dragStartYMax = _yMax;
                _dragStartScrollMin = _scrollMinTime;
                if (!_scrollMode) {
                  _autoScaleX = false;
                  _autoScaleY = false;
                }
              },
              onPanUpdate: (details) {
                if (!_isDragging || _dragStart == null) return;
                final dx = details.localPosition.dx - _dragStart!.dx;
                final dy = details.localPosition.dy - _dragStart!.dy;
                final w = constraints.maxWidth;
                final h = constraints.maxHeight;
                if (w == 0 || h == 0) return;

                setState(() {
                  if (_scrollMode) {
                    // In scroll mode: drag ChartViewport left/right within fixed range [-缓冲区大小, 0]
                    final xRange = _getDataXRange().$2 - _getDataXRange().$1; // Total X range
                    _scrollMinTime = (_dragStartScrollMin - dx / w * xRange)
                        .clamp(-_maxPoints.toDouble(), 0.0);
                    _xMin = _scrollMinTime;
                    _xMax = 0.0;  // Newest data always at x=0
                  } else {
                    // Normal mode: pan X and Y, but X clamped to [-_maxPoints, 0]
                    final xRange = _dragStartXMax - _dragStartXMin;
                    final yRange = _dragStartYMax - _dragStartYMin;
                    var newXMin = _dragStartXMin - dx / w * xRange;
                    var newXMax = _dragStartXMax - dx / w * xRange;
                    // Clamp X pan: never exceed [-_maxPoints, 0]
                    final bufMin = -_maxPoints.toDouble();
                    if (newXMin < bufMin) { final shift = bufMin - newXMin; newXMin += shift; newXMax += shift; }
                    if (newXMax > 0.0) { final shift = newXMax - 0.0; newXMin -= shift; newXMax -= shift; }
                    if (newXMin < bufMin) newXMin = bufMin;
                    _xMin = newXMin;
                    _xMax = newXMax;
                    _yMin = _dragStartYMin + dy / h * yRange;
                    _yMax = _dragStartYMax + dy / h * yRange;
                  }
                  // ⚡ skip _refreshViewportData during drag for smooth panning
                  _clearViewportCaches();
                });
              },
              onPanEnd: (_) {
                _isDragging = false;
                _dragStart = null;
                _refreshViewportData(); // refresh viewport data on release
              },
              child: Listener(
                onPointerSignal: (signal) {
                  if (signal is PointerScrollEvent) {
                    final dy = signal.scrollDelta.dy;
                    if (dy == 0) return;
                    final pos = signal.localPosition;
                    final h = constraints.maxHeight;
                    final w = constraints.maxWidth;

                    final nearXAxis = pos.dy > h - 40;
                    final plotLeft = _plotLeft();
                    final plotRight = _plotRight();
                    final plotW = w - plotLeft - plotRight;
                    final targetCh = _findYAxisChannelAtX(pos.dx, plotLeft, plotW, channels);
                    // Zoom factor: scroll up = zoom in (factor < 1), scroll down = zoom out (factor > 1)
                    final factor = dy > 0 ? 1.1 : 0.9;

                    setState(() {
                      if (nearXAxis) {
                        // X-axis scroll: zoom X only
                        _autoScaleX = false;
                        final center = (_xMin + _xMax) / 2;
                        final range = (_xMax - _xMin) * factor;
                        // Clamp: zoom range must stay within [-_maxPoints, 0]
                        final bufMin = -_maxPoints.toDouble();
                        final maxRange = 0.0 - bufMin;  // full range
                        // 不设最小范围，允许缩放到任意小
                        final clampedRange = range.clamp(0.0, maxRange);
                        _xMin = (center - clampedRange / 2).clamp(bufMin, 0.0);
                        _xMax = (center + clampedRange / 2).clamp(bufMin, 0.0);
                        // Ensure still within bounds after centering
                        if (_xMin < bufMin) { _xMin = bufMin; _xMax = bufMin + clampedRange; }
                        if (_xMax > 0.0) { _xMax = 0.0; _xMin = 0.0 - clampedRange; }
                      } else if (targetCh != null && !_shareYAxis) {
                        // Per-channel Y zoom (near specific channel's Y axis) — only when NOT sharing Y axis
                        final ch = targetCh;
                        final chYMin = ch.autoScaleY ? ch.yMin : ch.yMinManual;
                        final chYMax = ch.autoScaleY ? ch.yMax : ch.yMaxManual;
                        final center = (chYMin + chYMax) / 2;
                        final range = chYMax - chYMin;
                        ch.yMin = center - range / 2 * factor;
                        ch.yMax = center + range / 2 * factor;
                      } else if (targetCh != null && _shareYAxis) {
                        // When sharing Y axis, per-channel Y-axis zoom affects global range
                        _autoScaleY = false;
                        final center = (_yMin + _yMax) / 2;
                        final range = _yMax - _yMin;
                        _yMin = center - range / 2 * factor;
                        _yMax = center + range / 2 * factor;
                      } else {
                        // Middle area: zoom BOTH X + Y
                        _autoScaleX = false;
                        _autoScaleY = false;
                        final xCenter = (_xMin + _xMax) / 2;
                        final xRange = (_xMax - _xMin) * factor;
                        // Clamp X zoom: range must stay within [-_maxPoints, 0]
                        final bufMin = -_maxPoints.toDouble();
                        final maxXRange = 0.0 - bufMin;
                        // 最小范围 = 总范围的2%
                        final minXRange = maxXRange * 0.02;
                        final clampedXRange = xRange.clamp(minXRange, maxXRange);
                        _xMin = xCenter - clampedXRange / 2;
                        _xMax = xCenter + clampedXRange / 2;
                        if (_xMin < bufMin) { _xMin = bufMin; _xMax = bufMin + clampedXRange; }
                        if (_xMax > 0.0) { _xMax = 0.0; _xMin = 0.0 - clampedXRange; }
                        final yCenter = (_yMin + _yMax) / 2;
                        final yRange = _yMax - _yMin;
                        _yMin = yCenter - yRange / 2 * factor;
                        _yMax = yCenter + yRange / 2 * factor;
                      }
                    });
                  }
                },
                child: CustomPaint(
                  painter: _PlotPainter(
                    channels: channels,
                    xMin: _xMin, xMax: _xMax,
                    yMin: _groupYMin[groupId] ?? _yMin,
                    yMax: _groupYMax[groupId] ?? _yMax,
                    mousePosition: _mousePosition,
                    fps: _fps,
                    totalPoints: _totalPoints,
                    aaScale: _aaLevel.scale,
                    globalDecimals: _globalDecimals,
                    shareYAxis: _shareYAxis,
                    isDarkTheme: _plotThemeDark,
                    gpuWaveformImage: _gpuWaveformImage,
                    deltaTime: _deltaTime,
                    viewportRefreshCount: _viewportRefreshCount,
                    renderMode: _renderMode,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Build waveform scrollbar with minimap preview
  Widget _buildWaveformScrollbar(BoxConstraints constraints) {
    // Scrollbar always shows the full buffer range [-maxPoints, 0]
    final effDataXMin = -_maxPoints.toDouble();
    final effDataXMax = 0.0;
    final totalRange = effDataXMax - effDataXMin; // = _maxPoints
    if (totalRange <= 0) return const SizedBox.shrink();

    final scrollbarHeight = 36.0;
    final trackPadding = 16.0; // Padding on each side so handles are always visible
    final plotLeft = trackPadding;
    final plotRight = trackPadding;
    final trackWidth = constraints.maxWidth - plotLeft - plotRight;
    if (trackWidth <= 0) return const SizedBox.shrink();

    // Current visible window position and size
    // Clamp visible range to data range for scrollbar display
    final visibleMin = _xMin.clamp(effDataXMin, effDataXMax);
    final visibleMax = _xMax.clamp(effDataXMin, effDataXMax);
    if (visibleMin >= visibleMax) {
      // Fallback: show full range
      return SizedBox(
        height: scrollbarHeight,
        child: Row(children: [Expanded(child: Container(
          decoration: BoxDecoration(color: Colors.grey[900], border: Border.all(color: Colors.grey[700]!, width: 1)),
        ))]),
      );
    }

    var thumbLeft = plotLeft + ((visibleMin - effDataXMin) / totalRange) * trackWidth;
    var thumbRight = plotLeft + ((visibleMax - effDataXMin) / totalRange) * trackWidth;
    var thumbWidth = thumbRight - thumbLeft;

    // If visible window exceeds data range (zoomed out past data),
    // the thumb would be wider than track — clamp it
    if (thumbWidth > trackWidth) {
      thumbLeft = plotLeft;
      thumbRight = plotLeft + trackWidth;
      thumbWidth = trackWidth;
    }

    // Minimum thumb width (8px) to prevent rendering artifacts
    const minThumbWidth = 8.0;
    if (thumbRight - thumbLeft < minThumbWidth) {
      final center = (thumbLeft + thumbRight) / 2;
      thumbLeft = center - minThumbWidth / 2;
      thumbRight = center + minThumbWidth / 2;
      thumbWidth = minThumbWidth;
    }
    // Final clamp: never let thumb extend beyond track bounds
    thumbLeft = thumbLeft.clamp(plotLeft, plotLeft + trackWidth - minThumbWidth);
    thumbRight = thumbRight.clamp(plotLeft + minThumbWidth, plotLeft + trackWidth);
    thumbWidth = thumbRight - thumbLeft;

    return SizedBox(
      height: scrollbarHeight,
      child: Row(
        children: [
          Expanded(
            child: Stack(
              children: [
                // Track background
                Positioned(
                  left: plotLeft,
                  right: plotRight,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      border: Border.all(color: Colors.grey[700]!, width: 1),
                    ),
                  ),
                ),
                // Minimap preview
                Positioned(
                  left: plotLeft,
                  width: trackWidth,
                  top: 0,
                  bottom: 0,
                  child: CustomPaint(
                    painter: _MinimapPainter(
                      channels: _channels,
                      dataXMin: effDataXMin,
                      dataXMax: effDataXMax,
                      shareYAxis: _shareYAxis,
                      globalYMin: _yMin,
                      globalYMax: _yMax,
                    ),
                  ),
                ),
                // Thumb
                Positioned(
                  left: thumbLeft,
                  width: thumbWidth,
                  top: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onHorizontalDragStart: (d) {
                      _scrollbarDrag = _ScrollbarDrag.thumb;
                      _scrollbarDragStartX = d.globalPosition.dx;
                      _scrollbarDragStartXMin = _xMin;
                      _scrollbarDragStartXMax = _xMax;
                    },
                    onHorizontalDragUpdate: (d) {
                      if (_scrollbarDrag != _ScrollbarDrag.thumb) return;
                      final dx = d.globalPosition.dx - _scrollbarDragStartX;
                      final dxRatio = dx / trackWidth;
                      final range = _scrollbarDragStartXMax - _scrollbarDragStartXMin;
                      var newMin = _scrollbarDragStartXMin + dxRatio * totalRange;
                      var newMax = newMin + range;
                      // Clamp: never exceed [-_maxPoints, 0]
                      final bufMin = -_maxPoints.toDouble();
                      if (newMin < bufMin) { newMin = bufMin; newMax = bufMin + range; }
                      if (newMax > 0.0) { newMax = 0.0; newMin = 0.0 - range; }
                      if (newMin < bufMin) newMin = bufMin;  // re-clamp after adjustment
                      _xMin = newMin;
                      _xMax = newMax;
                      if (_scrollMode) {
                        _scrollMinTime = newMin.clamp(0.0, double.maxFinite);
                        _scrollWindowWidth = range;
                      } else {
                        _autoScaleX = false;
                      }
                      setState(() { _clearViewportCaches(); }); // ⚡ drag-only: skip _refreshViewportData (17 FFI calls) for smooth UI
                    },
                    onHorizontalDragEnd: (d) {
                      _scrollbarDrag = _ScrollbarDrag.none;
                      _refreshViewportData(); // refresh viewport data on release
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        border: Border.all(color: Colors.blue, width: 2),
                      ),
                    ),
                  ),
                ),
                // Left edge handle — always inside thumb left edge, white on blue
                // Width reduced to 20% of original (12.0 → 2.4, using 4.0 for usability)
                Positioned(
                  left: thumbLeft,
                  width: 4.0,
                  top: 2,
                  bottom: 2,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    child: GestureDetector(
                      onHorizontalDragStart: (d) {
                        _scrollbarDrag = _ScrollbarDrag.leftEdge;
                        _scrollbarDragStartX = d.globalPosition.dx;
                        _scrollbarDragStartXMin = _xMin;
                        _scrollbarDragStartXMax = _xMax;
                      },
                      onHorizontalDragUpdate: (d) {
                        if (_scrollbarDrag != _ScrollbarDrag.leftEdge) return;
                        final dx = d.globalPosition.dx - _scrollbarDragStartX;
                        final dxRatio = dx / trackWidth;
                        var newMin = _scrollbarDragStartXMin + dxRatio * totalRange;
                        // Minimum viewport width: at least 10 data points or 1% of range
                        final minRange = (totalRange * 0.01).clamp(10.0, totalRange);
                        if (newMin > _scrollbarDragStartXMax - minRange) {
                          newMin = _scrollbarDragStartXMax - minRange;
                        }
                        newMin = newMin.clamp(-_maxPoints.toDouble(), _scrollbarDragStartXMax - minRange);
                        _xMin = newMin;
                        if (_scrollMode) {
                          _scrollMinTime = newMin.clamp(0.0, double.maxFinite);
                          _scrollWindowWidth = _scrollbarDragStartXMax - newMin;
                        } else {
                          _autoScaleX = false;
                        }
                        setState(() { _clearViewportCaches(); }); // ⚡ drag-only: skip _refreshViewportData
                      },
                      onHorizontalDragEnd: (d) {
                        _scrollbarDrag = _ScrollbarDrag.none;
                        _refreshViewportData();
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(220),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Center(
                          child: Icon(Icons.chevron_left, size: 6, color: Colors.black87),
                        ),
                      ),
                    ),
                  ),
                ),
                // Right edge handle — always inside thumb right edge, white on blue
                // Width reduced to 20% of original (12.0 → 2.4, using 4.0 for usability)
                Positioned(
                  left: thumbRight - 4.0,
                  width: 4.0,
                  top: 2,
                  bottom: 2,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    child: GestureDetector(
                      onHorizontalDragStart: (d) {
                        _scrollbarDrag = _ScrollbarDrag.rightEdge;
                        _scrollbarDragStartX = d.globalPosition.dx;
                        _scrollbarDragStartXMin = _xMin;
                        _scrollbarDragStartXMax = _xMax;
                      },
                      onHorizontalDragUpdate: (d) {
                        if (_scrollbarDrag != _ScrollbarDrag.rightEdge) return;
                        final dx = d.globalPosition.dx - _scrollbarDragStartX;
                        final dxRatio = dx / trackWidth;
                        var newMax = _scrollbarDragStartXMax + dxRatio * totalRange;
                        // Minimum viewport width: at least 10 data points or 1% of range
                        final minRange = (totalRange * 0.01).clamp(10.0, totalRange);
                        newMax = newMax.clamp(_scrollbarDragStartXMin + minRange, 0.0);
                        _xMax = newMax;
                        if (_scrollMode) {
                          _scrollWindowWidth = newMax - _scrollbarDragStartXMin;
                        } else {
                          _autoScaleX = false;
                        }
                        setState(() { _clearViewportCaches(); }); // ⚡ drag-only: skip _refreshViewportData
                      },
                      onHorizontalDragEnd: (d) {
                        _scrollbarDrag = _ScrollbarDrag.none;
                        _refreshViewportData();
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(220),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Center(
                          child: Icon(Icons.chevron_right, size: 6, color: Colors.black87),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNumericPanel() {
    // Sort by device first, then channel name (same-device channels adjacent)
    final displayChannels = _useRealData 
        ? (List<PlotChannel>.from(_channels)..sort((a, b) {
            final devCompare = a.deviceName.toLowerCase().compareTo(b.deviceName.toLowerCase());
            if (devCompare != 0) return devCompare;
            // Natural sort for channel names within same device: ch0, ch1, ch10
            final aMatch = RegExp(r'ch(\d+)', caseSensitive: false).firstMatch(a.channelName);
            final bMatch = RegExp(r'ch(\d+)', caseSensitive: false).firstMatch(b.channelName);
            if (aMatch != null && bMatch != null) {
              return int.parse(aMatch.group(1)!).compareTo(int.parse(bMatch.group(1)!));
            }
            return a.channelName.toLowerCase().compareTo(b.channelName.toLowerCase());
          }))
        : _channels;
    
    return Container(
      color: AppTheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header with add button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Text('Values', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: _addChannel,
                  tooltip: 'Add Channel',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: displayChannels.length,
              itemBuilder: (context, index) {
                final ch = displayChannels[index];
                final actualIdx = _channels.indexOf(ch);
                return GestureDetector(
                  // Left-click: toggle visibility
                  onTap: () {
                    setState(() => ch.visible = !ch.visible);
                    _saveConfig();
                  },
                  // Right-click: channel config popup
                  onSecondaryTapUp: (_) => _showSingleChannelConfig(actualIdx),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: ch.visible ? null : AppTheme.surfaceVariant.withValues(alpha: 0.5),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                // Color dot — right-click target for config
                                GestureDetector(
                                  onSecondaryTapUp: (_) => _showSingleChannelConfig(index),
                                  child: Container(
                                    width: 12, height: 12,
                                    decoration: BoxDecoration(
                                      color: ch.visible ? ch.color : ch.color.withValues(alpha: 0.3),
                                      shape: BoxShape.circle,
                                      border: ch.visible ? null : Border.all(color: AppTheme.textSecondary, width: 1),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    ch.channelName,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: ch.visible ? AppTheme.textSecondary : AppTheme.textSecondary.withValues(alpha: 0.4),
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                // Delete button
                                IconButton(
                                  icon: Icon(Icons.close, size: 14, color: AppTheme.textSecondary.withValues(alpha: 0.5)),
                                  onPressed: () => _removeChannel(actualIdx),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                                  tooltip: 'Remove Channel',
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              ch.visible ? ch.currentValue.toStringAsFixed(ch.decimals) : '---',
                              style: TextStyle(
                                color: ch.visible ? ch.color : ch.color.withValues(alpha: 0.3),
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'DS-Digital',
                              ),
                            ),
                            Text(
                              ch.deviceName,
                              style: TextStyle(fontSize: 10, color: AppTheme.textSecondary.withValues(alpha: 0.5)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showSingleChannelConfig(int index) {
    final ch = _channels[index];
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Channel: ${ch.channelName}'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Visibility
                SwitchListTile(
                  value: ch.visible,
                  title: const Text('Visible'),
                  onChanged: (v) {
                    setDialogState(() => ch.visible = v);
                    setState(() {});
                  },
                  activeThumbColor: AppTheme.primary,
                ),
                const SizedBox(height: 8),
                // Channel name
                TextFormField(
                  initialValue: ch.channelName,
                  decoration: const InputDecoration(labelText: 'Channel Name', isDense: true),
                  onChanged: (v) {
                    ch.channelName = v;
                    setState(() {});
                  },
                ),
                const SizedBox(height: 12),
                // Device name
                TextFormField(
                  initialValue: ch.deviceName,
                  decoration: const InputDecoration(labelText: 'Device Name', isDense: true),
                  onChanged: (v) {
                    ch.deviceName = v;
                    setState(() {});
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    // Decimals
                    SizedBox(
                      width: 100,
                      child: DropdownButtonFormField<int>(
                        initialValue: ch.decimals,
                        decoration: const InputDecoration(
                          labelText: 'Decimals',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        ),
                        items: List.generate(9, (d) => DropdownMenuItem(value: d, child: Text('$d'))),
                        onChanged: (v) {
                          if (v != null) {
                            setDialogState(() => ch.decimals = v);
                            _viewportRefreshCount++;
                            setState(() {});
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Line style
                    SizedBox(
                      width: 130,
                      child: DropdownButtonFormField<LineStyle>(
                        initialValue: ch.lineStyle,
                        decoration: const InputDecoration(
                          labelText: 'Style',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        ),
                        items: LineStyle.values.map((ls) => DropdownMenuItem(value: ls, child: Text(ls.label))).toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setDialogState(() => ch.lineStyle = v);
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Line Width
                Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: DropdownButtonFormField<double>(
                        initialValue: ch.lineWidth,
                        decoration: const InputDecoration(
                          labelText: 'Line Width',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        ),
                        items: [0.5, 1.0, 1.5, 2.0, 3.0, 4.0].map((w) => DropdownMenuItem(value: w, child: Text(w.toStringAsFixed(1)))).toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setDialogState(() => ch.lineWidth = v);
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Show Y axis
                SwitchListTile(
                  value: ch.showYAxis,
                  title: const Text('Show Y-Axis', style: TextStyle(fontSize: 13)),
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) {
                    setDialogState(() => ch.showYAxis = v);
                    setState(() {});
                  },
                ),
                const SizedBox(height: 8),
                // Plot Group assignment
                DropdownButtonFormField<String>(
                  initialValue: ch.plotGroupId,
                  decoration: const InputDecoration(
                    labelText: 'Plot Group',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                  items: _plotGroups.map((g) => DropdownMenuItem(
                    value: g.id,
                    child: Text(g.name),
                  )).toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setDialogState(() => ch.plotGroupId = v);
                      setState(() {});
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                _saveConfig();
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showPlotGroupManager() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Plot Groups'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // List of existing groups
                ..._plotGroups.map((group) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        group.id == 'default' ? Icons.folder_special : Icons.folder,
                        size: 18,
                        color: const Color(0xFF8B949E),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: TextEditingController(text: group.name)
                            ..selection = TextSelection.fromPosition(
                              TextPosition(offset: group.name.length),
                            ),
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(vertical: 4),
                          ),
                          onChanged: (val) => _renamePlotGroup(group.id, val),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${_channels.where((c) => c.plotGroupId == group.id).length} ch',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF8B949E)),
                      ),
                      if (group.id != 'default') ...[
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            _removePlotGroup(group.id);
                            setDialogState(() {});
                          },
                          tooltip: 'Remove group',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        ),
                      ],
                    ],
                  ),
                )),
                const Divider(),
                // Add group button
                TextButton.icon(
                  onPressed: () {
                    _addPlotGroup();
                    setDialogState(() {});
                  },
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add Group'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  void _showChannelConfig() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Channel Configuration'),
          content: SizedBox(
            width: 560,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _channels.length,
              itemBuilder: (ctx, i) {
                final ch = _channels[i];
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 14, height: 14,
                              decoration: BoxDecoration(color: ch.color, shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text(ch.channelName, style: const TextStyle(fontWeight: FontWeight.bold))),
                            Switch(
                              value: ch.visible,
                              onChanged: (v) {
                                setDialogState(() => ch.visible = v);
                                setState(() {});
                              },
                            ),
                            IconButton(
                              icon: Icon(Icons.close, size: 16, color: AppTheme.textSecondary.withValues(alpha: 0.5)),
                              onPressed: () {
                                setDialogState(() => _channels.removeAt(i));
                                setState(() {});
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                              tooltip: 'Remove',
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            SizedBox(
                              width: 100,
                              child: DropdownButtonFormField<int>(
                                initialValue: ch.decimals,
                                decoration: const InputDecoration(
                                  labelText: 'Decimals',
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                ),
                                items: List.generate(9, (d) => DropdownMenuItem(value: d, child: Text('$d'))),
                                onChanged: (v) {
                                  if (v != null) {
                                    setDialogState(() => ch.decimals = v);
                                    _viewportRefreshCount++;
                                    setState(() {});
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            SizedBox(
                              width: 130,
                              child: DropdownButtonFormField<LineStyle>(
                                initialValue: ch.lineStyle,
                                decoration: const InputDecoration(
                                  labelText: 'Style',
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                ),
                                items: LineStyle.values.map((ls) => DropdownMenuItem(value: ls, child: Text(ls.label))).toList(),
                                onChanged: (v) {
                                  if (v != null) {
                                    setDialogState(() => ch.lineStyle = v);
                                    setState(() {});
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              child: SwitchListTile(
                                value: ch.showYAxis,
                                title: const Text('Y-Axis', style: TextStyle(fontSize: 12)),
                                contentPadding: EdgeInsets.zero,
                                onChanged: (v) {
                                  setDialogState(() => ch.showYAxis = v);
                                  setState(() {});
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: _addChannel,
              child: const Text('Add Channel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            ElevatedButton(
              onPressed: () {
                _saveConfig();
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Custom Painter — the actual waveform rendering
// ============================================================================

class _MinimapPainter extends CustomPainter {
  final List<PlotChannel> channels;
  final double dataXMin, dataXMax;
  final bool shareYAxis;
  final double globalYMin, globalYMax;

  _MinimapPainter({
    required this.channels,
    required this.dataXMin,
    required this.dataXMax,
    required this.shareYAxis,
    required this.globalYMin,
    required this.globalYMax,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rangeX = dataXMax - dataXMin;
    if (rangeX <= 0) return;

    for (final ch in channels) {
      if (!ch.visible) continue;

      // P0-2: Prefer GC-free viewportData, fallback to ch.data
      final int ptCount;
      final double Function(int) getX, getY;
      if (ch.viewportData.isNotEmpty) {
        ptCount = ch.viewportData.length;
        getX = (i) => ch.viewportData.x(i);
        getY = (i) => ch.viewportData.y(i);
      } else if (ch.data.isNotEmpty) {
        ptCount = ch.data.length;
        getX = (i) => ch.data[i].x;
        getY = (i) => ch.data[i].y;
      } else {
        continue;
      }
      // Each channel uses its own Y range so all are visible in the minimap
      final chYMin = ch.autoScaleY ? ch.yMin : ch.yMinManual;
      final chYMax = ch.autoScaleY ? ch.yMax : ch.yMaxManual;
      final rangeY = chYMax - chYMin;
      if (rangeY <= 0) continue;

      final paint = Paint()
        ..color = ch.color.withAlpha(150)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;

      final path = Path();
      var started = false;
      for (int i = 0; i < ptCount; i++) {
        final x = ((getX(i) - dataXMin) / rangeX) * size.width;
        final y = size.height - ((getY(i) - chYMin) / rangeY) * size.height;
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter old) {
    return dataXMin != old.dataXMin ||
        dataXMax != old.dataXMax ||
        shareYAxis != old.shareYAxis ||
        globalYMin != old.globalYMin ||
        globalYMax != old.globalYMax;
  }
}

class _PlotPainter extends CustomPainter {
  // ═══ Per-frame reusable Float32List buffers for drawRawPoints ═══
  Float32List? _lineBuf;
  Float32List? _envBuf;
  Float32List? _minMaxBuf;  // P1-2: vertical min-max line segments

  // ═══ Static cached paint objects (zero allocation on paint path) ═══
  static final _gpuImagePaint = Paint()..filterQuality = FilterQuality.high;
  static final _gridPaint = Paint()
    ..color = const Color(0xFF4A5A70)
    ..strokeWidth = 0.5;
  static final _zeroPaint = Paint()
    ..color = const Color(0xFF4A5A70)
    ..strokeWidth = 1.0;
  static final _gridTextStyle = TextStyle(
    color: const Color(0xFF8B949E),
    fontSize: 15,
    fontFamily: 'DS-Digital',
  );
  static final _miniBgPaint = Paint()..color = const Color(0xDD161B22);
  static final _aaDownsamplePaint = Paint()
    ..filterQuality = FilterQuality.medium
    ..blendMode = BlendMode.srcOver;
  // 🚀 P1: Reusable per-channel Paint + Path objects (zero per-frame allocation)
  static final _linePaint = Paint()..style = PaintingStyle.stroke;
  static final _envelopeFillPaint = Paint()
    ..style = PaintingStyle.fill;
  // P1-2: Min-max vertical line paint — oscilloscope-style per-bucket density bar
  static final _minMaxLinePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.5
    ..strokeCap = StrokeCap.round;
  // P4: Gap marker paints — shaded column + edge lines at data discontinuities
  static final _gapMarkerPaint = Paint()
    ..style = PaintingStyle.fill;
  static final _gapEdgePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  // Dot line style: cached paint + path
  static final _dotLinePaint = Paint()..style = PaintingStyle.stroke;
  static final _dotPointPaint = Paint();
  // Reusable TextPainters (one per frame use case, avoid per-frame allocation)
  static final _overlayTp = TextPainter(textDirection: TextDirection.ltr);
  static final _crosshairTp = TextPainter(textDirection: TextDirection.ltr);

  // ═══ Dark theme paints ═══
  static final _dkBg = Paint()..color = const Color(0xFF0A0E14);
  static final _dkPlotBg = Paint()..color = const Color(0xFF0D1117);
  static final _dkBorder = Paint()
    ..color = const Color(0xFF30363D)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;
  // Legacy aliases for GPU waveform path (always dark)
  static final _bgPaint = Paint()..color = const Color(0xFF0A0E14);
  static final _plotBgPaint = Paint()..color = const Color(0xFF0D1117);
  static final _borderPaint = Paint()
    ..color = const Color(0xFF30363D)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;
  static final _dkCursor = Paint()
    ..color = const Color(0x4058A6FF)
    ..strokeWidth = 0.5;
  static final _dkTooltipBg = Paint()..color = const Color(0xCC0D1117);
  static final _dkOverlayStyle = TextStyle(
    color: const Color(0xFF58A6FF),
    fontSize: 17,
    fontFamily: 'DS-Digital',
  );
  static final _dkCoordStyle = TextStyle(
    color: const Color(0xFFC9D1D9),
    fontSize: 17,
    fontFamily: 'DS-Digital',
  );
  static final _dkInfoStyle = TextStyle(
    color: const Color(0xFFB0B8C4),
    fontSize: 16,
    fontFamily: 'DS-Digital',
  );

  // ═══ Light theme paints ═══
  static final _ltBg = Paint()..color = const Color(0xFFF6F8FA);
  static final _ltPlotBg = Paint()..color = const Color(0xFFFFFFFF);
  static final _ltBorder = Paint()
    ..color = const Color(0xFFD0D7DE)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;
  static final _ltCursor = Paint()
    ..color = const Color(0x400960DA)
    ..strokeWidth = 0.5;
  static final _ltTooltipBg = Paint()..color = const Color(0xDDF6F8FA);
  static final _ltOverlayStyle = TextStyle(
    color: const Color(0xFF0969DA),
    fontSize: 17,
    fontFamily: 'DS-Digital',
  );
  static final _ltCoordStyle = TextStyle(
    color: const Color(0xFF24292F),
    fontSize: 17,
    fontFamily: 'DS-Digital',
  );
  static final _ltInfoStyle = TextStyle(
    color: const Color(0xFF57606A),
    fontSize: 16,
    fontFamily: 'DS-Digital',
  );
  static final _miniBgLightPaint = Paint()..color = const Color(0xDDFFFFFF);

  /// Draw a dashed line between [start] and [end].
  static void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint,
      {double dash = 4.0, double gap = 4.0}) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final length = (end - start).distance;
    if (length == 0) return;
    final invLen = 1.0 / length;
    double pos = 0;
    bool draw = true;
    while (pos < length) {
      final segLen = draw ? dash : gap;
      if (draw) {
        final t1 = pos * invLen;
        final t2 = (pos + segLen).clamp(0, length) * invLen;
        canvas.drawLine(
          Offset(start.dx + dx * t1, start.dy + dy * t1),
          Offset(start.dx + dx * t2, start.dy + dy * t2),
          paint,
        );
      }
      pos += segLen;
      draw = !draw;
    }
  }

  // ── Instance fields ──────────────────────────────────────────
  final List<PlotChannel> channels;
  final double xMin, xMax, yMin, yMax;
  final Offset? mousePosition;
  final int fps;
  final int totalPoints;
  final double aaScale;
  final int globalDecimals;
  final bool shareYAxis;
  final ui.Image? gpuWaveformImage;
  final double deltaTime;
  final int viewportRefreshCount;
  final bool isDarkTheme;
  final _RenderMode renderMode;

  // P2-2: Static layer cache (background/grid/axes — rebuild only on layout/theme change)
  static ui.Picture? _staticPicture;
  static int _staticVersion = 0;

  ui.Picture? _cachedPicture;
  int _cacheVersion = 0;

  _PlotPainter({
    required this.channels,
    required this.xMin, required this.xMax,
    required this.yMin, required this.yMax,
    this.mousePosition,
    required this.fps,
    required this.totalPoints,
    this.aaScale = 1.0,
    this.globalDecimals = 3,
    this.shareYAxis = false,
    this.isDarkTheme = true,
    this.gpuWaveformImage,
    this.deltaTime = 1.0,
    required this.viewportRefreshCount,
    this.renderMode = _RenderMode.auto,
  });

  double _xToScreen(double x, double w) {
    if (xMax == xMin) return w / 2;
    return (x - xMin) / (xMax - xMin) * w;
  }

  double _yToScreen(double y, double h, double yMinCh, double yMaxCh) {
    if (yMaxCh == yMinCh) return h / 2;
    return h - (y - yMinCh) / (yMaxCh - yMinCh) * h;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // ── GPU-accelerated rendering path ──
    // If we have a GPU-rendered waveform texture, use it directly
    if (gpuWaveformImage != null) {
      // Draw background first (matches _paintInternal)
      canvas.drawRect(Rect.fromLTWH(0, 0, w, h), _bgPaint);
      
      // Calculate plot area margins (must match _paintInternal)
      final yAxisChannels = channels.where((ch) => ch.visible && ch.showYAxis).toList();
      final leftYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 0).length;
      final rightYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 1).length;
      final plotLeft = 50.0 + leftYAxes * 45.0;
      final plotBottom = 40.0;
      final plotRight = 10.0 + rightYAxes * 45.0;
      final plotTop = 10.0;
      final plotW = w - plotLeft - plotRight;
      final plotH = h - plotTop - plotBottom;

      // Draw plot area background
      canvas.drawRect(Rect.fromLTWH(plotLeft, plotTop, plotW, plotH), _plotBgPaint);

      // Draw GPU waveform image (it already contains grid, waveforms, and axes)
      final srcRect = Rect.fromLTWH(0, 0, gpuWaveformImage!.width.toDouble(), gpuWaveformImage!.height.toDouble());
      final dstRect = Rect.fromLTWH(plotLeft, plotTop, plotW, plotH);
      canvas.drawImageRect(gpuWaveformImage!, srcRect, dstRect, _gpuImagePaint);

      // Draw border
      canvas.drawRect(Rect.fromLTWH(plotLeft, plotTop, plotW, plotH), _borderPaint);

      // Draw FPS and point count overlay
      _drawOverlay(canvas, w, h, fps, totalPoints);

      // Draw crosshair if mouse is in plot area
      if (mousePosition != null) {
        final mx = mousePosition!.dx;
        final my = mousePosition!.dy;
        if (mx >= plotLeft && mx <= plotLeft + plotW &&
            my >= plotTop && my <= plotTop + plotH) {
          _drawCrosshair(canvas, mx, my, plotLeft, plotTop, plotW, plotH, w, h);
        }
      }
      return; // Skip CPU rendering
    }

    // ── Anti-aliasing via supersampling ──
    if (aaScale > 1.0) {
      final recorder = ui.PictureRecorder();
      final ssCanvas = Canvas(recorder);
      // Scale up: draw logical coordinates at aaScale× resolution.
      // Pass aaScale as the scale factor so stroke widths / dot radii
      // are compensated (divided) here — they will look right after
      // the logical-size downsample below.
      ssCanvas.scale(aaScale, aaScale);
      _paintInternal(ssCanvas, w, h, aaScale);
      final picture = recorder.endRecording();
      try {
        final image = picture.toImageSync(
          (w * aaScale).round(),
          (h * aaScale).round(),
        );
        // Scale back to logical size WITHOUT stretching — just downsample.
        final srcRect = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
        final dstRect = Rect.fromLTWH(0, 0, w, h);
        canvas.drawImageRect(image, srcRect, dstRect, _aaDownsamplePaint);
        image.dispose();
      } catch (e) {
        // Fallback: draw directly without supersampling
        _paintInternal(canvas, w, h, 1.0);
      }
      picture.dispose();
    } else {
      // 🚀 P1-A 优化：PictureRecorder 缓存
      // Content-based hash: tracks actual viewport data shape, not frame counter.
      // The counter changes every frame in real-time mode → cache was always invalid.
      int contentHash = Object.hash(xMin, xMax, yMin, yMax);
      for (final ch in channels) {
        if (ch.visible) {
          final vd = ch.viewportData;
          contentHash = Object.hash(contentHash, vd.length, ch.envelopeData.length);
          if (vd.isNotEmpty) {
            // Sample first/mid/last points (X + Y) to detect real data changes
            final mid = vd.length ~/ 2;
            contentHash = Object.hash(contentHash,
                vd.firstX, vd.firstY, vd.x(mid), vd.y(mid), vd.lastX, vd.lastY);
          }
        }
      }
      bool cacheValid = (_cachedPicture != null && _cacheVersion == contentHash);
      
      if (cacheValid) {
        canvas.drawPicture(_cachedPicture!);
      } else {
        final recorder = ui.PictureRecorder();
        final cacheCanvas = Canvas(recorder);
        _paintInternal(cacheCanvas, w, h, 1.0);
        _cachedPicture = recorder.endRecording();
        _cacheVersion = contentHash;
        canvas.drawPicture(_cachedPicture!);
      }
    }

    // ── Crosshair overlay (drawn AFTER cached/AA picture — never cached) ──
    _drawCrosshairOverlay(canvas, w, h);
  }

  void _paintInternal(Canvas canvas, double w, double h, double scale) {
    // Calculate dynamic margins based on number of Y axes
    final yAxisChannels = channels.where((ch) => ch.visible && ch.showYAxis).toList();
    final leftYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 0).length;
    final rightYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 1).length;

    final plotLeft = 50.0 + leftYAxes * 45.0;
    final plotBottom = 40.0;
    final plotRight = 10.0 + rightYAxes * 45.0;
    final plotTop = 10.0;
    final plotW = w - plotLeft - plotRight;
    final plotH = h - plotTop - plotBottom;

    if (plotW <= 0 || plotH <= 0) return;

    // P2-2: Static layer cache — rebuild only on layout/theme/axis-range change
    // Hash includes: layout geometry + theme + visible Y-axis channels state + axis ranges
    // P3-3: Added shareYAxis to hash (toggling shareYAxis changes grid rendering)
    // Memory-leak fix: round float values to 4 significant digits so that tiny
    // auto-scale fluctuations (<0.01% of range) don't invalidate the cache every frame.
    double _hashRound(double v) {
      if (v == 0.0) return 0.0;
      final abs = v.abs();
      final scale = abs < 1e-6 ? 1e12 : abs > 1e6 ? 1 : 1e6 / abs;
      return (v * scale).roundToDouble() / scale;
    }
    int staticHash = Object.hash(
      isDarkTheme,
      plotLeft, plotTop, plotW, plotH,
      _hashRound(xMin), _hashRound(xMax), _hashRound(yMin), _hashRound(yMax),
      deltaTime, globalDecimals,
      shareYAxis,
      yAxisChannels.length,
    );
    for (int ci = 0; ci < yAxisChannels.length; ci++) {
      final ch = yAxisChannels[ci];
      staticHash = Object.hash(staticHash,
        ch.visible, ch.showYAxis, ch.decimals, ch.color.toARGB32(),
        ch.autoScaleY, _hashRound(ch.yMin), _hashRound(ch.yMax),
        _hashRound(ch.yMinManual), _hashRound(ch.yMaxManual),
        ci % 2, // left/right side
      );
    }

    if (_staticPicture == null || _staticVersion != staticHash) {
      // 🩺 Memory leak fix: dispose old Picture before creating new one.
      // Skia Picture wraps native GPU resources; without explicit dispose(),
      // the old picture's resources leak until Dart GC runs (which may take
      // minutes → multi-GB accumulation). Root cause of the ~9.5GB issue.
      _staticPicture?.dispose();
      _staticPicture = null;
      final recorder = ui.PictureRecorder();
      final staticCanvas = Canvas(recorder);
      _drawStaticLayer(staticCanvas, w, h, scale,
          plotLeft, plotTop, plotW, plotH, plotRight, plotBottom);
      _staticPicture = recorder.endRecording();
      _staticVersion = staticHash;
    }

    // Draw cached static layer (background, grid, axes, labels, border)
    canvas.drawPicture(_staticPicture!);

    // ── FPS / point count overlay (dynamic, changes every frame) ──
    final infoStyle = isDarkTheme ? _dkInfoStyle : _ltInfoStyle;
    final infoTp = TextPainter(
      text: TextSpan(text: 'FPS: $fps  Pts: $totalPoints', style: infoStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    infoTp.paint(canvas, Offset(plotLeft + plotW - infoTp.width - 4, plotTop + 4));

    // ── Waveform clipping (dynamic layer) ──
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(plotLeft, plotTop, plotW, plotH));

    for (final ch in channels) {
      if (!ch.visible || ch.data.isEmpty) continue;

      final double chYMin;
      final double chYMax;
      if (shareYAxis) {
        chYMin = yMin;
        chYMax = yMax;
      } else {
        chYMin = ch.autoScaleY ? ch.yMin : ch.yMinManual;
        chYMax = ch.autoScaleY ? ch.yMax : ch.yMaxManual;
      }

      _drawChannel(canvas, ch, plotLeft, plotTop, plotW, plotH, chYMin, chYMax, scale);
    }

    canvas.restore();
  }

  /// Draws crosshair, tooltip, and per-channel values ON TOP of cached content.
  /// Called from paint() after PictureCache/AA draw — never cached.
  void _drawCrosshairOverlay(Canvas canvas, double w, double h) {
    if (mousePosition == null) return;

    // Calculate plot bounds (same as _paintInternal)
    final yAxisChannels = channels.where((ch) => ch.visible && ch.showYAxis).toList();
    final leftYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 0).length;
    final rightYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 1).length;
    final plotLeft = 50.0 + leftYAxes * 45.0;
    final plotBottom = 40.0;
    final plotRight = 10.0 + rightYAxes * 45.0;
    final plotTop = 10.0;
    final plotW = w - plotLeft - plotRight;
    final plotH = h - plotTop - plotBottom;
    if (plotW <= 0 || plotH <= 0) return;

    final mx = mousePosition!.dx;
    final my = mousePosition!.dy;
    if (mx < plotLeft || mx > plotLeft + plotW ||
        my < plotTop || my > plotTop + plotH) return;

    // ── Cursor lines ──
    final cursorPaint = isDarkTheme ? _dkCursor : _ltCursor;
    canvas.drawLine(Offset(mx, plotTop), Offset(mx, plotTop + plotH), cursorPaint);
    canvas.drawLine(Offset(plotLeft, my), Offset(plotLeft + plotW, my), cursorPaint);

    // ── Coordinate tooltip ──
    final dataX = xMin + (mx - plotLeft) / plotW * (xMax - xMin);
    final dataY = yMax - (my - plotTop) / plotH * (yMax - yMin);
    int maxDecimals = 3;
    for (final ch in channels) {
      if (ch.visible && ch.decimals > maxDecimals) maxDecimals = ch.decimals;
    }
    final coordText = 'X: ${dataX.toStringAsFixed(maxDecimals)}  Y: ${dataY.toStringAsFixed(maxDecimals)}';
    final tp = _crosshairTp
      ..text = TextSpan(text: coordText, style: isDarkTheme ? _dkCoordStyle : _ltCoordStyle)
      ..layout();
    var tx = mx + 12;
    var ty = my - tp.height - 8;
    if (tx + tp.width > plotLeft + plotW) tx = mx - tp.width - 8;
    if (ty < plotTop) ty = my + 8;
    canvas.drawRect(
      Rect.fromLTWH(tx - 2, ty - 1, tp.width + 4, tp.height + 2),
      isDarkTheme ? _miniBgPaint : _miniBgLightPaint,
    );
    tp.paint(canvas, Offset(tx, ty));

    // ── Per-channel values at cursor X ──
    double yOffset = ty + tp.height + 4;
    for (final ch in channels) {
      if (!ch.visible || ch.data.isEmpty) continue;
      final val = _getValueAtX(ch, dataX);
      if (val != null) {
        final chText = '${ch.channelName}: ${val.toStringAsFixed(ch.decimals)}';
        final ctp = TextPainter(
          text: TextSpan(text: chText, style: TextStyle(
            color: ch.color,
            fontSize: 16,
            fontFamily: 'DS-Digital',
          )),
          textDirection: TextDirection.ltr,
        )..layout();
        if (yOffset + ctp.height > plotTop + plotH) break;
        ctp.paint(canvas, Offset(tx, yOffset));
        yOffset += ctp.height + 2;
      }
    }
  }

  /// Draws the static (non-waveform) layer: background, grid, axes, labels, border, info.
  /// Cached via _staticPicture / _staticVersion since these only change on zoom/pan/theme.
  void _drawStaticLayer(Canvas canvas, double w, double h, double scale,
      double plotLeft, double plotTop, double plotW, double plotH,
      double plotRight, double plotBottom) {
    // ── Background ──
    final bg = isDarkTheme ? _dkBg : _ltBg;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), bg);

    // ── Plot area background ──
    final plotBg = isDarkTheme ? _dkPlotBg : _ltPlotBg;
    canvas.drawRect(Rect.fromLTWH(plotLeft, plotTop, plotW, plotH), plotBg);

    // ── Grid lines (dashed) ──
    final xTicks = _niceTicks(xMin, xMax, 10);
    for (final tick in xTicks) {
      final sx = _xToScreen(tick, plotW) + plotLeft;
      if (sx < plotLeft || sx > plotLeft + plotW) continue;
      _drawDashedLine(canvas, Offset(sx, plotTop), Offset(sx, plotTop + plotH), _gridPaint);
    }

    final yTicks = _niceTicks(yMin, yMax, 8);
    for (final tick in yTicks) {
      final sy = _yToScreen(tick, plotH, yMin, yMax) + plotTop;
      if (sy < plotTop || sy > plotTop + plotH) continue;
      _drawDashedLine(canvas, Offset(plotLeft, sy), Offset(plotLeft + plotW, sy), _gridPaint);
    }

    // Zero line
    final zeroY = _yToScreen(0, plotH, yMin, yMax) + plotTop;
    if (zeroY >= plotTop && zeroY <= plotTop + plotH) {
      canvas.drawLine(Offset(plotLeft, zeroY), Offset(plotLeft + plotW, zeroY), _zeroPaint);
    }

    // ── X axis labels ──
    final labelStyle = TextStyle(
      color: const Color(0xFF8B949E),
      fontSize: 16,
      fontFamily: 'DS-Digital',
    );
    for (final tick in xTicks) {
      final sx = _xToScreen(tick, plotW) + plotLeft;
      if (sx < plotLeft || sx > plotLeft + plotW) continue;
      final tp = TextPainter(
        text: TextSpan(text: _formatXTick(tick, deltaTime), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(sx - tp.width / 2, h - plotBottom + 4));
    }

    // ── Per-channel Y axis labels ──
    final yAxisChannels = channels.where((ch) => ch.visible && ch.showYAxis).toList();
    if (yAxisChannels.isEmpty) {
      for (final tick in yTicks) {
        final sy = _yToScreen(tick, plotH, yMin, yMax) + plotTop;
        if (sy < plotTop || sy > plotTop + plotH) continue;
        final tp = TextPainter(
          text: TextSpan(text: _formatTick(tick, globalDecimals), style: _gridTextStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(plotLeft - tp.width - 4, sy - tp.height / 2));
      }
    } else if (yAxisChannels.length == 1) {
      for (final tick in yTicks) {
        final sy = _yToScreen(tick, plotH, yMin, yMax) + plotTop;
        if (sy < plotTop || sy > plotTop + plotH) continue;
        final tp = TextPainter(
          text: TextSpan(text: tick.toStringAsFixed(yAxisChannels.first.decimals), style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(plotLeft - tp.width - 4, sy - tp.height / 2));
      }
    } else {
      for (int ci = 0; ci < yAxisChannels.length; ci++) {
        final ch = yAxisChannels[ci];
        final chYMin = ch.autoScaleY ? ch.yMin : ch.yMinManual;
        final chYMax = ch.autoScaleY ? ch.yMax : ch.yMaxManual;
        final chTicks = _niceTicks(chYMin, chYMax, 6);
        final chLabelStyle = TextStyle(
          color: ch.color,
          fontSize: 15,
          fontFamily: 'DS-Digital',
        );
        final isLeft = ci % 2 == 0;
        final leftIdx = (ci ~/ 2);
        final rightIdx = (ci ~/ 2);
        for (final tick in chTicks) {
          final sy = _yToScreen(tick, plotH, chYMin, chYMax) + plotTop;
          if (sy < plotTop || sy > plotTop + plotH) continue;
          final tickText = tick.toStringAsFixed(ch.decimals);
          final tp = TextPainter(
            text: TextSpan(text: tickText, style: chLabelStyle),
            textDirection: TextDirection.ltr,
          )..layout();
          if (isLeft) {
            final xOffset = plotLeft - tp.width - 4 - leftIdx * 45;
            tp.paint(canvas, Offset(xOffset.clamp(2, double.maxFinite), sy - tp.height / 2));
          } else {
            final xOffset = plotLeft + plotW + 4 + rightIdx * 45;
            tp.paint(canvas, Offset(xOffset, sy - tp.height / 2));
          }
        }
        final axisPaint = Paint()
          ..color = ch.color.withValues(alpha: 0.5)
          ..strokeWidth = 1.0;
        if (isLeft) {
          final x = plotLeft - leftIdx * 45 - 2;
          canvas.drawLine(Offset(x, plotTop), Offset(x, plotTop + plotH), axisPaint);
        } else {
          final x = plotLeft + plotW + rightIdx * 45 + 2;
          canvas.drawLine(Offset(x, plotTop), Offset(x, plotTop + plotH), axisPaint);
        }
      }
    }

    // ── Border ──
    final borderPaint = isDarkTheme ? _dkBorder : _ltBorder;
    canvas.drawRect(Rect.fromLTWH(plotLeft, plotTop, plotW, plotH), borderPaint);

  }
  void _drawChannel(Canvas canvas, PlotChannel ch, double ox, double oy, double w, double h, double chYMin, double chYMax, double scale) {
    // P0-2: Use GC-free _DataBuf (viewportData is always populated by envelope read)
    final data = ch.viewportData;
    if (data.isEmpty) return;

    // Use per-channel Y transform
    double yTransform(double y) {
      if (chYMax == chYMin) return h / 2;
      return h - (y - chYMin) / (chYMax - chYMin) * h;
    }

    // ── Trace mode: raw polyline, no envelope ──
    // When zoomed in deeply (few samples covering many pixels), envelope bands
    // produce ugly wide vertical bars. A simple polyline is cleaner.
    final samplesPerPixel = data.length / w;
    final useTrace = renderMode == _RenderMode.trace ||
        (renderMode == _RenderMode.auto && samplesPerPixel < ENVELOPE_THRESHOLD);
    if (useTrace) {
      _drawTrace(canvas, ch, data, ox, oy, w, h, yTransform);
      return;
    }

    // 🚀 Phase B: Render envelope fill (semi-transparent min-max band) before foreground line
    final envData = ch.envelopeData;
    if (envData.isNotEmpty && envData.length >= 2) {
      _drawEnvelope(canvas, ch, envData, ox, oy, w, h, yTransform);
      _drawMinMaxLines(canvas, ch, envData, ox, oy, w, h, yTransform);
    }

    // P4: Gap markers — shaded regions at temporal discontinuities
    _drawGapMarkers(canvas, ch, data, ox, oy, w, h, yTransform);

    switch (ch.lineStyle) {
      case LineStyle.dot:
        _drawDots(canvas, ch, data, ox, oy, w, h, yTransform, scale);
        break;
      case LineStyle.dotLine:
        _drawDotLine(canvas, ch, data, ox, oy, w, h, yTransform, scale);
        break;
      case LineStyle.line:
        _drawLine(canvas, ch, data, ox, oy, w, h, yTransform, scale);
        break;
      case LineStyle.filled:
        _drawFilled(canvas, ch, data, ox, oy, w, h, yTransform, scale, chYMin, chYMax);
        break;
    }
  }

  // 数据抽取：将大量数据点减少到适合屏幕显示的密度
  // 🚀 性能优化：每个像素bucket只保留1个最有代表性的点
void _drawDots(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale) {
    if (data.isEmpty) return;
    
    // 🚀 性能优化：使用Path批量绘制，减少draw call次数
    final paint = Paint()
      ..color = ch.color
      ..strokeWidth = ch.lineWidth
      ..strokeCap = StrokeCap.round;
    
    // 🚀 P1-B 优化：批量绘制（替代 250K 次 drawCircle 调用）
    // drawRawPoints 需要扁平的 Float32List: [x1,y1, x2,y2, ...]
    final points = Float32List(data.length * 2);
    for (int i = 0; i < data.length; i++) {
      // pt inlined (P0-2 _DataBuf)
      points[i * 2] = _xToScreen(data.x(i), w) + ox;
      points[i * 2 + 1] = yTransform(data.y(i)) + oy;
    }
    canvas.drawRawPoints(ui.PointMode.points, points, paint);
  }

  // 🚀 Phase B: Render envelope fill background (semi-transparent min-max band)
  void _drawEnvelope(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform) {
    if (data.length < 4) return; // need ≥2 buckets (4 points: min0,max0,min1,max1)

    // Envelope data format: [x0,ymin0], [x0,ymax0], [x1,ymin1], [x1,ymax1], ...
    // Build polygon: top edge (ymax) forward, bottom edge (ymin) reverse
    // drawRawPoints(PointMode.polygon) auto-closes → no explicit close needed
    final n = data.length;
    if (_envBuf == null || _envBuf!.length < n * 2) {
      _envBuf = Float32List(n * 2);
    }
    final buf = _envBuf!;
    int pi = 0;
    // Top edge: yMax values (odd indices: 1, 3, 5, ...)
    for (int i = 1; i < n; i += 2) {
      buf[pi++] = _xToScreen(data.x(i), w) + ox;
      buf[pi++] = yTransform(data.y(i)) + oy;
    }
    // Bottom edge reverse: yMin values (even indices: ..., 4, 2, 0)
    for (int i = n - 2; i >= 0; i -= 2) {
      buf[pi++] = _xToScreen(data.x(i), w) + ox;
      buf[pi++] = yTransform(data.y(i)) + oy;
    }

    _envelopeFillPaint.color = ch.color.withValues(alpha: 0.25);
    canvas.drawRawPoints(ui.PointMode.polygon, buf, _envelopeFillPaint);
  }

  // 🚀 P1-2: Oscilloscope-style min-max vertical lines per bucket.
  // Draws a thin vertical line from yMin to yMax for each downsampled time bucket.
  // Combined with envelope fill, this gives the classic oscilloscope density view:
  //   envelope fill → wide band (25% alpha)
  //   min-max lines → sharp vertical bars (40% alpha, provides structure)
  //   avg line     → foreground trace (100% alpha, signal path)
  void _drawMinMaxLines(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform) {
    if (data.length < 2) return;

    // PointMode.lines: each 2 points = 1 line segment
    // data format: [x0,ymin0, x0,ymax0, x1,ymin1, x1,ymax1, ...]
    // For each bucket (even i = min, odd i+1 = max, same x):
    //   draw line (x, yMin) → (x, yMax)
    final nSegs = data.length ~/ 2;  // one segment per bucket
    final reqLen = nSegs * 4;        // 4 floats per segment (start.xy + end.xy)
    if (_minMaxBuf == null || _minMaxBuf!.length < reqLen) {
      _minMaxBuf = Float32List(reqLen);
    }
    final buf = _minMaxBuf!;
    int pi = 0;
    for (int i = 0; i < data.length; i += 2) {
      if (i + 1 >= data.length) break;
      final sx = _xToScreen(data.x(i), w) + ox;  // x same for min and max
      final syMin = yTransform(data.y(i)) + oy;
      final syMax = yTransform(data.y(i + 1)) + oy;
      buf[pi++] = sx;
      buf[pi++] = syMin;
      buf[pi++] = sx;
      buf[pi++] = syMax;
    }

    _minMaxLinePaint.color = ch.color.withValues(alpha: 0.40);
    canvas.drawRawPoints(ui.PointMode.lines, buf, _minMaxLinePaint);
  }

  /// P4: Draw gap markers where data has temporal discontinuities.
  /// Gaps are detected when the time interval between consecutive viewport points
  /// exceeds 3× the expected bucket interval. Markers appear as thin shaded columns.
  void _drawGapMarkers(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform) {
    if (data.length < 2) return;

    final expectedInterval = (data.lastX - data.firstX) / (data.length - 1);
    if (expectedInterval <= 0) return;

    final gapThreshold = expectedInterval * 3.0;

    // Reuse static paint, update color per channel
    _gapMarkerPaint.color = ch.color.withValues(alpha: 0.18);
    _gapMarkerPaint.strokeWidth = 2.5;

    for (int i = 1; i < data.length; i++) {
      final dt = data.x(i) - data.x(i - 1);
      if (dt > gapThreshold) {
        // Gap detected between i-1 and i: draw shaded column between the two X positions
        final x1 = _xToScreen(data.x(i - 1), w) + ox;
        final x2 = _xToScreen(data.x(i), w) + ox;
        if (x2 - x1 < 4) continue; // too narrow to see

        canvas.drawRect(
          Rect.fromLTWH(x1 + 1, oy, x2 - x1 - 2, h),
          _gapMarkerPaint,
        );

        // Draw vertical dashed edges at gap boundaries
        final edgeW = 1.0;
        _gapEdgePaint.color = ch.color.withValues(alpha: 0.35);
        _gapEdgePaint.strokeWidth = edgeW;
        canvas.drawLine(Offset(x1, oy), Offset(x1, oy + h), _gapEdgePaint);
        canvas.drawLine(Offset(x2, oy), Offset(x2, oy + h), _gapEdgePaint);
      }
    }
  }

  void _drawDotLine(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale) {
    if (data.isEmpty) return;

    // Reuse/resize buffer (2 floats per point: x, y)
    final n = data.length;
    if (_lineBuf == null || _lineBuf!.length < n * 2) {
      _lineBuf = Float32List(n * 2);
    }
    final buf = _lineBuf!;
    for (int i = 0; i < n; i++) {
      buf[i * 2] = _xToScreen(data.x(i), w) + ox;
      buf[i * 2 + 1] = yTransform(data.y(i)) + oy;
    }
    // Semi-transparent line
    _dotLinePaint.color = ch.color.withValues(alpha: 0.5);
    _dotLinePaint.strokeWidth = ch.lineWidth;
    canvas.drawRawPoints(ui.PointMode.polygon, buf, _dotLinePaint);

    // Dots on top (same buffer, PointMode.points)
    _dotPointPaint.color = ch.color;
    _dotPointPaint.strokeWidth = 2.5;
    _dotPointPaint.strokeCap = StrokeCap.round;
    canvas.drawRawPoints(ui.PointMode.points, buf, _dotPointPaint);
  }

  void _drawLine(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale) {
    if (data.isEmpty) return;

    // Reuse static Paint (update mutable fields only)
    _linePaint.color = ch.color;
    _linePaint.strokeWidth = ch.lineWidth;

    // Reuse/resize Float32List buffer (2 floats per point: x, y)
    final n = data.length;
    if (_lineBuf == null || _lineBuf!.length < n * 2) {
      _lineBuf = Float32List(n * 2);
    }
    final buf = _lineBuf!;
    for (int i = 0; i < n; i++) {
      buf[i * 2] = _xToScreen(data.x(i), w) + ox;
      buf[i * 2 + 1] = yTransform(data.y(i)) + oy;
    }
    canvas.drawRawPoints(ui.PointMode.polygon, buf, _linePaint);
  }

  // ── Trace mode: raw sample polyline (no envelope, no downsampling) ──
  // Used when samplesPerPixel < ENVELOPE_THRESHOLD (zoomed in).
  void _drawTrace(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform) {
    if (data.isEmpty) return;

    _linePaint.color = ch.color;
    _linePaint.strokeWidth = ch.lineWidth;

    // Use Path (non-closing polyline) instead of PointMode.polygon.
    // PointMode.polygon auto-closes the last→first point, creating
    // visible diagonal artifacts (same root cause as the 3-dark-lines bug).
    final path = Path();
    final sx = _xToScreen(data.x(0), w) + ox;
    final sy = yTransform(data.y(0)) + oy;
    path.moveTo(sx, sy);
    for (int i = 1; i < data.length; i++) {
      path.lineTo(_xToScreen(data.x(i), w) + ox, yTransform(data.y(i)) + oy);
    }
    canvas.drawPath(path, _linePaint);
  }

  void _drawFilled(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale, double chYMin, double chYMax) {
    if (data.length < 2) return;

    // Zero line position for this channel's Y range
    final zeroY = yTransform(0) + oy;

    // Calculate fill bounds
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (int i = 0; i < data.length; i++) {
      final sy = yTransform(data.y(i)) + oy;
      if (sy < minY) minY = sy;
      if (sy > maxY) maxY = sy;
    }
    final fillTop = min(minY, zeroY);
    final fillBottom = max(maxY, zeroY);

    // Gradient from waveform (opaque) to zero (transparent)
    final rect = Rect.fromLTWH(ox, fillTop, w, fillBottom - fillTop);
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        ch.color.withValues(alpha: 0.4),
        ch.color.withValues(alpha: 0.05),
        ch.color.withValues(alpha: 0.4),
      ],
      stops: const [0.0, 0.5, 1.0],
    );

    final fillPaint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.fill;

    // Build fill path: along waveform then back along zero
    final path = Path();
    path.moveTo(_xToScreen(data.x(0), w) + ox, zeroY);
    for (int i = 0; i < data.length; i++) {
      final sx = _xToScreen(data.x(i), w) + ox;
      final sy = yTransform(data.y(i)) + oy;
      path.lineTo(sx, sy);
    }
    path.lineTo(_xToScreen(data.lastX, w) + ox, zeroY);
    path.close();
    canvas.drawPath(path, fillPaint);

    // Also draw the line on top
    _drawLine(canvas, ch, data, ox, oy, w, h, yTransform, scale);
  }

  double? _getValueAtX(PlotChannel ch, double targetX) {
    if (ch.data.isEmpty) return null;
    int lo = 0, hi = ch.data.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (ch.data[mid].x < targetX) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0 && (ch.data[lo].x - targetX).abs() > (ch.data[lo - 1].x - targetX).abs()) {
      lo--;
    }
    return ch.data[lo].y;
  }

  List<double> _niceTicks(double min, double max, int targetCount) {
    if (min == max) return [min];
    final range = max - min;
    final rawStep = range / targetCount;
    final magnitude = pow(10, (log(rawStep) / ln10).floor()).toDouble();
    final normalized = rawStep / magnitude;

    double niceStep;
    if (normalized <= 1.5) niceStep = magnitude;
    else if (normalized <= 3.5) niceStep = 2 * magnitude;
    else if (normalized <= 7.5) niceStep = 5 * magnitude;
    else niceStep = 10 * magnitude;

    // Guard: niceStep should never be 0, but handle numerically
    if (niceStep <= 0) return [min, max];

    final ticks = <double>[];
    var tick = (min / niceStep).ceil() * niceStep;
    while (tick <= max) {
      ticks.add(tick);
      tick += niceStep;
    }
    return ticks;
  }

  /// X轴刻度格式化：显示整数点号
  String _formatXTick(double val, [double deltaTime = 1.0]) {
    // X values are sample indices, multiply by Δt to show time in ms
    final timeMs = val * (deltaTime > 0 ? deltaTime : 1.0);
    if (timeMs.abs() >= 1000) {
      return '${(timeMs / 1000).toStringAsFixed(2)}s';
    } else if (timeMs.abs() >= 1) {
      return '${timeMs.toStringAsFixed(1)}ms';
    } else {
      return '${timeMs.toStringAsFixed(3)}ms';
    }
  }

  String _formatTick(double val, [int decimals = 3]) {
    if (val.abs() >= 1000) return val.toStringAsFixed(0);
    if (val.abs() >= 1) return val.toStringAsFixed(decimals.clamp(0, 4));
    if (val.abs() >= 0.01) return val.toStringAsFixed(decimals.clamp(2, 6));
    return val.toStringAsExponential(2);
  }

  @override
  bool shouldRepaint(covariant _PlotPainter oldDelegate) {
    // 🚀 Mouse/cursor moved? Always repaint (instant crosshair feedback)
    if (mousePosition != oldDelegate.mousePosition) return true;

    // 🚀 Render mode changed? Repaint needed
    if (renderMode != oldDelegate.renderMode) return true;

    // 🚀 Channel config changed (decimals, showYAxis, etc)? Repaint needed
    if (channels.length != oldDelegate.channels.length) return true;
    for (int i = 0; i < channels.length; i++) {
      final a = channels[i];
      final b = oldDelegate.channels[i];
      if (a.visible != b.visible ||
          a.color != b.color ||
          a.lineStyle != b.lineStyle ||
          a.decimals != b.decimals ||
          a.showYAxis != b.showYAxis) {
        return true;
      }
    }

    // 🔧 P3-B revisited: viewportRefreshCount is incremented whenever
    // _refreshViewportData() runs → new viewportData is available → MUST repaint.
    // Previously this was a negative check (return false when equal but skip when
    // different), which meant xMin/xMax/yMin/yMax changes were sometimes missed.
    if (viewportRefreshCount != oldDelegate.viewportRefreshCount) {
      return true; // Viewport data was refreshed — always repaint
    }
    
    // 🚀 If viewport counter hasn't changed, check whether coordinates moved
    // (scrollbar drag / pan / zoom can change coordinates without refreshing viewport data).
    if (xMin != oldDelegate.xMin || xMax != oldDelegate.xMax ||
        yMin != oldDelegate.yMin || yMax != oldDelegate.yMax) {
      return true;
    }
    
    // GPU texture changed?
    if (gpuWaveformImage != oldDelegate.gpuWaveformImage) return true;
    
    // Only repaint when something actually changed (rare fallback)
    if (mousePosition != oldDelegate.mousePosition ||
        fps != oldDelegate.fps ||
        totalPoints != oldDelegate.totalPoints ||
        aaScale != oldDelegate.aaScale ||
        globalDecimals != oldDelegate.globalDecimals ||
        shareYAxis != oldDelegate.shareYAxis ||
        isDarkTheme != oldDelegate.isDarkTheme) {
      return true;
    }
    return false;
  }

  void _drawOverlay(Canvas canvas, double w, double h, int fps, int totalPoints) {
    final tp = _overlayTp
      ..text = TextSpan(text: 'FPS: $fps | Points: $totalPoints', style: isDarkTheme ? _dkOverlayStyle : _ltOverlayStyle)
      ..layout();
    tp.paint(canvas, Offset(w - tp.width - 8, 8));
  }

  void _drawCrosshair(Canvas canvas, double mx, double my,
      double plotLeft, double plotTop, double plotW, double plotH, double w, double h) {
    final cursorPaint = isDarkTheme ? _dkCursor : _ltCursor;
    canvas.drawLine(Offset(mx, plotTop), Offset(mx, plotTop + plotH), cursorPaint);
    canvas.drawLine(Offset(plotLeft, my), Offset(plotLeft + plotW, my), cursorPaint);

    // Show coordinates
    final dataX = xMin + (mx - plotLeft) / plotW * (xMax - xMin);
    final dataY = yMax - (my - plotTop) / plotH * (yMax - yMin);

    // Find max decimals across channels for alignment
    int maxDecimals = 3;
    for (final ch in channels) {
      if (ch.visible && ch.decimals > maxDecimals) maxDecimals = ch.decimals;
    }

    final coordText = 'X: ${dataX.toStringAsFixed(maxDecimals)}  Y: ${dataY.toStringAsFixed(maxDecimals)}';
    final tp = _crosshairTp
      ..text = TextSpan(text: coordText, style: isDarkTheme ? _dkCoordStyle : _ltCoordStyle)
      ..layout();

    // Position tooltip near cursor but avoid clipping
    double tx = mx + 10;
    double ty = my - 20;
    if (tx + tp.width > w - 10) tx = mx - tp.width - 10;
    if (ty < 10) ty = my + 20;

    // Background for tooltip
    canvas.drawRect(
      Rect.fromLTWH(tx - 4, ty - 2, tp.width + 8, tp.height + 4),
      isDarkTheme ? _dkTooltipBg : _ltTooltipBg,
    );
    tp.paint(canvas, Offset(tx, ty));
  }
}





