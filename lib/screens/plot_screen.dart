import 'dart:math';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:ffi' hide Size; // NOTE: Phase C: Pointer for native buffer reuse (hide Size to avoid dart:ui conflict)
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


part 'plot_models.dart';
part 'plot_painter.dart';

// ============================================================================
// Plot Screen — Oscilloscope-style waveform viewer
// ============================================================================

class _PlotScreenState extends State<PlotScreen> with SingleTickerProviderStateMixin {
  // ── Data source ──
  bool _useRealData = false; // false = demo, true = real device
  Timer? _realDataTimer; // NOTE: 单定时器：合并 data fetch + UI update，消除竞态
  
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

  // ── Pipeline thread toggle ──
  // When true, RENDER_ENVELOPE zero-copy path is active.
  // The pipeline thread pre-computes envelope data each frame (VP_DIRTY or DATA_READY trigger).
  // Toggle via toolbar button; off by default to keep startup simple.
  bool _pipelineEnabled = false;

  // ── AnalogSegment envelope toggle ──
  // When true, the pipeline reads envelope from AnalogSegment (f32, 10-level 16^n pyramid)
  // instead of TimeBucketPyramid (f64). Enables higher-precision decimation.
  // Toggle via toolbar button; requires pipeline to be enabled.
  bool _analogEnvelopeEnabled = false;
  int _fps = 0;
  int _totalPoints = 0;
  DateTime _lastFpsTime = DateTime.now();
  int _fpsFrameCount = 0;

  // ── GPU state ──
  bool _gpuInitialized = false;
  bool _useGpuAcceleration = true;
  ui.Image? _gpuWaveformImage;
  bool _isGpuRendering = false;

  // FIXED(P2)-B 优化：增量更新版本号
  // ignore: unused_field
  BigInt _lastDataVersion = BigInt.zero;

  // NOTE: P3-B 优化：ChartViewport 刷新计数器（用于 shouldRepaint 优化）
  int _viewportRefreshCount = 0;

  // DIAG: Diagnostic: set true to enable verbose per-frame logging (DISABLE for production)
  static const bool _verbose = false;
  int _frameCount = 0;

  // NOTE: Phase C: Reusable query buffers (allocated once, resized lazily)
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
    // HSL auto-generation: evenly distribute hues across the circle
    // Maintains perceptual distinctiveness beyond 16 channels (P3-3)
    final idx = _channels.length;
    if (idx < _channelColors.length) return _channelColors[idx];
    // Fallback: HSL with golden-ratio hue spacing for arbitrary channel count
    final hue = (idx * 137.508) % 360; // golden angle ~137.5°, maximises colour separation
    return HSLColor.fromAHSL(1.0, hue, 0.7, 0.55).toColor();
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
    // ── AnalogSegment: deferred init (created when user enables toggle) ──
    // AnalogSegments are created in _toggleAnalogEnvelope() to avoid unnecessary
    // resource allocation at startup.
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
      // NOTE: Batch push all sub-samples at once: 1 FFI call per channel instead of N×sub-samples
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

      // DIAG: Fix: _refreshViewportData() MUST run BEFORE _fitYAxis() to ensure
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
  /// NOTE: Phase A: Uses per-channel Rust LOD pyramid (pre-computed bucket aggregation)
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

    bool anyData = false; // Track if any channel had non-zero count
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
      anyData = true;

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

    // If no channel had data, fall through to per-channel pyramid query
    if (!anyData) return false;

    // Verify generation didn't change during read (pipeline update mid-read)
    // Note: asTypedList provides a live view; pipeline writes are atomic (generation check)
    final gen2 = bridge.envelopeGetGeneration();
    if (gen1 != gen2) return false; // Mid-update, discard

