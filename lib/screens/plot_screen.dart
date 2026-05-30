import 'dart:math';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart';
import 'package:file_picker/file_picker.dart';
import '../app/theme.dart';
import '../src/rust/api/device_api.dart';
import '../src/rust/api/debug_api.dart';
import '../src/rust/api/plot_api.dart';
import '../src/rust/frb_generated.dart';

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
  List<_DataPoint> data; // Full data (for scale/cursor)
  List<_DataPoint> viewportData; // Decimated viewport data (for painting)
  double currentValue;
  double yMin; // Per-channel Y range
  double yMax;
  double yMinManual; // User-specified Y range (if not auto)
  double yMaxManual;
  bool autoScaleY; // Per-channel auto-scale
  String plotGroupId; // Which PlotGroup this channel belongs to

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
    List<_DataPoint>? viewportData,
    this.currentValue = 0.0,
    this.yMin = 0,
    this.yMax = 1,
    this.yMinManual = -1,
    this.yMaxManual = 1,
    this.autoScaleY = true,
    this.plotGroupId = 'default',
  }) : data = data ?? [],
       viewportData = viewportData ?? [];

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
  );
}

class _DataPoint {
  final double x;
  final double y;
  _DataPoint(this.x, this.y);
}

/// Scrollbar drag mode
enum _ScrollbarDrag { none, thumb, leftEdge, rightEdge }

/// Min visible X range (prevents zooming to zero)
const _minVisibleRange = 0.01;

class PlotScreen extends StatefulWidget {
  const PlotScreen({super.key});

  @override
  State<PlotScreen> createState() => _PlotScreenState();
}

class _PlotScreenState extends State<PlotScreen> with SingleTickerProviderStateMixin {
  // ── Data source ──
  bool _useRealData = false; // false = demo, true = real device
  Timer? _realDataTimer;
  
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
  double _screenWidth = 800.0;       // plot area width for viewport decimation

  // ── Scrollbar drag state ──
  _ScrollbarDrag _scrollbarDrag = _ScrollbarDrag.none;
  double _scrollbarDragStartX = 0;
  double _scrollbarDragStartXMin = 0;
  double _scrollbarDragStartXMax = 10;

  // ── Protocol parser ──
  bool _autoAddChannels = true; // Auto-add channels from received data

  // ── Display state ──
  bool _isPlaying = true;
  int _fps = 0;
  int _totalPoints = 0;
  DateTime _lastFpsTime = DateTime.now();
  int _fpsFrameCount = 0;

  // ── GPU state ──
  bool _gpuInitialized = false;
  bool _useGpuAcceleration = true;
  ui.Image? _gpuWaveformImage;
  bool _isGpuRendering = false;

  // ── Interaction state ──
  Offset? _mousePosition;
  bool _isDragging = false;
  Offset? _dragStart;
  double _dragStartXMin = 0;
  double _dragStartXMax = 10;
  double _dragStartYMin = -1;
  double _dragStartYMax = 1;
  // Drag state for scroll-mode viewport (X-axis only drag in scroll mode)
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

  // ── Demo ──
  double _demoPhase = 0;  // Demo phase for waveform generation (time in seconds)
  int _sampleIndex = 0;  // Sample index counter for X-axis (displayed as index * deltaTime)
  Timer? _demoTimer;

  // ── Channel colors pool ──
  static const _channelColors = [
    Color(0xFF58A6FF),
    Color(0xFF3FB950),
    Color(0xFFD29922),
    Color(0xFFF85149),
    Color(0xFFBC8CFF),
    Color(0xFF39D2C0),
    Color(0xFFFF7B72),
    Color(0xFF79C0FF),
    Color(0xFF56D364),
    Color(0xFFFFA657),
    Color(0xFFFFC680),
    Color(0xFFA5D6FF),
  ];

  // ── Config persistence ──
  static String get _configPath {
    final appData = Platform.environment['APPDATA'] ?? '';
    return '$appData\\VCR\\plot_config.json';
  }

  @override
  void initState() {
    super.initState();
    print('🧪 [DEBUG] initState() 开始');
    _ticker = createTicker(_onTick);
    _ticker.start();
    _initDemoChannels();
    _startDemoData();
    _loadConfig();
    // Apply buffer size to Rust immediately when page loads
    try {
      RustLib.instance.api.crateApiPlotApiPlotSetBufferCapacity(capacity: BigInt.from(_maxPoints));
    } catch (_) {}
    
    // 启动真实数据定时器（方案 B: 分离数据轮询和 UI 更新）
    _fetchTimer = Timer.periodic(const Duration(milliseconds: 20), (_) => _fetchRealData());
    _realDataTimer = Timer.periodic(const Duration(milliseconds: 33), (_) => _updateRealDataUI());
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
    // 启动 Rust 独立线程接收数据（方案3）
    try {
      RustLib.instance.api.crateApiDataReceiverStartDataReceiver();
      print('✅ 数据接收线程启动成功');
    } catch (e) {
      print('❌ 数据接收线程启动失败: $e');
    }
    // Load Flutter log settings asynchronously (don't block initState)
    _loadFlutterLogSettings();
  }

