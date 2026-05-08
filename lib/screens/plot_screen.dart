import 'dart:math';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart';
import 'package:file_picker/file_picker.dart';
import '../app/theme.dart';
import '../src/rust/api/device_api.dart';
import '../src/rust/api/debug_api.dart';
import '../src/rust/api/plot_api.dart';

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

enum AntiAliasingLevel { off, x2, x4, x8, x16 }

extension AALevelLabel on AntiAliasingLevel {
  String get label {
    switch (this) {
      case AntiAliasingLevel.off: return 'Off';
      case AntiAliasingLevel.x2: return '2×';
      case AntiAliasingLevel.x4: return '4×';
      case AntiAliasingLevel.x8: return '8×';
      case AntiAliasingLevel.x16: return '16×';
    }
  }

  double get scale {
    switch (this) {
      case AntiAliasingLevel.off: return 1.0;
      case AntiAliasingLevel.x2: return 2.0;
      case AntiAliasingLevel.x4: return 4.0;
      case AntiAliasingLevel.x8: return 8.0;
      case AntiAliasingLevel.x16: return 16.0;
    }
  }

  int get rasterizerTraces {
    switch (this) {
      case AntiAliasingLevel.off: return 0;
      case AntiAliasingLevel.x2: return 1;
      case AntiAliasingLevel.x4: return 2;
      case AntiAliasingLevel.x8: return 3;
      case AntiAliasingLevel.x16: return 4;
    }
  }
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
  List<_DataPoint> data;
  double currentValue;
  double yMin; // Per-channel Y range
  double yMax;
  double yMinManual; // User-specified Y range (if not auto)
  double yMaxManual;
  bool autoScaleY; // Per-channel auto-scale

  PlotChannel({
    required this.deviceId,
    required this.deviceName,
    required this.channelName,
    this.color = AppTheme.primary,
    this.visible = true,
    this.decimals = 3,
    this.showYAxis = true,
    this.lineStyle = LineStyle.line,
    List<_DataPoint>? data,
    this.currentValue = 0.0,
    this.yMin = 0,
    this.yMax = 1,
    this.yMinManual = -1,
    this.yMaxManual = 1,
    this.autoScaleY = true,
  }) : data = data ?? [];

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'channelName': channelName,
    'visible': visible,
    'decimals': decimals,
    'showYAxis': showYAxis,
    'lineStyle': lineStyle.name,
    'autoScaleY': autoScaleY,
    'yMinManual': yMinManual,
    'yMaxManual': yMaxManual,
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
    autoScaleY: json['autoScaleY'] as bool? ?? true,
    yMinManual: (json['yMinManual'] as num?)?.toDouble() ?? -1,
    yMaxManual: (json['yMaxManual'] as num?)?.toDouble() ?? 1,
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
  
  // ── Data ──
  List<PlotChannel> _channels = [];
  final int _maxPoints = 100000;

  // ── Axis config ──
  bool _autoScaleX = true;
  bool _autoScaleY = true; // Global Y auto-scale (fallback)
  double _xMin = 0;
  double _xMax = 10;
  double _yMin = -1; // Global Y range (used when no per-channel axis)
  double _yMax = 1;
  int _globalDecimals = 3; // Global decimal precision for axes

  // ── Scroll (oscilloscope) mode ──
  bool _scrollMode = false;         // true = oscilloscope sweep mode
  double _scrollWindowWidth = 10.0;  // visible X range in seconds
  double _scrollMinTime = 0.0;       // left edge of visible window

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

  // ── Y axis share ──
  bool _shareYAxis = false; // Each channel uses its own Y range

  // ── Anti-aliasing ──
  AntiAliasingLevel _aaLevel = AntiAliasingLevel.off;

  // ── Animation ──
  late Ticker _ticker;