    _viewportRefreshCount++;
    return true;
  }

  void _refreshViewportData() {
    if (_xMin == _xMax || _screenWidth <= 0) return;

    // FIXED(P0)-4: Zero-copy envelope read (pre-computed by Rust pipeline thread).
    // When pipeline is enabled, try envelope read first; fall back to pyramid query on failure.
    if (_pipelineEnabled) {
      if (_refreshViewportDataFromEnvelope()) return;
      if (_refreshViewportFromAnalog()) return;
    } else if (_analogEnvelopeEnabled) {
      // AnalogSegment direct C-ABI path (works without pipeline thread).
      if (_refreshViewportFromAnalog()) return;
    }

    // Fallback: per-channel pyramid query (always active)
    final maxPts = _screenWidth.round().clamp(500, 4000);
    final bridge = FfiBridge.instance;

    // NOTE: Reusable Float64List buffer for pyramid query results
    final maxDatapoints = maxPts * 2;
    if (_queryBuffer == null || _queryBuffer!.length != maxDatapoints * 2) {
      _queryBuffer = Float64List(maxDatapoints * 2);
    }
    final fb = _queryBuffer!;

    // NOTE: Phase C: Reuse native CDataPoint buffer
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

      try {
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
      } catch (_) {
        // FFI call failed (e.g. DLL unloaded, Rust panic) — clear this channel and continue
        ch.viewportData.clear();
        ch.envelopeData.clear();
      }

    }
    _viewportRefreshCount++;
  }

  // ── AnalogSegment envelope read ──
  // Called when _analogEnvelopeEnabled is true (runtime toggle).
  // Reads per-channel envelope from AnalogSegment via C-ABI (f32 min/max pairs).
  // When samplesPerPixel < envelopeThreshold, uses trace mode (raw f32 values).
  bool _refreshViewportFromAnalog() {
    // Wrap entire method in try to prevent calloc leaks on FFI crash (P2-3)
    try {
      return _refreshViewportFromAnalogImpl();
    } catch (_) {
      return false;
    }
  }

  bool _refreshViewportFromAnalogImpl() {
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
          : envelopeThreshold.toDouble();

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
          (_renderMode == _RenderMode.auto && samplesPerPixelDouble < envelopeThreshold);
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

      // ── Envelope mode (samplesPerPixel >= envelopeThreshold): min/max pairs ──
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
    // NOTE: P3-B 双缓冲：每次获取数据前，先 swap 缓冲区
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
            if (_analogEnvelopeEnabled) {
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
              // FIXED(P0)-1: Use Rust timestampMs as X value (synced with pipeline pyramid)
              ch.data = pts.map((p) => _DataPoint(p.timestampMs, p.value)).toList();
              ch.currentValue = pts.last.value;
              // Pipeline pushes from receive loop — no Dart push needed
            }
          } else {
            // Get delta data: all new points since last swap (front buffer has delta only)
            try {
              final latestData = plotGetChannelLatestData(deviceId: deviceId, channel: chName);
              if (latestData.isNotEmpty) {
                // FIXED(P0)-1: Use Rust timestampMs (synced with pipeline::push_sample_batch_with_x)
                for (int k = 0; k < latestData.length; k++) {
                  ch.data.add(_DataPoint(latestData[k].timestampMs, latestData[k].value));
                }
                ch.currentValue = latestData.last.value;
                // Keep only _maxPoints points (trim from front, keep newest)
                if (ch.data.length > _maxPoints) {
                  ch.data.removeRange(0, ch.data.length - _maxPoints);
                  // Pyramid self-manages via TimeBucket::max_buckets — no Dart trimming needed
                }
                // NOTE: Incremental point counting (avoid O(all_data) fold)
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

    // NOTE: 单定时器架构：数据获取 + UI 更新在同一回调中顺序执行
    // 消除 _fetchTimer / _realDataTimer 双定时器竞态：
    // - 旧架构：两个独立 100ms Timer，执行顺序不确定
    // - 新架构：单个 50ms Timer，先 fetch → 再 UI update，保证 pyramid 数据就绪
    // _updateRealDataUI 内部保留 33ms 节流，控制实际 UI 刷新率
    _realDataTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _fetchRealData();
      // DIAG: Diagnostic: track viewportData population
      if (_channels.isNotEmpty) {
        final hasData = _channels.where((c) => c.visible && c.data.isNotEmpty);
        final noViewport = hasData.where((c) => c.viewportData.isEmpty);
        if (noViewport.isNotEmpty && _frameCount % 20 == 0) {
          if (_verbose) print('[DIAG] ${noViewport.length}/${hasData.length} channels have empty viewportData (frame $_frameCount)');
        }
        _frameCount++;
      }
      // DIAG: Diagnostic: check Rust-side overflow counts every 200 frames (~10s)
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

      // NOTE: Clear pyramid data to prevent demo↔real data mixing.
      // Demo and Real channels share integer indices (0,1,2,...) as pyramid keys;
      // switching modes reuses same indices with different channel lists.
      FfiBridge.instance.clearAllChannelPyramids();
      // Clear AnalogSegment data as well (prevents demo↔real data mixing)
      if (_analogEnvelopeEnabled) {
        FfiBridge.instance.analogResetAll();
      }
      // Bump viewportRefreshCount to invalidate _PlotPainter cached picture
      // (otherwise shouldRepaint returns false, reusing stale demo rendering).
      _viewportRefreshCount++;

      // FIX: P2-3: Reset EMA-smoothed Y-axis range on data-source switch.
      // Without this, Demo↔Real carry-over pollutes Y axis for several seconds.
      for (final ch in _channels) {
        ch._smoothedYMin = null;
        ch._smoothedYMax = null;
      }

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

  void _togglePipeline() {
    setState(() {
      _pipelineEnabled = !_pipelineEnabled;
      if (_pipelineEnabled) {
        FfiBridge.instance.startPipeline();
        // If analog envelope is enabled, ensure segments exist after pipeline start
        if (_analogEnvelopeEnabled) {
          _ensureAnalogSegments();
        }
      } else {
        FfiBridge.instance.stopPipeline();
      }
    });
  }

  /// Toggle AnalogSegment envelope rendering.
  /// When enabled, the pipeline reads envelope data from AnalogSegment (f32, 10-level
  /// 16^n pyramid) instead of TimeBucketPyramid (f64). This provides higher-precision
  /// decimation at the cost of additional memory (f32 per level).
  /// Requires pipeline to be enabled; auto-starts pipeline if needed.
  void _toggleAnalogEnvelope() {
    setState(() {
      _analogEnvelopeEnabled = !_analogEnvelopeEnabled;
      if (_analogEnvelopeEnabled) {
        // Auto-start pipeline if not already running
        if (!_pipelineEnabled) {
          _pipelineEnabled = true;
          FfiBridge.instance.startPipeline();
        }
        // Enable AnalogSegment as envelope source
        FfiBridge.instance.analogSetEnvelopeEnabled(true);
        _ensureAnalogSegments();
      } else {
        // Disable AnalogSegment envelope source (fall back to TimeBucketPyramid)
        FfiBridge.instance.analogSetEnvelopeEnabled(false);
      }
      _saveConfig();
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

  // NOTE: 性能优化：计算绘图区域尺寸（用于GPU渲染）
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

    // P1: Only scan viewportData (~800-4000 points) — never fall back to ch.data
    // (250K _DataPoint heap objects). In real-time mode viewportData is always
    // populated by _refreshViewportData() before _fitYAxis() runs. When empty
    // (e.g. first frame, source switch), keep the previous smoothed range
    // instead of iterating the full dataset.
    if (ch.viewportData.isNotEmpty) {
      for (int i = 0; i < ch.viewportData.length; i++) {
        final y = ch.viewportData.y(i);
        if (y < minVal) minVal = y;
        if (y > maxVal) maxVal = y;
      }
    }
    if (minVal.isInfinite) {
      // No viewport data — use EMA carry-over or default range
      if (ch._smoothedYMin != null) {
        // Reuse previous smoothed range (stabilized, no oscillation)
        return; // Don't touch ch.yMin/ch.yMax this frame
      }
      return; // Never had data — wait for first populated viewport
    }
    final range = maxVal - minVal;
    final padding = range * 0.1;
    final targetMin = minVal - padding;
    final targetMax = maxVal + padding;
    
    // DIAG: EMA-smooth Y-axis to eliminate 1-frame range oscillation glitches.
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
    // DIAG: Diagnostic: detect Y-axis oscillation (target range change > 5%)
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
        if (_pipelineEnabled) _notifyPipelineViewport(); // Feed viewport BEFORE refresh → pipeline computes async
        _refreshViewportData(); // Reads envelope (from prev frame) or falls back to pyramid query
        if (_autoScaleY) _fitYAxis();
        if (!_scrollMode && _autoScaleX) _fitXAxis();
        setState(() {});
      } else {
        if (_pipelineEnabled) _notifyPipelineViewport(); // Feed viewport BEFORE refresh
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
    // GPU 关闭
    if (_gpuInitialized) {
      RustLib.instance.api.crateApiGpuApiGpuCleanup();
    }
    // 停止 Rust 独立线程（方案3）
    RustLib.instance.api.crateApiDataReceiverStopDataReceiver();
    // Stop pipeline thread if active
    if (_pipelineEnabled) {
      FfiBridge.instance.stopPipeline();
    }
    // Release static GPU Picture cache (prevents long-running memory leak)
    _PlotPainter.disposeStaticCache();
    // NOTE: Phase C: Free reusable native query buffer
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
        _pipelineEnabled = json['pipelineEnabled'] as bool? ?? false;
        _analogEnvelopeEnabled = json['analogEnvelopeEnabled'] as bool? ?? false;
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
        // Restore pipeline + analog envelope state after config load
        if (_pipelineEnabled) {
          FfiBridge.instance.startPipeline();
        }
        if (_analogEnvelopeEnabled) {
          FfiBridge.instance.analogSetEnvelopeEnabled(true);
          _ensureAnalogSegments();
          // Auto-start pipeline if analog envelope needs it
          if (!_pipelineEnabled) {
            _pipelineEnabled = true;
            FfiBridge.instance.startPipeline();
          }
        }
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
        'pipelineEnabled': _pipelineEnabled,
        'analogEnvelopeEnabled': _analogEnvelopeEnabled,
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
        // FIX: P2-3: Reset EMA-smoothed Y-axis range on data clear.
        // Without this, switch Demo↔Real carries over old channel's
        // smoothed range → wrong Y-axis for several seconds.
        ch._smoothedYMin = null;
        ch._smoothedYMax = null;
        ch.yMin = -1;
        ch.yMax = 1;
      }
      // NOTE: Clear pyramid data on data reset
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
      // P2-4: Stream write via IOSink — avoids StringBuffer explosion for 250K+ points
      final file = File(path);
      final sink = file.openWrite(encoding: utf8);
      try {
        for (int c = 0; c < visibleChannels.length; c++) {
          if (c > 0) sink.write(',');
          sink.write('Time,${visibleChannels[c].deviceName} - ${visibleChannels[c].channelName}');
        }
        sink.writeln();

        int maxLen = visibleChannels.fold(0, (m, ch) => max(m, ch.data.length));
        for (int i = 0; i < maxLen; i++) {
          for (int c = 0; c < visibleChannels.length; c++) {
            if (c > 0) sink.write(',');
            final ch = visibleChannels[c];
            if (i < ch.data.length) {
              sink.write('${ch.data[i].x.toStringAsFixed(6)},${ch.data[i].y.toStringAsFixed(ch.decimals)}');
            } else {
              sink.write(',');
            }
          }
          sink.writeln();
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
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
      if (_analogEnvelopeEnabled) {
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
    if (_analogEnvelopeEnabled) {
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
    if (_analogEnvelopeEnabled) {
      final buf = StringBuffer();
      for (var i = 0; i < _channels.length; i++) {
        final info = FfiBridge.instance.analogDumpDebug(i);
        buf.writeln('═══ Channel $i ═══');
        buf.writeln(info);
        buf.writeln();
      }
      _pyramidDebugText = buf.toString();
    } else {
      _pyramidDebugText = 'AnalogSegment envelope is DISABLED.\nEnable "Analog Envelope" in toolbar to view pyramid state.';
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
          // Pipeline toggle (pre-computed envelope)
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _pipelineEnabled ? AppTheme.primary.withValues(alpha: 0.2) : AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(
                _pipelineEnabled ? Icons.memory : Icons.memory_outlined,
                color: _pipelineEnabled ? AppTheme.primary : AppTheme.textSecondary,
                size: 20,
              ),
            ),
            onPressed: _togglePipeline,
            tooltip: _pipelineEnabled ? 'Pipeline ON (zero-copy envelope)' : 'Pipeline OFF (per-channel query)',
          ),
          // AnalogSegment envelope toggle (f32 10-level 16^n pyramid)
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _analogEnvelopeEnabled ? Colors.purple.withValues(alpha: 0.2) : AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(
                _analogEnvelopeEnabled ? Icons.stacked_bar_chart : Icons.stacked_bar_chart_outlined,
                color: _analogEnvelopeEnabled ? Colors.purple : AppTheme.textSecondary,
                size: 20,
              ),
            ),
            onPressed: _toggleAnalogEnvelope,
            tooltip: _analogEnvelopeEnabled ? 'Analog Envelope ON (f32 pyramid)' : 'Analog Envelope OFF (f64)',
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
                      viewportRefreshCount: _viewportRefreshCount,
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