  void _initDemoChannels() {
    final devices = listDevices();
    final deviceName = devices.isNotEmpty ? devices.first.name : 'Demo';
    _channels = [
      PlotChannel(
        deviceId: 'demo_ch1', deviceName: deviceName, channelName: 'Voltage',
        color: _channelColors[0], decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch2', deviceName: deviceName, channelName: 'Current',
        color: _channelColors[1], decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch3', deviceName: deviceName, channelName: 'Power',
        color: _channelColors[2], decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch4', deviceName: deviceName, channelName: 'Temp',
        color: _channelColors[3], decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch5', deviceName: deviceName, channelName: 'Pressure',
        color: _channelColors[4], decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch6', deviceName: deviceName, channelName: 'Flow',
        color: _channelColors[5], decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch7', deviceName: deviceName, channelName: 'Torque',
        color: _channelColors[6], decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch8', deviceName: deviceName, channelName: 'RPM',
        color: _channelColors[7], decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      // Fourier square wave approximations (5+ terms)
      PlotChannel(
        deviceId: 'demo_ch9', deviceName: deviceName, channelName: 'Square_1Hz',
        color: _channelColors[8], decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch10', deviceName: deviceName, channelName: 'Square_3Hz',
        color: _channelColors[9], decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch11', deviceName: deviceName, channelName: 'PWM_2Hz',
        color: _channelColors[10], decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
      ),
      PlotChannel(
        deviceId: 'demo_ch12', deviceName: deviceName, channelName: 'Step_0.5Hz',
        color: _channelColors[11], decimals: 3, lineStyle: LineStyle.line, showYAxis: false,
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

  // 帧率控制：防止setState调用过于频繁
  DateTime _lastDemoUpdate = DateTime.now();
  
  // 每通道独立的样本索引，确保X值连续
  final List<int> _demoSampleIndices = <int>[];
  
  void _startDemoData() {
    print('🧪 [DEBUG] _startDemoData() 开始');
    _debugLog('[START] _startDemoData called, _useRealData=$_useRealData, _isPlaying=$_isPlaying, _maxPoints=$_maxPoints');
    _debugLog('[START] _demoChannels.length=${_demoChannels.length}, _realChannels.length=${_realChannels.length}');
    _demoTimer?.cancel();
    
    // 初始化每通道样本索引
    _demoSampleIndices.clear();
    for (int i = 0; i < _channels.length; i++) {
      _demoSampleIndices.add(0);
    }
    
    final dt = 0.008 / _demoSubSamples; // sub-sample interval
    _demoTimer = Timer.periodic(const Duration(milliseconds: 8), (_) {  // ~120fps timer
      if (!mounted || !_isPlaying) return;
      
      // 限制UI更新频率：每50ms最多更新一次界面（约20fps）
      final now = DateTime.now();
      final shouldUpdateUI = now.difference(_lastDemoUpdate).inMilliseconds >= 50;
      final rng = Random();
      
      // Generate sub-samples per tick for smooth curves
      // Performance: use append (O(1)) + relative X offset to avoid O(n) renumbering
      for (int s = 0; s < _demoSubSamples; s++) {
        _demoPhase += dt;
        final t = _demoPhase;
        for (int i = 0; i < _channels.length; i++) {
          final noise = 0.05 * (rng.nextDouble() - 0.5);
          final val = _demoEval(i, t, noise);
          // Append at end: data[0]=oldest, data[last]=newest
          // Store per-channel sample index (continuous); displayed X = pt.x - data.last.x (offset from newest)
          _channels[i].data.add(_DataPoint(_demoSampleIndices[i].toDouble(), val));
          _channels[i].currentValue = val;
          _demoSampleIndices[i]++;
        }
      }
      // Trim: only when data exceeds _maxPoints by a safe margin to avoid O(n) per tick.
      // Using sublist() on a large list is O(n) — we defer trimming until 110% capacity.
      if (_channels.isNotEmpty && _channels.first.data.length > _maxPoints * 11 ~/ 10) {
        _debugLog('[TRIM] Trimming data: first.data.length=${_channels.first.data.length}, _maxPoints=$_maxPoints');
        for (final ch in _channels) {
          if (ch.data.length > _maxPoints) {
            ch.data = ch.data.sublist(ch.data.length - _maxPoints);
          }
        }
      }
      _totalPoints = _channels.fold(0, (sum, ch) => sum + ch.data.length);
      // 每100帧输出一次调试信息
      if (_sampleIndex % 100 == 0) {
        _debugLog('[TICK] sampleIndex=$_sampleIndex, totalPoints=$_totalPoints, first.ch.data.length=${_channels.isNotEmpty ? _channels.first.data.length : 0}');
      }

      if (_scrollMode) {
        // Auto-track: always show the latest data at the right edge (x=0)
        _xMax = 0.0;
        _xMin = -_effectiveScrollWindowWidth;
        _scrollMinTime = _xMin;
      } else {
        if (_autoScaleX) _fitXAxis();
        if (_autoScaleY) _fitYAxis();
      }
      
      // 根据帧率控制决定是否更新UI
      if (shouldUpdateUI) {
        _lastDemoUpdate = now;
        _refreshViewportData(); // ← 修复：timer回调中刷新viewportData，否则绘制回退到ch.data(250K点)导致卡顿
        setState(() {});
      }
    });
  }

  // ── Helper: binary search for viewport data ──
  // Returns first index where data[i].x >= target.
  // If no such index, returns data.length.
  int _binarySearch(List<_DataPoint> data, double target) {
    int lo = 0, hi = data.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (data[mid].x < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  // Debug log to file with level control
  // Levels: trace=0, debug=1, info=2, warn=3, error=4, off=5
  int _flutterLogLevel = 1; // default: debug
  String _flutterLogPath = 'debug_log.txt';
  bool _flutterFileLogging = true;

  void _debugLog(String msg, {int level = 1}) {
    // Check if logging is enabled and level is sufficient
    if (!_flutterFileLogging || level < _flutterLogLevel) return;
    
    try {
      final file = File(_flutterLogPath);
      final levelStr = ['TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR'][level.clamp(0, 4)];
      file.writeAsStringSync('${DateTime.now()} [$levelStr] $msg\n', mode: FileMode.append);
    } catch (_) {
      // Ignore file write errors
    }
  }

  /// Refresh viewportData for all channels using current _xMin/_xMax.
  /// Called after scrollbar drag, zoom, or any viewport change.
  void _refreshViewportData() {
    if (_xMin == _xMax || _screenWidth <= 0) return;
    final maxPts = (_screenWidth * 2).round().clamp(500, 4000);
    // 调试：打印关键参数
    if (_channels.isNotEmpty && _channels.first.data.isNotEmpty) {
      _debugLog('[DEBUG] _refreshViewportData: _xMin=$_xMin _xMax=$_xMax _screenWidth=$_screenWidth maxPts=$maxPts');
      _debugLog('[DEBUG]   first ch.data.length=${_channels.first.data.length} newestAbsX=${_channels.first.data.last.x}');
    }
    for (final ch in _channels) {
      if (!ch.visible) {
        ch.viewportData = [];
        continue;
      }

      // 统一处理 Demo 和 Real 模式的 viewportData 构建
      // 两种模式都使用相同的坐标系统：X 值是相对索引（-N+1 到 0）
      if (ch.data.isEmpty) { ch.viewportData = []; continue; }
      
      // 使用二进制搜索快速定位视口范围内的数据点
      final newestAbsX = ch.data.last.x; // 最新点的绝对索引
      final targetMin = newestAbsX + _xMin; // 转换为绝对坐标进行搜索
      final targetMax = newestAbsX + _xMax;
      
      // Binary search for targetMin (first index where x >= targetMin)
      int startIdx = _binarySearch(ch.data, targetMin);
      // Binary search for targetMax (first index where x > targetMax)
      int endIdx = _binarySearch(ch.data, targetMax) + 1;
      
      startIdx = startIdx.clamp(0, ch.data.length);
      endIdx = endIdx.clamp(startIdx, ch.data.length);
      
      if (startIdx >= endIdx) { ch.viewportData = []; continue; }
      
      final visible = ch.data.sublist(startIdx, endIdx);
      if (visible.isEmpty) { ch.viewportData = []; continue; }
      
      // 调试：打印 visible.length 和 maxPts
      _debugLog('[VPD] ${ch.channelName}: visible.length=${visible.length} maxPts=$maxPts');
      
      // Adjust X values: relative to newest (newest = 0, older = negative)
      // Decimate to ≤ maxPts
      final step = (visible.length / maxPts).ceil().clamp(1, visible.length);
      ch.viewportData = [
        for (int i = 0; i < visible.length; i += step)
          _DataPoint(visible[i].x - newestAbsX, visible[i].y),
      ];
      // 调试：打印 viewportData.length
      _debugLog('[VPD]   viewportData.length=${ch.viewportData.length}');
    }
  }

  /// 分离的数据轮询（策略 B: 减少 FRB 调用）
  /// 后台快速轮询，不触发 UI 更新
  void _fetchRealData() {
    print('🧪 [DEBUG] [数据链路] 步骤5: _fetchRealData() 开始');
    if (!_useRealData) return; // Skip in demo mode
    if (!_isPlaying) return; // Pause: stop data fetching

    try {
      final activeDevices = debugGetActiveSessions();
      if (activeDevices.isEmpty) return;

      for (final deviceId in activeDevices) {
        // 只获取通道列表（轻量级）
        final channelNames = plotGetChannels(deviceId: deviceId);
        
        for (final chName in channelNames) {
          // Find or create channel
          final chIdx = _channels.indexWhere(
            (c) => c.deviceId == deviceId && c.channelName == chName,
          );
          
          if (chIdx == -1) {
            if (!_autoAddChannels) continue;
            final colorIdx = _channels.length % _channelColors.length;
            _channels.add(PlotChannel(
              deviceId: deviceId,
              deviceName: deviceId,
              channelName: chName,
              color: _channelColors[colorIdx],
              decimals: 3,
              lineStyle: LineStyle.line,
              showYAxis: false,
              plotGroupId: 'default',
            ));
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
              // Use sample index as X value: newest point at x=0, older points negative
              final totalPts = pts.length;
              ch.data = List.generate(totalPts, (i) {
                final sampleIdx = i - totalPts + 1; // -N+1, ..., -1, 0
                return _DataPoint(sampleIdx.toDouble(), pts[i].value);
              });
              ch.currentValue = pts.last.value;
              print('🧪 [DEBUG] [数据链路] 步骤5a: ch=${chName} initial data.len=${pts.length}');
            }
          } else {
            // ch.data has data, append latest points
            try {
              final latestData = plotGetChannelLatestData(deviceId: deviceId, channel: chName);
              if (latestData.isNotEmpty) {
                ch.currentValue = latestData.last.value;
                // Append new data points with sample index X values
                // Use negative indices: newest at x=0, older points negative
                for (int k = 0; k < latestData.length; k++) {
                  ch.data.add(_DataPoint(0.0, latestData[k].value));
                }
                ch.currentValue = latestData.last.value;
                // Keep only _maxPoints points (trim from front, keep newest)
                if (ch.data.length > _maxPoints) {
                  ch.data = ch.data.sublist(ch.data.length - _maxPoints);
                }
                // Renumber X values: newest at x=0, older points at negative indices
                final int totalLen = ch.data.length;
                for (int i = 0; i < totalLen; i++) {
                  ch.data[i] = _DataPoint((i - totalLen + 1).toDouble(), ch.data[i].y);
                }
              }
            } catch (_) {}
          }
        }
      }
      
      _totalPoints = _channels.fold(0, (sum, ch) => sum + ch.data.length);
    } catch (e) {
      print('🧪 [DEBUG] [数据链路] 步骤5 ERROR: $e');
    }
  }

  /// UI 更新节流（策略 A: 分离数据轮询和 UI 更新）
  /// 每 33ms 更新一次 UI，而非每次数据轮询都更新
  DateTime _lastUIUpdate = DateTime.now();

  void _updateRealDataUI() {
    print('🧪 [DEBUG] [数据链路] 步骤6: _updateRealDataUI() 开始');
    if (!_useRealData || !mounted || !_isPlaying) return;

    // 策略 A: UI 节流，每 33ms（约 30fps）更新一次
    final now = DateTime.now();
    if (now.difference(_lastUIUpdate).inMilliseconds < 33) return;
    _lastUIUpdate = now;

    // Update X axis range
    if (_scrollMode) {
      // Newest data at x=0, auto-track
      _xMax = 0.0;
      // For real data, limit scroll window to actual data length
      double effectiveWidth = _effectiveScrollWindowWidth;
      if (_useRealData && _channels.isNotEmpty) {
        final maxDataLen = _channels.map((c) => c.data.length).fold(0, (a, b) => a > b ? a : b);
        if (maxDataLen > 0 && maxDataLen < effectiveWidth) {
          effectiveWidth = maxDataLen.toDouble();
        }
      }
      _xMin = -effectiveWidth;
      _scrollMinTime = _xMin;
    } else {
      if (_autoScaleX) _fitXAxis();
      if (_autoScaleY) _fitYAxis();
    }
    
    // Always update Y-axis in scroll mode too
    if (_scrollMode && _autoScaleY) {
      _fitYAxis();
    }

    // 调试：X轴范围
    print('🧪 [DEBUG] [数据链路] 步骤6a: _xMin=$_xMin _xMax=$_xMax _autoScaleX=$_autoScaleX _channels.len=${_channels.length}');

    // Fetch viewport data for visible channels
    // 统一使用 _refreshViewportData() 处理 Demo 和 Real 模式
    _refreshViewportData();
    
    // CPU 渲染路径
    setState(() {});
  }

  void _startRealData() {
    _realDataTimer?.cancel();
    _fetchTimer?.cancel();

    // 策略 A: 两个分离的定时器
    // 1. 数据轮询：100ms（~10fps），降低频率避免FPS下降
    //    与 _updateRealDataUI 解耦，允许数据轮询更快
    _fetchTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _fetchRealData());
    // 2. UI 更新：100ms（~10fps），保证画面流畅不卡顿
    _realDataTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _updateRealDataUI());
  }

  Timer? _fetchTimer; // Separate from _realDataTimer

  void _toggleDataSource() {
    setState(() {
      _useRealData = !_useRealData;
      if (_useRealData) {
        // Switch to real data: stop demo timer, start real data timers
        _demoTimer?.cancel();
        // Init real channels if empty
        if (_realChannels.isEmpty) {
          _startRealData();
        } else {
          // Resume real data timers
          _realDataTimer?.cancel();
          _fetchTimer?.cancel();
          _fetchTimer = Timer.periodic(const Duration(milliseconds: 33), (_) => _fetchRealData());
          _realDataTimer = Timer.periodic(const Duration(milliseconds: 33), (_) => _updateRealDataUI());
        }
      } else {
        // Switch to demo: stop real data timers, start demo timer
        _realDataTimer?.cancel();
        _fetchTimer?.cancel();
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

  void _fitYAxisForChannel(PlotChannel ch) {
    // Use viewportData for Y-axis fitting (visible data only)
    final data = ch.viewportData.isNotEmpty ? ch.viewportData : ch.data;
    if (!ch.visible || data.isEmpty) return;
    double minVal = double.infinity;
    double maxVal = double.negativeInfinity;
    for (final pt in data) {
      if (pt.y < minVal) minVal = pt.y;
      if (pt.y > maxVal) maxVal = pt.y;
    }
    if (minVal.isInfinite) { minVal = -1; maxVal = 1; }
    final range = maxVal - minVal;
    final padding = range * 0.1;
    ch.yMin = minVal - padding;
    ch.yMax = maxVal + padding;
    ch.autoScaleY = true;
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
    _fpsFrameCount++;
    final now = DateTime.now();
    if (now.difference(_lastFpsTime).inMilliseconds >= 1000) {
      setState(() {
        _fps = _fpsFrameCount;
        _fpsFrameCount = 0;
        _lastFpsTime = now;
      });
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _demoTimer?.cancel();
    _realDataTimer?.cancel();
    _fetchTimer?.cancel();
    // GPU 𫔰阌
    if (_gpuInitialized) {
      RustLib.instance.api.crateApiGpuApiGpuCleanup();
    }
    // 停止 Rust 独立线程（方案3）
    RustLib.instance.api.crateApiDataReceiverStopDataReceiver();
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
          for (int i = 0; i < min(chConfigs.length, _channels.length); i++) {
            try {
              final c = chConfigs[i] as Map<String, dynamic>;
              _channels[i].visible = c['visible'] as bool? ?? true;
              _channels[i].decimals = c['decimals'] as int? ?? 3;
              _channels[i].showYAxis = c['showYAxis'] as bool? ?? true;
              _channels[i].lineStyle = LineStyle.values.firstWhere(
                (e) => e.name == c['lineStyle'], orElse: () => LineStyle.line);
              _channels[i].plotGroupId = c['plotGroupId'] as String? ?? 'default';
            } catch (e) {
              debugPrint('Failed to load channel config at index $i: $e');
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
        _shareYAxis = json['shareYAxis'] as bool? ?? true;
        _scrollMode = json['scrollMode'] as bool? ?? false;
        _scrollWindowWidth = (json['scrollWindowWidth'] as num?)?.toDouble() ?? 0.0;
        _scrollMinTime = (json['scrollMinTime'] as num?)?.toDouble() ?? 0.0;
        _maxPoints = (json['maxPoints'] as num?)?.toInt() ?? 250000;
        _deltaTime = (json['deltaTime'] as num?)?.toDouble() ?? 1.0;
        _maxPointsController.text = _maxPoints.toString();
        _deltaTimeController.text = _deltaTime.toString();
        // Load Flutter log settings from app_config.json
        try {
          final appData = Platform.environment['APPDATA'] ?? '';
          final appFile = File('$appData\\VCR\\app_config.json');
          if (await appFile.exists()) {
            final appConfig = jsonDecode(await appFile.readAsString()) as Map<String, dynamic>;
            final flutterLogLevel = appConfig['flutterLogLevel'] as String? ?? 'debug';
            _flutterLogLevel = ['trace', 'debug', 'info', 'warn', 'error'].indexOf(flutterLogLevel);
            if (_flutterLogLevel < 0) _flutterLogLevel = 1;
            _flutterLogPath = appConfig['flutterLogPath'] as String? ?? 'debug_log.txt';
            _flutterFileLogging = appConfig['flutterFileLogging'] as bool? ?? true;
          }
        } catch (e) {
          debugPrint('Failed to load Flutter log settings: $e');
        }
      }
    } catch (e) {
      debugPrint('Failed to load plot config: $e');
    }
  }

  Future<void> _loadFlutterLogSettings() async {
    try {
      final appData = Platform.environment['APPDATA'] ?? '';
      final appFile = File('$appData\\VCR\\app_config.json');
      if (await appFile.exists()) {
        final appConfig = jsonDecode(await appFile.readAsString()) as Map<String, dynamic>;
        final flutterLogLevel = appConfig['flutterLogLevel'] as String? ?? 'debug';
        _flutterLogLevel = ['trace', 'debug', 'info', 'warn', 'error'].indexOf(flutterLogLevel);
        if (_flutterLogLevel < 0) _flutterLogLevel = 1;
        _flutterLogPath = appConfig['flutterLogPath'] as String? ?? 'debug_log.txt';
        _flutterFileLogging = appConfig['flutterFileLogging'] as bool? ?? true;
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
      await file.writeAsString(jsonEncode({
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
      }));
      // Also sync to app_config.json so settings screen picks it up
      final appData = Platform.environment['APPDATA'] ?? '';
      final appFile = File('$appData\\VCR\\app_config.json');
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
      await appFile.writeAsString(jsonEncode(appConfig));
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
      final result = await RustLib.instance.api.crateApiGpuApiGpuInit();
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

  Future<void> _renderWaveformOnGpu() async {
    if (!_useGpuAcceleration || !_gpuInitialized || _isGpuRendering) return;
    if (_channels.isEmpty) return;

    _isGpuRendering = true;
    try {
      final points = <double>[];
      for (final ch in _channels.where((c) => c.visible && c.viewportData.isNotEmpty)) {
        for (final pt in ch.viewportData) {
          points.add(pt.x);
          points.add(pt.y);
        }
      }

      if (points.isEmpty) {
        _isGpuRendering = false;
        return;
      }

      final pointCount = points.length ~/ 2;
      final width = 800;
      final height = 600;

      final imageData = await RustLib.instance.api.crateApiGpuApiGpuRenderWaveform(
        width: width,
        height: height,
        points: Float32List.fromList(points),
        pointCount: pointCount,
        r: 255,
        g: 0,
        b: 0,
        a: 255,
      );

      final image = await _createImageFromRgba(imageData, width, height);

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
    setState(() {
      _sampleIndex = 0;
      _demoPhase = 0;
      for (final ch in _channels) {
        ch.data.clear();
        ch.currentValue = 0.0;
      }
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
              // Pause: cancel timers to stop all updates
              _fetchTimer?.cancel();
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
                              fontSize: 10,
                              fontFamily: 'Consolas, monospace',
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
          // Track plot area width for viewport decimation
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
                    // In scroll mode: drag viewport left/right within fixed range [-缓冲区大小, 0]
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
                  _refreshViewportData();
                });
              },
              onPanEnd: (_) {
                _isDragging = false;
                _dragStart = null;
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
                    gpuWaveformImage: _gpuWaveformImage,
                    deltaTime: _deltaTime,
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

    // Final clamp: never let thumb extend beyond track bounds
    thumbLeft = thumbLeft.clamp(plotLeft, plotLeft + trackWidth - 20);
    thumbRight = thumbRight.clamp(plotLeft + 20, plotLeft + trackWidth);

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
                      setState(() => _refreshViewportData());
                    },
                    onHorizontalDragEnd: (d) {
                      _scrollbarDrag = _ScrollbarDrag.none;
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.blue.withAlpha(180),
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
                        // 允许滑块宽度为0
                        if (newMin >= _scrollbarDragStartXMax) {
                          newMin = _scrollbarDragStartXMax;
                        }
                        newMin = newMin.clamp(-_maxPoints.toDouble(), _scrollbarDragStartXMax);
                        _xMin = newMin;
                        if (_scrollMode) {
                          _scrollMinTime = newMin.clamp(0.0, double.maxFinite);
                          _scrollWindowWidth = _scrollbarDragStartXMax - newMin;
                        } else {
                          _autoScaleX = false;
                        }
                        setState(() => _refreshViewportData());
                      },
                      onHorizontalDragEnd: (d) {
                        _scrollbarDrag = _ScrollbarDrag.none;
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
                        // 允许滑块宽度为0
                        newMax = newMax.clamp(_scrollbarDragStartXMin, 0.0);
                        _xMax = newMax;
                        if (_scrollMode) {
                          _scrollWindowWidth = newMax - _scrollbarDragStartXMin;
                        } else {
                          _autoScaleX = false;
                        }
                        setState(() => _refreshViewportData());
                      },
                      onHorizontalDragEnd: (d) {
                        _scrollbarDrag = _ScrollbarDrag.none;
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
    // Sort channels by name in Real Data Mode (CH0, CH1, CH10... natural order)
    final displayChannels = _useRealData 
        ? (List<PlotChannel>.from(_channels)..sort((a, b) {
            // Natural sort for channel names like ch0, ch1, ch10
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
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Consolas, monospace',
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
    print('🧪 [DEBUG] _PlotPainter.paint() 被调用, size=\$size');
    final rangeX = dataXMax - dataXMin;
    if (rangeX <= 0) return;

    for (final ch in channels) {
      if (!ch.visible || ch.data.isEmpty) continue;
      // Use viewportData if available (already decimated, 500-4000 pts)
      final data = ch.viewportData.isNotEmpty ? ch.viewportData : ch.data;
      if (data.isEmpty) continue;
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
      for (int i = 0; i < data.length; i++) {
        final pt = data[i];
        final x = ((pt.x - dataXMin) / rangeX) * size.width;
        final y = size.height - ((pt.y - chYMin) / rangeY) * size.height;
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
  final List<PlotChannel> channels;
  final double xMin, xMax, yMin, yMax;
  final Offset? mousePosition;
  final int fps;
  final int totalPoints;
  final double aaScale;
  final int globalDecimals;
  final bool shareYAxis; // When true, all channels use global yMin/yMax
  final ui.Image? gpuWaveformImage; // GPU-accelerated waveform texture (optional)
  final double deltaTime; // Time per sample in ms (for X axis label formatting)

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
    this.gpuWaveformImage,
    this.deltaTime = 1.0,
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
    print('🧪 [DEBUG] _PlotPainter.paint() 被调用, size=\$size');
    final w = size.width;
    final h = size.height;

    // ── GPU-accelerated rendering path ──
    // If we have a GPU-rendered waveform texture, use it directly
    if (gpuWaveformImage != null) {
      // Draw background first (matches _paintInternal)
      canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF0A0E14));
      
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
      canvas.drawRect(
        Rect.fromLTWH(plotLeft, plotTop, plotW, plotH),
        Paint()..color = const Color(0xFF0D1117),
      );

      // Draw GPU waveform image (it already contains grid, waveforms, and axes)
      final srcRect = Rect.fromLTWH(0, 0, gpuWaveformImage!.width.toDouble(), gpuWaveformImage!.height.toDouble());
      final dstRect = Rect.fromLTWH(plotLeft, plotTop, plotW, plotH);
      canvas.drawImageRect(gpuWaveformImage!, srcRect, dstRect, Paint()..filterQuality = FilterQuality.high);

      // Draw border
      canvas.drawRect(
        Rect.fromLTWH(plotLeft, plotTop, plotW, plotH),
        Paint()
          ..color = const Color(0xFF30363D)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );

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
        canvas.drawImageRect(image, srcRect, dstRect, Paint()
          ..filterQuality = FilterQuality.medium
          ..blendMode = BlendMode.srcOver);
        image.dispose();
      } catch (e) {
        // Fallback: draw directly without supersampling
        _paintInternal(canvas, w, h, 1.0);
      }
      picture.dispose();
    } else {
      _paintInternal(canvas, w, h, 1.0);
    }
  }

  void _paintInternal(Canvas canvas, double w, double h, double scale) {
    // Calculate dynamic margins based on number of Y axes
    final yAxisChannels = channels.where((ch) => ch.visible && ch.showYAxis).toList();
    final leftYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 0).length;
    final rightYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 1).length;
    
    final plotLeft = 50.0 + leftYAxes * 45.0; // Expand left margin for multiple Y axes
    final plotBottom = 40.0;
    final plotRight = 10.0 + rightYAxes * 45.0; // Expand right margin for multiple Y axes
    final plotTop = 10.0;
    final plotW = w - plotLeft - plotRight;
    final plotH = h - plotTop - plotBottom;

    if (plotW <= 0 || plotH <= 0) return; // Guard against invalid dimensions

    // ── Background ──
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF0A0E14));

    // ── Plot area background ──
    canvas.drawRect(
      Rect.fromLTWH(plotLeft, plotTop, plotW, plotH),
      Paint()..color = const Color(0xFF0D1117),
    );

    // ── Grid lines ──
    final gridPaint = Paint()
      ..color = const Color(0xFF1A2030)
      ..strokeWidth = 0.5;

    // Vertical grid (X axis — shared)
    final xTicks = _niceTicks(xMin, xMax, 10);
    for (final tick in xTicks) {
      final sx = _xToScreen(tick, plotW) + plotLeft;
      if (sx < plotLeft || sx > plotLeft + plotW) continue;
      canvas.drawLine(Offset(sx, plotTop), Offset(sx, plotTop + plotH), gridPaint);
    }

    // Horizontal grid (Y axis — global for now, per-channel labels rendered separately)
    final yTicks = _niceTicks(yMin, yMax, 8);
    for (final tick in yTicks) {
      final sy = _yToScreen(tick, plotH, yMin, yMax) + plotTop;
      if (sy < plotTop || sy > plotTop + plotH) continue;
      canvas.drawLine(Offset(plotLeft, sy), Offset(plotLeft + plotW, sy), gridPaint);
    }

    // Zero line
    final zeroY = _yToScreen(0, plotH, yMin, yMax) + plotTop;
    if (zeroY >= plotTop && zeroY <= plotTop + plotH) {
      final zeroPaint = Paint()
        ..color = const Color(0xFF2A3040)
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(plotLeft, zeroY), Offset(plotLeft + plotW, zeroY), zeroPaint);
    }

    // ── X axis labels ──
    final labelStyle = TextStyle(
      color: const Color(0xFF8B949E),
      fontSize: 10.0,
      fontFamily: 'Consolas, monospace',
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
    // If multiple channels show Y-axis, render them on alternating sides with their color
    if (yAxisChannels.length == 1) {
      // Single Y-axis: render on left side as before, use global range
      for (final tick in yTicks) {
        final sy = _yToScreen(tick, plotH, yMin, yMax) + plotTop;
        if (sy < plotTop || sy > plotTop + plotH) continue;
        final tp = TextPainter(
          text: TextSpan(text: _formatTick(tick, globalDecimals), style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(plotLeft - tp.width - 4, sy - tp.height / 2));
      }
    } else {
      // Multi Y-axis: render each channel's Y labels on alternating sides
      for (int ci = 0; ci < yAxisChannels.length; ci++) {
        final ch = yAxisChannels[ci];
        final chYMin = ch.autoScaleY ? ch.yMin : ch.yMinManual;
        final chYMax = ch.autoScaleY ? ch.yMax : ch.yMaxManual;
        final chTicks = _niceTicks(chYMin, chYMax, 6);
        final chLabelStyle = TextStyle(
          color: ch.color,
          fontSize: 9.0,
          fontFamily: 'Consolas, monospace',
        );

        // Even index → left side, odd index → right side
        final isLeft = ci % 2 == 0;
        final leftIdx = (ci / 2).floor();
        final rightIdx = (ci / 2).floor();

        for (final tick in chTicks) {
          final sy = _yToScreen(tick, plotH, chYMin, chYMax) + plotTop;
          if (sy < plotTop || sy > plotTop + plotH) continue;
          // Format with channel's decimal precision
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

        // Draw a colored axis line for this channel
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

    // ── Waveform clipping ──
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(plotLeft, plotTop, plotW, plotH));

    // ── Draw channels ──
    for (final ch in channels) {
      if (!ch.visible || ch.data.isEmpty) continue;

      // Determine which Y range to use for this channel
      final double chYMin;
      final double chYMax;
      if (shareYAxis) {
        // Use global Y range when sharing Y axis
        chYMin = yMin;
        chYMax = yMax;
      } else {
        // Use per-channel Y range
        chYMin = ch.autoScaleY ? ch.yMin : ch.yMinManual;
        chYMax = ch.autoScaleY ? ch.yMax : ch.yMaxManual;
      }

      _drawChannel(canvas, ch, plotLeft, plotTop, plotW, plotH, chYMin, chYMax, scale);
    }

    canvas.restore();

    // ── Border ──
    canvas.drawRect(
      Rect.fromLTWH(plotLeft, plotTop, plotW, plotH),
      Paint()
        ..color = const Color(0xFF30363D)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    // ── Crosshair / cursor ──
    if (mousePosition != null) {
      final mx = mousePosition!.dx;
      final my = mousePosition!.dy;
      if (mx >= plotLeft && mx <= plotLeft + plotW &&
          my >= plotTop && my <= plotTop + plotH) {
        final cursorPaint = Paint()
          ..color = const Color(0x4058A6FF)
          ..strokeWidth = 0.5;

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
        final tp = TextPainter(
          text: TextSpan(text: coordText, style: TextStyle(
            color: const Color(0xFFC9D1D9),
            fontSize: 11.0,
            fontFamily: 'Consolas, monospace',
          )),
          textDirection: TextDirection.ltr,
        )..layout();
        var tx = mx + 12;
        var ty = my - tp.height - 8;
        if (tx + tp.width > plotLeft + plotW) tx = mx - tp.width - 8;
        if (ty < plotTop) ty = my + 8;

        canvas.drawRect(
          Rect.fromLTWH(tx - 2, ty - 1, tp.width + 4, tp.height + 2),
          Paint()..color = const Color(0xDD161B22),
        );
        tp.paint(canvas, Offset(tx, ty));

        // Channel values at cursor X
        double yOffset = ty + tp.height + 4;
        for (final ch in channels) {
          if (!ch.visible || ch.data.isEmpty) continue;
          final val = _getValueAtX(ch, dataX);
          if (val != null) {
            final chText = '${ch.channelName}: ${val.toStringAsFixed(ch.decimals)}';
            final ctp = TextPainter(
              text: TextSpan(text: chText, style: TextStyle(
                color: ch.color,
                fontSize: 10.0,
                fontFamily: 'Consolas, monospace',
              )),
              textDirection: TextDirection.ltr,
            )..layout();
            if (yOffset + ctp.height > plotTop + plotH) break;
            ctp.paint(canvas, Offset(tx, yOffset));
            yOffset += ctp.height + 2;
          }
        }
      }
    }

    final infoStyle = TextStyle(
      color: const Color(0xFF8B949E),
      fontSize: 10.0,
      fontFamily: 'Consolas, monospace',
    );
    final infoTp = TextPainter(
      text: TextSpan(text: 'FPS: $fps  Pts: $totalPoints', style: infoStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    infoTp.paint(canvas, Offset(plotLeft + plotW - infoTp.width - 4, plotTop + 4));
  }

  void _drawChannel(Canvas canvas, PlotChannel ch, double ox, double oy, double w, double h, double chYMin, double chYMax, double scale) {
    // Use pre-decimated viewport data from Rust if available, otherwise fall back to full data
    List<_DataPoint> data;
    if (ch.viewportData.isNotEmpty) {
      data = ch.viewportData;
    } else {
      final allData = ch.data;
      if (allData.isEmpty) return;

      // Viewport clip: only pass data points within visible X range + 1 point margin
      final xRange = xMax - xMin;
      final margin = xRange * 0.01;
      int startIdx = 0;
      int endIdx = allData.length - 1;
      int lo = 0, hi = allData.length - 1;
      while (lo < hi) {
        final mid = (lo + hi) ~/ 2;
        if (allData[mid].x < xMin - margin) lo = mid + 1; else hi = mid;
      }
      startIdx = lo > 0 ? lo - 1 : 0;
      lo = startIdx; hi = allData.length - 1;
      while (lo < hi) {
        final mid = (lo + hi + 1) ~/ 2;
        if (allData[mid].x > xMax + margin) hi = mid - 1; else lo = mid;
      }
      endIdx = lo < allData.length - 1 ? lo + 1 : allData.length - 1;
      data = allData.sublist(startIdx, endIdx + 1);

      // No decimation for demo mode — data is bounded and viewport-clipped
      // Decimation loses high-frequency Fourier harmonics, causing jagged appearance
      // if (data.length > w * 1) {
      //   data = _decimateDataSmooth(data, w);
      // }
    }

    if (data.isEmpty) return;

    // Use per-channel Y transform
    double yTransform(double y) {
      if (chYMax == chYMin) return h / 2;
      return h - (y - chYMin) / (chYMax - chYMin) * h;
    }

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
void _drawDots(Canvas canvas, PlotChannel ch, List<_DataPoint> data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale) {
    if (data.isEmpty) return;
    
    // 🚀 性能优化：使用Path批量绘制，减少draw call次数
    final paint = Paint()
      ..color = ch.color
      ..strokeWidth = ch.lineWidth
      ..strokeCap = StrokeCap.round;
    
    for (final pt in data) {
      final sx = _xToScreen(pt.x, w) + ox;
      final sy = yTransform(pt.y) + oy;
      canvas.drawCircle(Offset(sx, sy), 1.5, paint);
    }
  }

  void _drawDotLine(Canvas canvas, PlotChannel ch, List<_DataPoint> data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale) {
    // Draw connecting line first (thinner, dimmer)
    final linePaint = Paint()
      ..color = ch.color.withValues(alpha: 0.5)
      ..strokeWidth = ch.lineWidth
      ..style = PaintingStyle.stroke;

    final path = Path();
    for (int i = 0; i < data.length; i++) {
      final sx = _xToScreen(data[i].x, w) + ox;
      final sy = yTransform(data[i].y) + oy;
      if (i == 0) {
        path.moveTo(sx, sy);
      } else {
        path.lineTo(sx, sy);
      }
    }
    canvas.drawPath(path, linePaint);

    // Draw dots on top
    final dotPaint = Paint()..color = ch.color;
    for (final pt in data) {
      final sx = _xToScreen(pt.x, w) + ox;
      final sy = yTransform(pt.y) + oy;
      canvas.drawCircle(Offset(sx, sy), 2.5, dotPaint);
    }
  }

  void _drawLine(Canvas canvas, PlotChannel ch, List<_DataPoint> data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale) {
    final paint = Paint()
      ..color = ch.color
      ..strokeWidth = ch.lineWidth
      ..style = PaintingStyle.stroke;

    final path = Path();
    for (int i = 0; i < data.length; i++) {
      final sx = _xToScreen(data[i].x, w) + ox;
      final sy = yTransform(data[i].y) + oy;
      if (i == 0) {
        path.moveTo(sx, sy);
      } else {
        path.lineTo(sx, sy);
      }
    }
    canvas.drawPath(path, paint);
  }

  void _drawFilled(Canvas canvas, PlotChannel ch, List<_DataPoint> data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale, double chYMin, double chYMax) {
    if (data.length < 2) return;

    // Zero line position for this channel's Y range
    final zeroY = yTransform(0) + oy;

    // Calculate fill bounds
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (final pt in data) {
      final sy = yTransform(pt.y) + oy;
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
    path.moveTo(_xToScreen(data[0].x, w) + ox, zeroY);
    for (int i = 0; i < data.length; i++) {
      final sx = _xToScreen(data[i].x, w) + ox;
      final sy = yTransform(data[i].y) + oy;
      path.lineTo(sx, sy);
    }
    path.lineTo(_xToScreen(data.last.x, w) + ox, zeroY);
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
    // GPU texture changed?
    if (gpuWaveformImage != oldDelegate.gpuWaveformImage) return true;
    
    // Only repaint when something actually changed
    if (xMin != oldDelegate.xMin || xMax != oldDelegate.xMax ||
        yMin != oldDelegate.yMin || yMax != oldDelegate.yMax ||
        mousePosition != oldDelegate.mousePosition ||
        fps != oldDelegate.fps ||
        totalPoints != oldDelegate.totalPoints ||
        aaScale != oldDelegate.aaScale ||
        globalDecimals != oldDelegate.globalDecimals ||
        shareYAxis != oldDelegate.shareYAxis) {
      return true;
    }
    // Check channel-level changes
    if (channels.length != oldDelegate.channels.length) return true;
    for (int i = 0; i < channels.length; i++) {
      final a = channels[i];
      final b = oldDelegate.channels[i];
      if (a.visible != b.visible ||
          a.color != b.color ||
          a.lineStyle != b.lineStyle ||
          a.data.length != b.data.length ||
          a.viewportData.length != b.viewportData.length) {
        return true;
      }
      // Only need to check last point for new data
      if (a.data.isNotEmpty && b.data.isNotEmpty) {
        final aLast = a.data.last;
        final bLast = b.data.last;
        if (aLast.x != bLast.x || aLast.y != bLast.y) return true;
      } else if (a.data.isNotEmpty || b.data.isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  void _drawOverlay(Canvas canvas, double w, double h, int fps, int totalPoints) {
    // Draw FPS counter (top-right corner)
    final fpsStyle = TextStyle(
      color: const Color(0xFF58A6FF),
      fontSize: 11.0,
      fontFamily: 'Consolas, monospace',
    );
    final fpsText = 'FPS: $fps | Points: $totalPoints';
    final tp = TextPainter(
      text: TextSpan(text: fpsText, style: fpsStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(w - tp.width - 8, 8));
  }

  void _drawCrosshair(Canvas canvas, double mx, double my,
      double plotLeft, double plotTop, double plotW, double plotH, double w, double h) {
    final cursorPaint = Paint()
      ..color = const Color(0x4058A6FF)
      ..strokeWidth = 0.5;

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
    final tp = TextPainter(
      text: TextSpan(text: coordText, style: TextStyle(
        color: const Color(0xFFC9D1D9),
        fontSize: 11.0,
        fontFamily: 'Consolas, monospace',
      )),
      textDirection: TextDirection.ltr,
    )..layout();

    // Position tooltip near cursor but avoid clipping
    double tx = mx + 10;
    double ty = my - 20;
    if (tx + tp.width > w - 10) tx = mx - tp.width - 10;
    if (ty < 10) ty = my + 20;

    // Background for tooltip
    canvas.drawRect(
      Rect.fromLTWH(tx - 4, ty - 2, tp.width + 8, tp.height + 4),
      Paint()..color = const Color(0xCC0D1117),
    );
    tp.paint(canvas, Offset(tx, ty));
  }
}