  // ── Demo ──
  double _demoPhase = 0;
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
  ];

  // ── Config persistence ──
  static String get _configPath {
    final appData = Platform.environment['APPDATA'] ?? '';
    return '$appData\\VCR\\plot_config.json';
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _ticker.start();
    _initDemoChannels();
    _startDemoData();
    _loadConfig();
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
    ];
  }

  void _startDemoData() {
    _demoTimer?.cancel();
    _demoTimer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      if (!mounted || !_isPlaying) return;
      _demoPhase += 0.005;
      final t = _demoPhase;
      setState(() {
        for (int i = 0; i < _channels.length; i++) {
          final rng = Random();
          final noise = 0.05 * (rng.nextDouble() - 0.5);
          double val;
          switch (i) {
            case 0: val = 3.3 * sin(2 * pi * 0.5 * t) + noise; break;
            case 1: val = 2.0 * sin(2 * pi * 0.3 * t + pi / 4) + noise; break;
            case 2: val = 3.3 * sin(2 * pi * 0.5 * t) * 2.0 * sin(2 * pi * 0.3 * t + pi / 4) + noise; break;
            case 3: val = 25.0 + 10.0 * sin(2 * pi * 0.1 * t) + 3.0 * sin(2 * pi * 1.3 * t) + noise; break;
            case 4: val = 101.3 + 5.0 * sin(2 * pi * 0.07 * t + pi / 3) + 2.0 * cos(2 * pi * 0.8 * t) + noise; break;
            case 5: val = 5.0 + 2.0 * sin(2 * pi * 0.2 * t) + 1.0 * sin(2 * pi * 1.5 * t + pi / 6) + noise; break;
            case 6: val = 50.0 * sin(2 * pi * 0.15 * t) + 20.0 * cos(2 * pi * 0.9 * t) + noise; break;
            case 7: val = 3000.0 + 1500.0 * sin(2 * pi * 0.25 * t + pi / 2) + 500.0 * sin(2 * pi * 2.0 * t) + noise * 100; break;
            default: val = sin(t) + noise; break;
          }
          _channels[i].data.add(_DataPoint(t, val));
          _channels[i].currentValue = val;
          // Trim old data to prevent unbounded memory growth
          if (_channels[i].data.length > _maxPoints * 2) {
            _channels[i].data = _channels[i].data.sublist(_channels[i].data.length - _maxPoints);
          }
        }
        _totalPoints = _channels.fold(0, (sum, ch) => sum + ch.data.length);

        if (_scrollMode) {
          // Oscilloscope mode: auto-scroll window to latest data
          final latestX = _channels.isNotEmpty && _channels.first.data.isNotEmpty
              ? _channels.first.data.last.x
              : t;
          _scrollMinTime = (latestX - _scrollWindowWidth).clamp(0.0, latestX);
          _xMin = _scrollMinTime;
          _xMax = latestX;
        } else {
          if (_autoScaleX) _fitXAxis();
          if (_autoScaleY) _fitYAxis();
        }
      });
    });
  }

  void _startRealData() {
    _realDataTimer?.cancel();
    _realDataTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || !_isPlaying) return;

      // Get active sessions from Rust
      final activeDevices = debugGetActiveSessions();
      if (activeDevices.isEmpty) return;
      
      for (final deviceId in activeDevices) {
        // Get channel data from Rust plot API
        final channels = plotGetChannels(deviceId: deviceId);
        if (channels.isEmpty) continue;
        
        // Ensure channels exist in our list
        for (final chName in channels) {
          final existingIdx = _channels.indexWhere(
            (ch) => ch.deviceId == deviceId && ch.channelName == chName,
          );
          if (existingIdx == -1 && _autoAddChannels) {
            // Add new channel
            final colorIdx = _channels.length % _channelColors.length;
            _channels.add(PlotChannel(
              deviceId: deviceId,
              deviceName: deviceId,
              channelName: chName,
              color: _channelColors[colorIdx],
              decimals: 3,
              lineStyle: LineStyle.line,
            ));
          }
        }
        
        // Fetch data for each channel
        setState(() {
          final targetChannels = _channels.where((c) => c.deviceId == deviceId).toList();
          for (final ch in targetChannels) {
            final points = plotGetChannelData(deviceId: deviceId, channel: ch.channelName);
            ch.data = points.map((p) => _DataPoint(p.timestampMs / 1000.0, p.value)).toList();
            if (ch.data.isNotEmpty) {
              ch.currentValue = ch.data.last.y;
            }
            // Trim to max points to prevent unbounded growth
            if (ch.data.length > _maxPoints * 2) {
              ch.data = ch.data.sublist(ch.data.length - _maxPoints);
            }
          }
          _totalPoints = _channels.fold(0, (sum, ch) => sum + ch.data.length);

          if (_scrollMode) {
            // Auto-scroll window to latest data point
            double latestX = _scrollMinTime + _scrollWindowWidth;
            final visibleChs = _channels.where((c) => c.visible && c.data.isNotEmpty).toList();
            for (final ch in visibleChs) {
              if (ch.data.last.x > latestX) latestX = ch.data.last.x;
            }
            _scrollMinTime = (latestX - _scrollWindowWidth).clamp(0.0, latestX);
            _xMin = _scrollMinTime;
            _xMax = latestX;
          } else {
            if (_autoScaleX) _fitXAxis();
            if (_autoScaleY) _fitYAxis();
          }
        });
      }
    });
  }

  void _toggleDataSource() {
    setState(() {
      _useRealData = !_useRealData;
      if (_useRealData) {
        _demoTimer?.cancel();
        _channels.clear();
        _startRealData();
      } else {
        _realDataTimer?.cancel();
        _channels.clear();
        _initDemoChannels();
        _startDemoData();
      }
    });
  }

  void _fitXAxis() {
    if (_scrollMode) return; // X axis is controlled by scroll window
    double minVal = double.infinity;
    double maxVal = double.negativeInfinity;
    for (final ch in _channels) {
      if (!ch.visible || ch.data.isEmpty) continue;
      minVal = min(minVal, ch.data.first.x);
      maxVal = max(maxVal, ch.data.last.x);
    }
    if (minVal.isInfinite) { minVal = 0; maxVal = 10; }
    final padding = (maxVal - minVal) * 0.02;
    _xMin = minVal - padding;
    _xMax = maxVal + padding;
  }

  void _fitYAxisForChannel(int chIdx) {
    final ch = _channels[chIdx];
    if (!ch.visible || ch.data.isEmpty) return;
    double minVal = double.infinity;
    double maxVal = double.negativeInfinity;
    for (final pt in ch.data) {
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
    for (int i = 0; i < _channels.length; i++) {
      _fitYAxisForChannel(i);
    }
    if (_yMin.isInfinite) { _yMin = -1; _yMax = 1; }
  }

  int _leftYAxisCount() {
    final total = _channels.where((ch) => ch.visible && ch.showYAxis).length;
    return (total + 1) ~/ 2; // ceil(total/2)
  }

  int _rightYAxisCount() {
    final total = _channels.where((ch) => ch.visible && ch.showYAxis).length;
    return total ~/ 2; // floor(total/2)
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
  (double, double) _getDataXRange() {
    double minVal = double.infinity;
    double maxVal = double.negativeInfinity;
    for (final ch in _channels) {
      if (!ch.visible || ch.data.isEmpty) continue;
      minVal = min(minVal, ch.data.first.x);
      maxVal = max(maxVal, ch.data.last.x);
    }
    if (minVal.isInfinite) return (0.0, 10.0);
    return (minVal, maxVal);
  }

  /// Find which channel's Y-axis is closest to cursor X position.
  /// Returns -1 if none.
  int _findYAxisChannelAtX(double cursorX, double plotLeft, double plotW) {
    final yAxisChannels = _channels.asMap().entries
        .where((e) => e.value.visible && e.value.showYAxis)
        .map((e) => e.key)
        .toList();
    if (yAxisChannels.isEmpty) return -1;
    const hitHalfW = 30.0; // Half of the hit-test width for each axis slot

    // Iterate each visual axis slot as rendered in _paintInternal.
    // ci = 0,1,2,3 → left,right,left,right
    // left slot N x-position: plotLeft - N*45 - 2  (x of the colored axis line)
    // right slot N x-position: plotLeft + plotW + N*45 + 2
    for (int ci = 0; ci < yAxisChannels.length; ci++) {
      final isLeft = ci % 2 == 0;
      final slotIdx = ci ~/ 2;
      double axisX;
      if (isLeft) {
        // x of left axis line N: plotLeft - N*45 - 2
        axisX = plotLeft - slotIdx * 45.0 - 2.0;
      } else {
        // x of right axis line N: plotLeft + plotW + N*45 + 2
        axisX = plotLeft + plotW + slotIdx * 45.0 + 2.0;
      }
      // Use the colored axis line as the hit target (± hitHalfW on each side)
      if ((cursorX - axisX).abs() < hitHalfW) {
        return yAxisChannels[ci];
      }
    }
    return -1;
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
            final c = chConfigs[i] as Map<String, dynamic>;
            _channels[i].visible = c['visible'] as bool? ?? true;
            _channels[i].decimals = c['decimals'] as int? ?? 3;
            _channels[i].showYAxis = c['showYAxis'] as bool? ?? true;
            _channels[i].lineStyle = LineStyle.values.firstWhere(
              (e) => e.name == c['lineStyle'], orElse: () => LineStyle.line);
          }
        }
        final aaIdx = json['aaLevel'] as int?;
        if (aaIdx != null && aaIdx >= 0 && aaIdx < AntiAliasingLevel.values.length) {
          _aaLevel = AntiAliasingLevel.values[aaIdx];
        }
        _panelWidth = (json['panelWidth'] as num?)?.toDouble() ?? 220.0;
        _shareYAxis = json['shareYAxis'] as bool? ?? true;
        _scrollMode = json['scrollMode'] as bool? ?? false;
        _scrollWindowWidth = (json['scrollWindowWidth'] as num?)?.toDouble() ?? 10.0;
        _scrollMinTime = (json['scrollMinTime'] as num?)?.toDouble() ?? 0.0;
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  Future<void> _saveConfig() async {
    try {
      final file = File(_configPath);
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'channels': _channels.map((ch) => ch.toJson()).toList(),
        'aaLevel': _aaLevel.index,
        'panelWidth': _panelWidth,
        'shareYAxis': _shareYAxis,
        'scrollMode': _scrollMode,
        'scrollWindowWidth': _scrollWindowWidth,
        'scrollMinTime': _scrollMinTime,
      }));
      // Also sync to app_config.json so settings screen picks it up
      final appData = Platform.environment['APPDATA'] ?? '';
      final appFile = File('$appData\\VCR\\app_config.json');
      Map<String, dynamic> appConfig = {};
      if (await appFile.exists()) {
        appConfig = jsonDecode(await appFile.readAsString()) as Map<String, dynamic>;
      }
      appConfig['plotAALevel'] = _aaLevel.index;
      if (!await appFile.parent.exists()) await appFile.parent.create(recursive: true);
      await appFile.writeAsString(jsonEncode(appConfig));
    } catch (_) {}
  }

  void _setAALevel(AntiAliasingLevel level) {
    setState(() => _aaLevel = level);
    _saveConfig();
  }

  // ── CSV Export/Import ──

  Future<void> _exportCsv() async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Waveform Data',
      fileName: 'waveform_${DateTime.now().millisecondsSinceEpoch}.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (path == null) return;

    final visibleChannels = _channels.where((ch) => ch.visible && ch.data.isNotEmpty).toList();
    if (visibleChannels.isEmpty) return;

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

  // ── Scroll mode settings dialog ──
  void _showScrollModeSettings() {
    final widthCtrl = TextEditingController(text: _scrollWindowWidth.toStringAsFixed(1));
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
              children: [1.0, 2.0, 5.0, 10.0, 20.0, 30.0, 60.0, 120.0].map((w) => ActionChip(
                label: Text('${w.toStringAsFixed(w == w.roundToDouble() ? 0 : 1)}s', style: const TextStyle(fontSize: 12)),
                onPressed: () { widthCtrl.text = w.toStringAsFixed(w == w.roundToDouble() ? 0 : 1); },
              )).toList(),
            ),
            if (_scrollMode) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Text('Current window: ${_scrollMinTime.toStringAsFixed(2)}s → ${(_scrollMinTime + _scrollWindowWidth).toStringAsFixed(2)}s',
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
                    _scrollMinTime = (latest - _scrollWindowWidth).clamp(0.0, latest);
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
        title: const Text('Plot'),
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
            onPressed: () => setState(() => _isPlaying = !_isPlaying),
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
                ? 'Scroll Mode ON — ${_scrollWindowWidth.toStringAsFixed(1)}s window'
                : 'Scroll Mode (Oscilloscope Sweep)',
          ),
          // Channel config
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showChannelConfig,
            tooltip: 'Channel Config',
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
          // Resize handle
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
                width: 6,
                color: AppTheme.border,
                child: Center(
                  child: Container(
                    width: 2,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppTheme.textSecondary.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(1),
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
    return Container(
      color: const Color(0xFF0A0E14),
      child: LayoutBuilder(
        builder: (context, constraints) {
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
                final targetCh = _findYAxisChannelAtX(pos.dx, plotLeft, plotW);
                if (targetCh >= 0) {
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
                    // In scroll mode: only X-axis panning (drag viewport left/right)
                    final xRange = _dragStartXMax - _dragStartXMin;
                    _scrollMinTime = _dragStartScrollMin - dx / w * xRange;
                    _xMin = _scrollMinTime;
                    _xMax = _scrollMinTime + _scrollWindowWidth;
                    // Clamp: don't drag window before earliest data point
                    double earliestX = double.infinity;
                    for (final ch in _channels.where((c) => c.data.isNotEmpty)) {
                      if (ch.data.first.x < earliestX) earliestX = ch.data.first.x;
                    }
                    if (earliestX.isFinite) {
                      final minScrollMin = earliestX;
                      if (_scrollMinTime < minScrollMin) {
                        _scrollMinTime = minScrollMin;
                        _xMin = _scrollMinTime;
                        _xMax = _scrollMinTime + _scrollWindowWidth;
                      }
                    }
                    // Clamp: don't drag window beyond latest data
                    double latestX = double.negativeInfinity;
                    for (final ch in _channels.where((c) => c.data.isNotEmpty)) {
                      if (ch.data.last.x > latestX) latestX = ch.data.last.x;
                    }
                    if (latestX.isFinite) {
                      final maxScrollMin = latestX - _scrollWindowWidth;
                      if (_scrollMinTime > maxScrollMin) {
                        _scrollMinTime = maxScrollMin;
                        _xMin = _scrollMinTime;
                        _xMax = _scrollMinTime + _scrollWindowWidth;
                      }
                    }
                  } else {
                    // Normal mode: pan X and Y freely
                    final xRange = _dragStartXMax - _dragStartXMin;
                    final yRange = _dragStartYMax - _dragStartYMin;
                    _xMin = _dragStartXMin - dx / w * xRange;
                    _xMax = _dragStartXMax - dx / w * xRange;
                    _yMin = _dragStartYMin + dy / h * yRange;
                    _yMax = _dragStartYMax + dy / h * yRange;
                  }
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
                    final plotTop = _plotTop();
                    final plotLeft = _plotLeft();
                    final plotRight = _plotRight();
                    final plotW = w - plotLeft - plotRight;
                    final targetCh = _findYAxisChannelAtX(pos.dx, plotLeft, plotW);
                    final nearRightYAxis = plotW > 0 && pos.dx > w - plotRight && _rightSlotCount() > 0;
                    // Zoom factor: scroll up = zoom in (factor < 1), scroll down = zoom out (factor > 1)
                    final factor = dy > 0 ? 1.1 : 0.9;

                    setState(() {
                      if (nearXAxis) {
                        // X-axis scroll: zoom X only
                        _autoScaleX = false;
                        final center = (_xMin + _xMax) / 2;
                        final range = (_xMax - _xMin) * factor;
                        // Clamp: zoom out max 3× data range, zoom in min _minVisibleRange
                        final (dataXMin2, dataXMax2) = _getDataXRange();
                        final maxRange = (dataXMax2 - dataXMin2) * 3.0;
                        final clampedRange = range.clamp(_minVisibleRange, maxRange.isFinite && maxRange > 0 ? maxRange : range);
                        _xMin = center - clampedRange / 2;
                        _xMax = center + clampedRange / 2;
                      } else if (targetCh >= 0 && !_shareYAxis) {
                        // Per-channel Y zoom (near specific channel's Y axis) — only when NOT sharing Y axis
                        final ch = _channels[targetCh];
                        final chYMin = ch.autoScaleY ? ch.yMin : ch.yMinManual;
                        final chYMax = ch.autoScaleY ? ch.yMax : ch.yMaxManual;
                        final center = (chYMin + chYMax) / 2;
                        final range = chYMax - chYMin;
                        ch.yMin = center - range / 2 * factor;
                        ch.yMax = center + range / 2 * factor;
                      } else if (targetCh >= 0 && _shareYAxis) {
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
                        // Clamp X zoom range same as X-axis-only zoom
                        final (dataXMin2, dataXMax2) = _getDataXRange();
                        final maxXRange = (dataXMax2 - dataXMin2) * 3.0;
                        final clampedXRange = xRange.clamp(_minVisibleRange, maxXRange.isFinite && maxXRange > 0 ? maxXRange : xRange);
                        _xMin = xCenter - clampedXRange / 2;
                        _xMax = xCenter + clampedXRange / 2;
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
                    channels: _channels,
                    xMin: _xMin, xMax: _xMax,
                    yMin: _yMin, yMax: _yMax,
                    mousePosition: _mousePosition,
                    fps: _fps,
                    totalPoints: _totalPoints,
                    aaScale: _aaLevel.scale,
                    globalDecimals: _globalDecimals,
                    shareYAxis: _shareYAxis,
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
    final (dataXMin, dataXMax) = _getDataXRange();
    if (dataXMin.isNaN || dataXMax.isNaN || dataXMin.isInfinite || dataXMax.isInfinite) {
      return const SizedBox.shrink();
    }
    
    final totalRange = dataXMax - dataXMin;
    if (totalRange <= 0) return const SizedBox.shrink();

    final scrollbarHeight = 36.0;
    final trackPadding = 16.0; // Padding on each side so handles are always visible
    final plotLeft = trackPadding;
    final plotRight = trackPadding;
    final trackWidth = constraints.maxWidth - plotLeft - plotRight;
    if (trackWidth <= 0) return const SizedBox.shrink();

    // Current visible window position and size
    // Clamp visible range to data range for scrollbar display
    final visibleMin = _xMin.clamp(dataXMin, dataXMax);
    final visibleMax = _xMax.clamp(dataXMin, dataXMax);
    if (visibleMin >= visibleMax) return const SizedBox.shrink();

    var thumbLeft = plotLeft + ((visibleMin - dataXMin) / totalRange) * trackWidth;
    var thumbRight = plotLeft + ((visibleMax - dataXMin) / totalRange) * trackWidth;
    var thumbWidth = thumbRight - thumbLeft;

    // If visible window exceeds data range (zoomed out past data),
    // the thumb would be wider than track — clamp it
    if (thumbWidth > trackWidth) {
      thumbLeft = plotLeft;
      thumbRight = plotLeft + trackWidth;
      thumbWidth = trackWidth;
    }
    // Ensure minimum thumb width so it's always interactable
    if (thumbWidth < 20) {
      final center = (thumbLeft + thumbRight) / 2;
      thumbLeft = (center - 10).clamp(plotLeft, plotLeft + trackWidth - 20);
      thumbRight = thumbLeft + 20;
      thumbWidth = 20.0;
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
                      dataXMin: dataXMin,
                      dataXMax: dataXMax,
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
                      final newMin = _scrollbarDragStartXMin + dxRatio * totalRange;
                      final newMax = newMin + range;
                      _xMin = newMin;
                      _xMax = newMax;
                      if (_scrollMode) {
                        _scrollMinTime = newMin.clamp(0.0, double.maxFinite);
                        _scrollWindowWidth = range;
                      } else {
                        _autoScaleX = false;
                      }
                      setState(() {});
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
                Positioned(
                  left: thumbLeft,
                  width: thumbWidth > 40 ? 12.0 : (thumbWidth / 3).clamp(6.0, 12.0),
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
                        if (newMin >= _scrollbarDragStartXMax - _minVisibleRange) {
                          newMin = _scrollbarDragStartXMax - _minVisibleRange;
                        }
                        _xMin = newMin;
                        if (_scrollMode) {
                          _scrollMinTime = newMin.clamp(0.0, double.maxFinite);
                          _scrollWindowWidth = _scrollbarDragStartXMax - newMin;
                        } else {
                          _autoScaleX = false;
                        }
                        setState(() {});
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
                          child: Icon(Icons.chevron_left, size: 10, color: Colors.black87),
                        ),
                      ),
                    ),
                  ),
                ),
                // Right edge handle — always inside thumb right edge, white on blue
                Positioned(
                  left: thumbRight - (thumbWidth > 40 ? 12.0 : (thumbWidth / 3).clamp(6.0, 12.0)),
                  width: thumbWidth > 40 ? 12.0 : (thumbWidth / 3).clamp(6.0, 12.0),
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
                        if (newMax <= _scrollbarDragStartXMin + _minVisibleRange) {
                          newMax = _scrollbarDragStartXMin + _minVisibleRange;
                        }
                        _xMax = newMax;
                        if (_scrollMode) {
                          _scrollWindowWidth = newMax - _scrollbarDragStartXMin;
                        } else {
                          _autoScaleX = false;
                        }
                        setState(() {});
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
                          child: Icon(Icons.chevron_right, size: 10, color: Colors.black87),
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
              itemCount: _channels.length,
              itemBuilder: (context, index) {
                final ch = _channels[index];
                return GestureDetector(
                  // Left-click: toggle visibility
                  onTap: () {
                    setState(() => ch.visible = !ch.visible);
                    _saveConfig();
                  },
                  // Right-click: channel config popup
                  onSecondaryTapUp: (_) => _showSingleChannelConfig(index),
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
                                  onPressed: () => _removeChannel(index),
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
                  activeColor: AppTheme.primary,
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
                        value: ch.decimals,
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
                        value: ch.lineStyle,
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
                                value: ch.decimals,
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
                                value: ch.lineStyle,
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
      if (!ch.visible || ch.data.isEmpty) continue;
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
      // Downsample for minimap performance: max ~500 points per channel
      final step = (ch.data.length / 500).ceil().clamp(1, ch.data.length);
      for (int i = 0; i < ch.data.length; i += step) {
        final pt = ch.data[i];
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

  double _calcChannelYMin(List<PlotChannel> chs) {
    double minVal = double.infinity;
    for (final ch in chs) {
      if (!ch.visible || ch.data.isEmpty) continue;
      for (final pt in ch.data) {
        if (pt.y < minVal) minVal = pt.y;
      }
    }
    return minVal.isInfinite ? 0.0 : minVal;
  }

  double _calcChannelYMax(List<PlotChannel> chs) {
    double maxVal = double.negativeInfinity;
    for (final ch in chs) {
      if (!ch.visible || ch.data.isEmpty) continue;
      for (final pt in ch.data) {
        if (pt.y > maxVal) maxVal = pt.y;
      }
    }
    return maxVal.isInfinite ? 1.0 : maxVal;
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
        canvas.drawImageRect(image, srcRect, dstRect, Paint()..filterQuality = FilterQuality.high);
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
        text: TextSpan(text: _formatTick(tick), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(sx - tp.width / 2, h - plotBottom + 4));
    }

    // ── Per-channel Y axis labels ──
    // If multiple channels show Y-axis, render them on alternating sides with their color
    if (yAxisChannels.length <= 1) {
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
    final allData = ch.data;
    if (allData.isEmpty) return;

    // Use per-channel Y transform
    double yTransform(double y) {
      if (chYMax == chYMin) return h / 2;
      return h - (y - chYMin) / (chYMax - chYMin) * h;
    }

    // Viewport clip: only pass data points within visible X range + 1 point margin
    final xRange = xMax - xMin;
    final margin = xRange * 0.01; // 1% margin on each side
    int startIdx = 0;
    int endIdx = allData.length - 1;
    // Binary search for start
    int lo = 0, hi = allData.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (allData[mid].x < xMin - margin) lo = mid + 1; else hi = mid;
    }
    startIdx = lo > 0 ? lo - 1 : 0; // include 1 point before for line continuity
    // Binary search for end
    lo = startIdx; hi = allData.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (allData[mid].x > xMax + margin) hi = mid - 1; else lo = mid;
    }
    endIdx = lo < allData.length - 1 ? lo + 1 : allData.length - 1; // include 1 point after
    final data = allData.sublist(startIdx, endIdx + 1);

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

  void _drawDots(Canvas canvas, PlotChannel ch, List<_DataPoint> data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale) {
    final paint = Paint()..color = ch.color;
    for (final pt in data) {
      final sx = _xToScreen(pt.x, w) + ox;
      final sy = yTransform(pt.y) + oy;
      canvas.drawCircle(Offset(sx, sy), 2.0 / scale, paint);
    }
  }

  void _drawDotLine(Canvas canvas, PlotChannel ch, List<_DataPoint> data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale) {
    // Draw connecting line first (thinner, dimmer)
    final linePaint = Paint()
      ..color = ch.color.withValues(alpha: 0.5)
      ..strokeWidth = 1.0 / scale
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
      canvas.drawCircle(Offset(sx, sy), 2.5 / scale, dotPaint);
    }
  }

  void _drawLine(Canvas canvas, PlotChannel ch, List<_DataPoint> data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale) {
    final paint = Paint()
      ..color = ch.color
      ..strokeWidth = 1.5 / scale
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

  String _formatTick(double val, [int decimals = 3]) {
    if (val.abs() >= 1000) return val.toStringAsFixed(0);
    if (val.abs() >= 1) return val.toStringAsFixed(decimals.clamp(0, 4));
    if (val.abs() >= 0.01) return val.toStringAsFixed(decimals.clamp(2, 6));
    return val.toStringAsExponential(2);
  }

  @override
  bool shouldRepaint(covariant _PlotPainter oldDelegate) {
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
          a.data.length != b.data.length) {
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
}
