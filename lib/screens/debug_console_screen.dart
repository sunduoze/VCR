import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import '../widgets/main_shell.dart' show VcrLogo;
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gbk_codec/gbk_codec.dart';
import '../app/theme.dart';
import '../src/rust/api/device_api.dart';
import '../src/rust/api/debug_api.dart';
import '../src/rust/core/device/models.dart';
import '../src/rust/core/session/debug_session.dart';
import 'settings_screen.dart' show AppConfig;

// ============================================================================
// 常量
const int kDefaultBufferSize = 200 * 1024; // 200 KB
const int kPollIntervalMs = 200; // 日志轮询间隔
const int kMaxCommandHistory = 10;

/// Default SCPI commands always shown at front of command history
const List<String> kDefaultCommands = [
  'READ?',
  'VOLT:DC:NPLC 10',
  '*IDN?',
  '*RST',
];

// ============================================================================
// Per-device console state
// Each connected device gets its own independent state:
// DTR/RTS/Break, command history, TX/RX counters & rates, config settings, etc.
// ============================================================================
class ConsoleDeviceState {
  // ── Connection ──
  bool connected = false;
  bool isSerialDevice = false;

  // ── Signal states (serial only) ──
  bool dtrEnabled = false;
  bool rtsEnabled = false;
  bool breakEnabled = false;

  // ── TX/RX counters & rates ──
  int txBytes = 0;
  int rxBytes = 0;
  int txPackets = 0;
  int rxPackets = 0;
  int lastLogCount = 0;
  double txRate = 0.0;
  double rxRate = 0.0;
  int lastTxBytes = 0;
  int lastRxBytes = 0;
  DateTime lastRateTime = DateTime.now();

  // ── Log buffer size for this device ──
  int bufferSize = kDefaultBufferSize;

  // ── Command history ──
  List<String> commandHistory = List<String>.from(kDefaultCommands);

  // ── UI display settings ──
  bool showTimestamp = true;
  bool showHex = false;
  bool showTx = true;
  bool showRx = true;
  bool autoScroll = true;
  String sendFormat = 'ASCII'; // ASCII / HEX / FILE
  String lineEnding = 'LF'; // None / CR / LF / CRLF
  String encoding = 'UTF-8'; // UTF-8 / GBK

  // ── Continuous send ──
  bool continuousSending = false;
  bool continuousStopRequested = false;
  int continuousSendInterval = 10; // ms
  int continuousSendCount = 0;
  int continuousSendTarget = 100;
  List<int>? continuousSendBytes;
  String? continuousSendDeviceId; // Device ID when continuous send started

  // Serialise to JSON (one device block in console_config.json)
  Map<String, dynamic> toJson() => {
    'dtrEnabled': dtrEnabled,
    'rtsEnabled': rtsEnabled,
    'breakEnabled': breakEnabled,
    'bufferSize': bufferSize,
    'showTimestamp': showTimestamp,
    'showHex': showHex,
    'showTx': showTx,
    'showRx': showRx,
    'autoScroll': autoScroll,
    'sendFormat': sendFormat,
    'lineEnding': lineEnding,
    'encoding': encoding,
    'continuousSendInterval': continuousSendInterval,
    'continuousSendTarget': continuousSendTarget,
    // Save only user-entered commands (exclude defaults)
    'commandHistory': commandHistory.where((c) => !kDefaultCommands.contains(c)).toList(),
  };

  // Restore from JSON
  void fromJson(Map<String, dynamic> json) {
    dtrEnabled = json['dtrEnabled'] as bool? ?? dtrEnabled;
    rtsEnabled = json['rtsEnabled'] as bool? ?? rtsEnabled;
    breakEnabled = json['breakEnabled'] as bool? ?? breakEnabled;
    bufferSize = json['bufferSize'] as int? ?? bufferSize;
    showTimestamp = json['showTimestamp'] as bool? ?? showTimestamp;
    showHex = json['showHex'] as bool? ?? showHex;
    showTx = json['showTx'] as bool? ?? showTx;
    showRx = json['showRx'] as bool? ?? showRx;
    autoScroll = json['autoScroll'] as bool? ?? autoScroll;
    sendFormat = json['sendFormat'] as String? ?? sendFormat;
    lineEnding = json['lineEnding'] as String? ?? lineEnding;
    encoding = json['encoding'] as String? ?? encoding;
    continuousSendInterval =
        json['continuousSendInterval'] as int? ?? continuousSendInterval;
    continuousSendTarget =
        json['continuousSendTarget'] as int? ?? continuousSendTarget;
    commandHistory =
        (json['commandHistory'] as List?)?.cast<String>() ?? [];
    // Always ensure default commands are at the front
    _prependDefaultCommands();
  }

  /// Ensure kDefaultCommands appear at the front of commandHistory
  void _prependDefaultCommands() {
    for (final cmd in kDefaultCommands.reversed) {
      commandHistory.remove(cmd); // Remove if already present (old position)
      commandHistory.insert(0, cmd); // Re-insert at front
    }
    // Trim duplicates after prepending
    final seen = <String>{};
    commandHistory = commandHistory.where((c) => seen.add(c)).toList();
  }

  // Reset counters (used after clear or full recalc)
  void resetCounters() {
    txBytes = 0;
    rxBytes = 0;
    txPackets = 0;
    rxPackets = 0;
    lastLogCount = 0;
    txRate = 0;
    rxRate = 0;
    lastTxBytes = 0;
    lastRxBytes = 0;
    lastRateTime = DateTime.now();
  }

  // Update rates using EMA
  void updateRates(int newTx, int newRx) {
    final now = DateTime.now();
    final dt = now.difference(lastRateTime).inMicroseconds / 1e6;
    if (dt > 0) {
      final instantTx = (newTx - lastTxBytes) / dt;
      final instantRx = (newRx - lastRxBytes) / dt;
      const alpha = 0.33;
      txRate = alpha * instantTx + (1 - alpha) * txRate;
      rxRate = alpha * instantRx + (1 - alpha) * rxRate;
      if (txRate < 0) txRate = 0;
      if (rxRate < 0) rxRate = 0;
    }
    lastTxBytes = newTx;
    lastRxBytes = newRx;
    lastRateTime = now;
  }
}

// ============================================================================
// DebugConsoleScreen — per-device independent state
// ============================================================================
class DebugConsoleScreen extends StatefulWidget {
  final String? deviceId;
  const DebugConsoleScreen({super.key, this.deviceId});

  /// Called by MainShell when switching away from Console tab
  static Future<void> saveCurrentState() async {
    await _DebugConsoleScreenState._instance?._saveGlobalConfig();
  }

  @override
  State<DebugConsoleScreen> createState() => _DebugConsoleScreenState();
}

class _DebugConsoleScreenState extends State<DebugConsoleScreen>
    with WidgetsBindingObserver {
  // ── Per-device state map ──
  final Map<String, ConsoleDeviceState> _deviceStates = {};

  // ── Static reference for cross-widget communication ──
  static _DebugConsoleScreenState? _instance;

  String? _selectedDeviceId;

  // ── Global (shared) settings ──
  String? _lastExportDir;
  List<String> _deviceSortOrder = [];
  final List<int> _bufferSizePresets = [
    200 * 1024,
    500 * 1024,
    1024 * 1024,
    2 * 1024 * 1024,
    5 * 1024 * 1024,
    10 * 1024 * 1024,
    50 * 1024 * 1024,
    100 * 1024 * 1024,
    500 * 1024 * 1024,
  ];

  // ── Controllers / scroll ──
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  final TextEditingController _bufferSizeInputController =
      TextEditingController();

  bool _isProgrammaticScroll = false;

  // ── Log change detection (for conditional setState) ──
  int _lastLogCount = 0;

  // ── User scroll detection (for smart auto-scroll) ──
  bool _userScrolledUp = false;

  // HEX formatter
  static final _hexFormatter = FilteringTextInputFormatter.allow(
    RegExp(r'[0-9A-Fa-f ]'),
  );

  static String get _configPath {
    final appData = Platform.environment['APPDATA'] ?? '';
    return '$appData\\VCR\\console_config.json';
  }

  // ── Current device state accessor ──
  ConsoleDeviceState get _cs {
    if (_selectedDeviceId == null) return _ensureState('');
    return _deviceStates.putIfAbsent(
      _selectedDeviceId!,
      () => ConsoleDeviceState(),
    );
  }

  ConsoleDeviceState _ensureState(String deviceId) {
    return _deviceStates.putIfAbsent(deviceId, () => ConsoleDeviceState());
  }

  // ── Convenience getters (forwarded to current device state) ──
  bool get _connected => _cs.connected;

  @override
  void initState() {
    super.initState();
    _instance = this;
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScrollPositionChanged);
    // Start low-freq state sync (device connection status updates even when not connected)
    _startStateSync();
    // Start async initialization
    _initializeAsync();
  }

  /// Async initialization: load config, then restore last selected device
  Future<void> _initializeAsync() async {
    await _loadGlobalConfig();
    await _loadSortOrder();

    // Load persisted signal/display/send settings for all devices
    final devices = listDevices();
    for (final d in devices) {
      if (_deviceStates.containsKey(d.id)) continue; // already loaded by config
      await _loadSignalStates(d.id);
    }

    // Now restore last selected device
    await _restoreLastSelectedDevice();

    // Sync all devices' connection/isSerial state from Rust
    _syncDeviceStates();

    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Save config when app goes to background or is closed
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveGlobalConfig(); // fire-and-forget, best effort
    }
  }

  @override
  void dispose() {
    // Save all device configs before disposing
    _saveGlobalConfig(); // fire-and-forget

    _instance = null;
    WidgetsBinding.instance.removeObserver(this);

    // Stop polling and continuous send
    _stopPolling();
    _stateSyncTimer?.cancel();
    _stateSyncTimer = null;
    _cs.continuousStopRequested = true;
    _cs.continuousSending = false;
    _cs.continuousSendBytes = null;
    _cs.continuousSendDeviceId = null;

    // Dispose controllers
    _scrollController.removeListener(_onScrollPositionChanged);
    _scrollController.dispose();
    _inputController.dispose();
    _inputFocusNode.dispose();
    _bufferSizeInputController.dispose();
    super.dispose();
  }

  Future<void> _restoreLastSelectedDevice() async {
    // DEBUG
    final args = ModalRoute.of(context)?.settings.arguments;
    debugPrint('[DEBUG] _restoreLastSelectedDevice called');
    debugPrint('[DEBUG]   widget.deviceId = ${widget.deviceId}');
    debugPrint('[DEBUG]   route args = $args');

    final devices = listDevices();
    debugPrint('[DEBUG]   devices.length = ${devices.length}');
    debugPrint(
      '[DEBUG]   devices[0].id = ${devices.isNotEmpty ? devices.first.id : "(empty)"}',
    );

    // Determine which device to select
    String? targetDeviceId;
    if (widget.deviceId != null &&
        devices.any((d) => d.id == widget.deviceId)) {
      // Navigation from device_list_screen: use the passed-in device ID
      targetDeviceId = widget.deviceId;
      debugPrint('[DEBUG]   Using widget.deviceId: $targetDeviceId');
    } else {
      // Normal tab switch: try to restore from saved config
      final savedDeviceId = await _getLastSelectedDeviceId();
      debugPrint('[DEBUG]   savedDeviceId from config = $savedDeviceId');
      if (savedDeviceId != null && devices.any((d) => d.id == savedDeviceId)) {
        targetDeviceId = savedDeviceId;
        debugPrint('[DEBUG]   Using savedDeviceId: $targetDeviceId');
      }
    }

    // Fall back to first device if needed
    targetDeviceId ??= devices.isNotEmpty ? devices.first.id : null;
    debugPrint('[DEBUG]   Final targetDeviceId = $targetDeviceId');

    if (targetDeviceId != null) {
      debugPrint('[DEBUG]   Calling _selectDevice($targetDeviceId)');
      await _selectDevice(targetDeviceId, loadFromRust: true);
    }
  }

  Future<String?> _getLastSelectedDeviceId() async {
    try {
      final file = File(_configPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        return json['lastSelectedDeviceId'] as String?;
      }
    } catch (e) {
      debugPrint('Failed to get last selected device ID: $e');
    }
    return null;
  }

  // ── Device switching: save old, load new ──
  Future<void> _selectDevice(
    String deviceId, {
    bool loadFromRust = false,
  }) async {
    // Stop continuous send on current device before switching
    final oldCs = _selectedDeviceId != null
        ? _deviceStates[_selectedDeviceId!]
        : null;
    if (oldCs != null && oldCs.continuousSending) {
      oldCs.continuousStopRequested = true;
      oldCs.continuousSending = false;
      oldCs.continuousSendBytes = null;
    }

    // Persist current device's state BEFORE switching.
    // Must await so the file is written before we overwrite it.
    await _saveSignalStates();
    _selectedDeviceId = deviceId;

    // Load new device's state from disk (must await before Rust state overwrites it).
    await _loadSignalStates(deviceId);

    final cs = _cs;

    if (loadFromRust) {
      cs.connected = isDeviceConnected(deviceId: deviceId);
      final device = getDevice(deviceId: deviceId);
      cs.isSerialDevice =
          device != null && device.connectionType == ConnectionType.serial;

      if (!cs.connected) {
        // Not connected: clear live signals but keep persisted preferences
      } else if (cs.isSerialDevice) {
        _applySignalStates();
      } else {
        cs.dtrEnabled = false;
        cs.rtsEnabled = false;
        cs.breakEnabled = false;
      }

      if (cs.connected) {
        final log = debugGetLog(deviceId: deviceId);
        _recalcCounters(cs, log);
      }
    }

    _bufferSizeInputController.text = _formatBufferSizeInput(cs.bufferSize);
    if (mounted) setState(() {});
  }

  // ── Signal state application on connect ──
  void _applySignalStates() {
    final cs = _cs;
    if (!cs.connected || !cs.isSerialDevice || _selectedDeviceId == null)
      return;
    if (cs.dtrEnabled) serialSetDtr(deviceId: _selectedDeviceId!, level: true);
    if (cs.rtsEnabled) serialSetRts(deviceId: _selectedDeviceId!, level: true);
    if (cs.breakEnabled) serialSetBreak(deviceId: _selectedDeviceId!);
  }

  // ── Save/restore signal states to disk ──
  Future<void> _saveSignalStates() async {
    if (_selectedDeviceId == null) return;
    final cs = _cs;
    try {
      final file = File(_configPath);
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);

      Map<String, dynamic> config = {};
      if (await file.exists()) {
        try {
          config =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        } catch (e) {
          debugPrint('Failed to parse config file: $e');
        }
      }

      // Save per-device state block
      final deviceConfigs = (config['devices'] as Map<String, dynamic>?) ?? {};
      deviceConfigs[_selectedDeviceId!] = cs.toJson();
      config['devices'] = deviceConfigs;
      config['lastSelectedDeviceId'] = _selectedDeviceId;

      await file.writeAsString(jsonEncode(config));
    } catch (e) {
      debugPrint('Failed to save signal states: $e');
    }
  }

  Future<void> _loadSignalStates(String deviceId) async {
    final cs = _ensureState(deviceId);
    try {
      final file = File(_configPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final deviceConfigs = json['devices'] as Map<String, dynamic>?;
        if (deviceConfigs != null && deviceConfigs.containsKey(deviceId)) {
          cs.fromJson(deviceConfigs[deviceId] as Map<String, dynamic>);
        }
      }
    } catch (e) {
      debugPrint('Failed to load signal states for device $deviceId: $e');
    }
  }

  // ── Sort order ──
  Future<void> _loadSortOrder() async {
    try {
      final config = await AppConfig.load();
      final order = config['deviceSortOrder'] as List?;
      if (order != null) _deviceSortOrder = order.cast<String>();
    } catch (e) {
      debugPrint('Failed to load sort order: $e');
    }
  }

  void _sortDevices(List<DeviceInfo> devices) {
    devices.sort((a, b) {
      final aConn = a.status == DeviceStatus.connected ? 0 : 1;
      final bConn = b.status == DeviceStatus.connected ? 0 : 1;
      if (aConn != bConn) return aConn - bConn;
      final aIdx = _deviceSortOrder.indexOf(a.id);
      final bIdx = _deviceSortOrder.indexOf(b.id);
      if (aIdx != bIdx) return aIdx - bIdx;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  // ── Global config (lastExportDir, global defaults) ──
  Future<void> _loadGlobalConfig() async {
    try {
      final file = File(_configPath);
      if (!await file.exists()) return;
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final dir = json['lastExportDir'] as String?;
      if (dir != null && await Directory(dir).exists()) {
        _lastExportDir = dir;
      }
      // Note: lastSelectedDeviceId is now loaded separately in _getLastSelectedDeviceId()
    } catch (e) {
      debugPrint('Failed to load global config: $e');
    }
  }

  Future<void> _saveGlobalConfig() async {
    try {
      final file = File(_configPath);
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);

      Map<String, dynamic> config = {};
      if (await file.exists()) {
        try {
          config =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        } catch (e) {
          debugPrint('Failed to parse config file: $e');
        }
      }

      // Save per-device blocks
      final deviceConfigs = <String, dynamic>{};
      for (final entry in _deviceStates.entries) {
        deviceConfigs[entry.key] = entry.value.toJson();
      }
      config['devices'] = deviceConfigs;
      config['lastSelectedDeviceId'] = _selectedDeviceId;
      config['lastExportDir'] = _lastExportDir;

      await file.writeAsString(jsonEncode(config));
    } catch (e) {
      debugPrint('Failed to save global config: $e');
    }
  }

  // ── Scroll handling ──
  void _onScrollPositionChanged() {
    if (_isProgrammaticScroll || !_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    final atBottom = maxScroll - currentScroll < 50;
    if (atBottom) {
      _userScrolledUp = false;
      if (!_cs.autoScroll) {
        _cs.autoScroll = true;
        setState(() {});
      }
    } else {
      _userScrolledUp = true;
    }
  }

  // ── Formatters ──
  String _formatBufferSizeInput(int bytes) {
    if (bytes >= 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${bytes ~/ 1024} KB';
  }

  // ── Counter & rate helpers ──
  void _updateCounters(ConsoleDeviceState cs, List<DebugLogEntry> log) {
    // Rust side may have trimmed old entries since last fetch,
    // so we must recalculate from scratch rather than incrementally appending.
    // This is called on every poll tick (200ms), and the log size is bounded
    // by cs.bufferSize, so full recalc is cheap enough.
    int txBytes = 0, rxBytes = 0, txPackets = 0, rxPackets = 0;
    for (final e in log) {
      final bc = e.data.length;
      if (e.direction == 'TX') {
        txBytes += bc;
        txPackets++;
      } else {
        rxBytes += bc;
        rxPackets++;
      }
    }
    cs.updateRates(txBytes, rxBytes);
    cs.txBytes = txBytes;
    cs.rxBytes = rxBytes;
    cs.txPackets = txPackets;
    cs.rxPackets = rxPackets;
    cs.lastLogCount = log.length;
  }

  void _recalcCounters(ConsoleDeviceState cs, List<DebugLogEntry> log) {
    cs.txBytes = 0;
    cs.rxBytes = 0;
    cs.txPackets = 0;
    cs.rxPackets = 0;
    cs.lastLogCount = 0;
    for (final e in log) {
      final bc = e.data.length;
      if (e.direction == 'TX') {
        cs.txBytes += bc;
        cs.txPackets++;
      } else {
        cs.rxBytes += bc;
        cs.rxPackets++;
      }
    }
    cs.lastLogCount = log.length;
    cs.lastTxBytes = cs.txBytes;
    cs.lastRxBytes = cs.rxBytes;
    cs.lastRateTime = DateTime.now();
    cs.txRate = 0;
    cs.rxRate = 0;
  }

  /// Sync all devices' connected/isSerial state from Rust.
  /// Called from _refreshLog (polling), _stateSyncTimer, and _initializeAsync.
  /// Never call this from build().
  bool _syncDeviceStates() {
    final devices = listDevices();
    bool changed = false;
    for (final d in devices) {
      final cs = _ensureState(d.id);
      final wasConnected = cs.connected;
      final wasSerial = cs.isSerialDevice;
      cs.connected = isDeviceConnected(deviceId: d.id);
      cs.isSerialDevice =
          (getDevice(deviceId: d.id)?.connectionType ?? ConnectionType.tcp) ==
          ConnectionType.serial;
      if (cs.connected != wasConnected || cs.isSerialDevice != wasSerial) {
        changed = true;
      }
    }
    return changed;
  }

  void _refreshLog() {
    if (!mounted) return;
    if (_selectedDeviceId == null) return;
    _syncDeviceStates(); // keep connection/isSerial state in sync (outside build)
    final cs = _cs;
    final newLog = debugGetLogWithLimit(
      deviceId: _selectedDeviceId!,
      maxSize: cs.bufferSize,
    );
    _updateCounters(cs, newLog);
    // Only rebuild UI if log count changed (new entries arrived)
    final hasNewData = newLog.length != _lastLogCount;
    if (hasNewData) {
      _lastLogCount = newLog.length;
    }
    if (hasNewData && mounted) setState(() {});
    // Smart auto-scroll: only scroll if user hasn't scrolled up
    if (cs.autoScroll && !_userScrolledUp && _scrollController.hasClients) {
      _isProgrammaticScroll = true;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
      Future.delayed(const Duration(milliseconds: 150), () {
        _isProgrammaticScroll = false;
      });
    }
  }

  Future<void> _toggleConnection() async {
    if (_selectedDeviceId == null) return;
    final cs = _cs;
    if (!cs.connected) {
      // Connect: check return value to handle port-in-use or other errors
      bool ok = false;
      try {
        ok = await connectDevice(deviceId: _selectedDeviceId!);
      } catch (e) {
        _showError('Connection failed: $e');
        return;
      }
      if (!ok) {
        // Connection failed — sync actual state from Rust and show error
        cs.connected = isDeviceConnected(deviceId: _selectedDeviceId!);
        final device = getDevice(deviceId: _selectedDeviceId!);
        final errMsg = device?.errorMessage ?? 'Unknown error';
        _showError('Failed to connect: $errMsg');
        if (mounted) setState(() {});
        return;
      }
      cs.connected = true;
      _startPolling();
      _applySignalStates();
    } else {
      if (cs.continuousSending) _stopContinuousSend();
      _stopPolling();
      try {
        await disconnectDevice(deviceId: _selectedDeviceId!);
      } catch (e) {
        debugPrint('Disconnect failed: $e');
        // Disconnect failed — still mark as disconnected locally
      }
      cs.connected = false;
    }
    _saveConnectedDevices();
    await _saveSignalStates();
    if (mounted) setState(() {});
  }

  void _saveConnectedDevices() {
    final devices = listDevices();
    final connectedIds = devices
        .where((d) => d.status == DeviceStatus.connected)
        .map((d) => d.id)
        .toList();
    AppConfig.saveLastConnectedDevices(connectedIds);
  }

  void _clearLog() {
    if (_selectedDeviceId == null) return;
    debugClearLog(deviceId: _selectedDeviceId!);
    final cs = _cs;
    cs.resetCounters();
    if (mounted) setState(() {});
  }

  // ── Copy / Export ──
  String _buildLogText(List<DebugLogEntry> log) {
    final filtered = log.where((e) {
      if (e.direction == 'TX' && !_cs.showTx) return false;
      if (e.direction == 'RX' && !_cs.showRx) return false;
      return true;
    }).toList();
    return filtered
        .map((entry) {
          final parts = <String>[];
          if (_cs.showTimestamp)
            parts.add('[${_formatTimestamp(entry.timestamp)}]');
          parts.add('[${entry.direction}]');
          parts.add(
            _cs.showHex
                ? entry.data
                      .map(
                        (b) =>
                            b.toRadixString(16).toUpperCase().padLeft(2, '0'),
                      )
                      .join(' ')
                : entry.display,
          );
          return parts.join(' ');
        })
        .join('\n');
  }

  void _copyLog() {
    if (_selectedDeviceId == null) return;
    final log = debugGetLog(deviceId: _selectedDeviceId!);
    Clipboard.setData(ClipboardData(text: _buildLogText(log)));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Log copied to clipboard'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _exportLog() async {
    if (_selectedDeviceId == null) return;
    final log = debugGetLog(deviceId: _selectedDeviceId!);
    if (log.isEmpty) return;
    try {
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .substring(0, 19);
      final outputPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Console Log',
        fileName: 'console_$ts.txt',
        initialDirectory: _lastExportDir,
      );
      if (outputPath == null || outputPath.isEmpty) return;
      final file = File(outputPath);
      await file.writeAsString(_buildLogText(log));
      _lastExportDir = file.parent.path;
      await _saveGlobalConfig();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Exported to $outputPath'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      _showError('Export failed: $e');
    }
  }

  void _addToHistory(String cmd) {
    final cs = _cs;
    if (cmd.trim().isEmpty) return;
    cs.commandHistory.remove(cmd);
    cs.commandHistory.insert(0, cmd);
    if (cs.commandHistory.length > kMaxCommandHistory) {
      cs.commandHistory = cs.commandHistory.sublist(0, 10);
    }
    _saveSignalStates();
    setState(() {});
  }

  // ── Buffer size ──
  int? _parseBufferSize(String input) {
    input = input.trim().toUpperCase();
    final mb = RegExp(r'^([\d.]+)\s*MB$').firstMatch(input);
    if (mb != null) {
      final v = double.tryParse(mb.group(1)!);
      if (v != null) {
        final b = (v * 1024 * 1024).round();
        if (b >= 1 && b <= 500 * 1024 * 1024) return b;
      }
    }
    final kb = RegExp(r'^(\d+)\s*KB$').firstMatch(input);
    if (kb != null) {
      final v = int.tryParse(kb.group(1)!);
      if (v != null) {
        final b = v * 1024;
        if (b >= 1 && b <= 500 * 1024 * 1024) return b;
      }
    }
    return null;
  }

  void _showBufferSizeDialog() {
    _bufferSizeInputController.text = _formatBufferSizeInput(_cs.bufferSize);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Buffer Size'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _bufferSizeInputController,
              decoration: const InputDecoration(
                hintText: 'e.g. 200 KB or 1.5 MB',
                border: OutlineInputBorder(),
                suffixText: 'max: 500 MB',
              ),
              onSubmitted: (v) {
                final sz = _parseBufferSize(v);
                if (sz != null) {
                  _applyBufferSize(sz);
                  Navigator.of(ctx).pop();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invalid format')),
                  );
                }
              },
            ),
            const SizedBox(height: 12),
            const Text(
              'Presets:',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _bufferSizePresets
                  .map(
                    (sz) => ActionChip(
                      label: Text(
                        _formatBufferSizeInput(sz),
                        style: const TextStyle(fontSize: 12),
                      ),
                      onPressed: () {
                        _bufferSizeInputController.text =
                            _formatBufferSizeInput(sz);
                      },
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final sz = _parseBufferSize(_bufferSizeInputController.text);
              if (sz != null) {
                _applyBufferSize(sz);
                Navigator.of(ctx).pop();
              } else {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Invalid format')));
              }
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  void _applyBufferSize(int bytes) {
    _cs.bufferSize = bytes;
    _bufferSizeInputController.text = _formatBufferSizeInput(bytes);
    _saveSignalStates();
    if (_selectedDeviceId != null) {
      debugSetBufferSize(deviceId: _selectedDeviceId!, maxSize: bytes);
    }
    setState(() {});
  }

  // ── HEX sanitization ──
  void _sanitizeHexInput() {
    final text = _inputController.text;
    final s = text.replaceAll(RegExp(r'[^0-9A-Fa-f ]'), '');
    if (s != text) {
      _inputController.text = s;
      _inputController.selection = TextSelection.fromPosition(
        TextPosition(offset: s.length),
      );
    }
  }

  // ── Encode helpers ──
  List<int>? _encodeInput() {
    if (_selectedDeviceId == null) return null;
    final text = _inputController.text;
    if (_cs.sendFormat == 'ASCII') {
      if (text.isEmpty) return null;
      String full = text;
      if (_cs.lineEnding == 'CR')
        full = '$text\r';
      else if (_cs.lineEnding == 'LF')
        full = '$text\n';
      else if (_cs.lineEnding == 'CRLF')
        full = '$text\r\n';
      return _cs.encoding == 'GBK' ? gbk.encode(full) : utf8.encode(full);
    } else if (_cs.sendFormat == 'HEX') {
      if (text.isEmpty) return null;
      final hex = text.replaceAll(' ', '').toUpperCase();
      if (hex.isEmpty || hex.length % 2 != 0) return null;
      final bytes = <int>[];
      for (int i = 0; i < hex.length; i += 2) {
        final b = int.tryParse(hex.substring(i, i + 2), radix: 16);
        if (b == null) return null;
        bytes.add(b);
      }
      if (_cs.lineEnding == 'CR')
        bytes.add(0x0D);
      else if (_cs.lineEnding == 'LF')
        bytes.add(0x0A);
      else if (_cs.lineEnding == 'CRLF') {
        bytes.add(0x0D);
        bytes.add(0x0A);
      }
      return bytes;
    }
    return null;
  }

  // ── Send ──
  void _doSend() {
    if (_selectedDeviceId == null) return;
    final bytes = _encodeInput();
    if (bytes == null || bytes.isEmpty) return;
    final text = _inputController.text;
    if (_cs.sendFormat == 'ASCII')
      _addToHistory(text);
    else if (_cs.sendFormat == 'HEX')
      _addToHistory('[HEX] $text');
    debugSendBytes(deviceId: _selectedDeviceId!, data: bytes);
    _refreshLog();
  }

  void _send() => _doSend();

  // ── Continuous send ──
  void _showContinuousSendDialog() {
    if (_selectedDeviceId == null || !_connected) return;
    if (_inputController.text.isEmpty && _cs.sendFormat != 'FILE') return;
    final iCtrl = TextEditingController(
      text: _cs.continuousSendInterval.toString(),
    );
    final cCtrl = TextEditingController(
      text: _cs.continuousSendTarget.toString(),
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Continuous Send'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: iCtrl,
              decoration: const InputDecoration(
                labelText: 'Interval (ms)',
                border: OutlineInputBorder(),
                suffixText: 'ms',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: cCtrl,
              decoration: const InputDecoration(
                labelText: 'Count',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(ctx).pop();
              final iv = int.tryParse(iCtrl.text) ?? 10;
              final ct = int.tryParse(cCtrl.text) ?? 100;
              _startContinuousSend(interval: iv, targetCount: ct);
            },
            icon: const Icon(Icons.repeat, size: 18),
            label: const Text('Start'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade700,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  void _startContinuousSend({required int interval, required int targetCount}) {
    if (_selectedDeviceId == null || !_connected) return;
    final bytes = _encodeInput();
    if (bytes == null || bytes.isEmpty) return;
    final cs = _cs;
    cs.continuousSendInterval = interval < 1 ? 1 : interval;
    cs.continuousSendTarget = targetCount < 1 ? 1 : targetCount;
    cs.continuousSendCount = 0;
    cs.continuousSendBytes = bytes;
    cs.continuousStopRequested = false;
    cs.continuousSending = true;
    // Store the device ID this continuous send was started on
    cs.continuousSendDeviceId = _selectedDeviceId;
    _saveSignalStates();
    setState(() {});
    _continuousSendLoop(cs);
  }

  Future<void> _continuousSendLoop(ConsoleDeviceState cs) async {
    // Use the device ID stored when continuous send started
    final targetDeviceId = cs.continuousSendDeviceId;
    while (cs.continuousSending &&
        !cs.continuousStopRequested &&
        cs.continuousSendBytes != null &&
        targetDeviceId != null) {
      if (cs.continuousSendCount >= cs.continuousSendTarget) break;
      debugSendBytes(deviceId: targetDeviceId, data: cs.continuousSendBytes!);
      cs.continuousSendCount++;
      if (cs.continuousSendCount % 10 == 0 ||
          cs.continuousSendCount >= cs.continuousSendTarget) {
        if (mounted) setState(() {});
      }
      if (cs.continuousSendCount >= cs.continuousSendTarget) break;
      await Future.delayed(Duration(milliseconds: cs.continuousSendInterval));
    }
    if (cs.continuousSending) {
      cs.continuousSending = false;
      cs.continuousSendBytes = null;
      cs.continuousSendDeviceId = null;
      if (mounted) setState(() {});
      _refreshLog();
    }
  }

  void _stopContinuousSend() {
    _cs.continuousStopRequested = true;
    _cs.continuousSending = false;
    _cs.continuousSendBytes = null;
    _cs.continuousSendDeviceId = null;
    _saveSignalStates();
    setState(() {});
    _refreshLog();
  }

  Future<void> _sendFile() async {
    if (_selectedDeviceId == null) return;
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null || path.isEmpty) return;
      final file = File(path);
      if (!await file.exists()) {
        _showError('File not found: $path');
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        _showError('File is empty');
        return;
      }
      _addToHistory('[FILE] $path (${bytes.length} bytes)');
      debugSendBytes(deviceId: _selectedDeviceId!, data: bytes);
      _refreshLog();
    } catch (e) {
      _showError('Failed to read file: $e');
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  void _sendQuickCommand(String cmd) {
    if (_selectedDeviceId == null) return;
    _addToHistory(cmd);
    debugSendString(deviceId: _selectedDeviceId!, text: cmd, lineEnding: '\n');
    _inputController.text = cmd;
    _refreshLog();
  }

  Timer? _pollTimer;
  Timer? _stateSyncTimer; // low-freq sync for device states when not polling
  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: kPollIntervalMs),
      (_) => _refreshLog(),
    );
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _startStateSync() {
    _stateSyncTimer?.cancel();
    _stateSyncTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_syncDeviceStates() && mounted) setState(() {});
    });
  }

  String _formatTimestamp(PlatformInt64 ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}.${dt.millisecond.toString().padLeft(3, '0')}';
  }

  Color _getDirectionColor(String dir) =>
      dir == 'TX' ? Colors.orange : Colors.green;

  String _formatData(DebugLogEntry entry) {
    return _cs.showHex
        ? entry.data
              .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
              .join(' ')
        : entry.display;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      final kb = bytes / 1024;
      return '${kb.toStringAsFixed(kb == kb.roundToDouble() ? 0 : 1)} KB';
    }
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(mb == mb.roundToDouble() ? 0 : 1)} MB';
  }

  String _formatRate(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    if (bytesPerSec < 1024 * 1024)
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(2)} MB/s';
  }

  String _formatBufferSize(int bytes) => bytes < 1024 * 1024
      ? '${bytes ~/ 1024} KB'
      : '${bytes ~/ (1024 * 1024)} MB';

  InputDecoration _dropdownDecoration() => const InputDecoration(
    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    border: OutlineInputBorder(),
    isDense: true,
  );

  Widget _buildToggleIcon({
    required IconData icon,
    required bool active,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: active ? AppTheme.surfaceVariant : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            icon,
            size: 18,
            color: active
                ? AppTheme.textPrimary
                : AppTheme.textSecondary.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }

  Widget _buildDirectionToggle({
    required String label,
    required bool active,
    required Color activeColor,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: active
                ? activeColor.withValues(alpha: 0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: active
                ? Border.all(
                    color: activeColor.withValues(alpha: 0.5),
                    width: 1,
                  )
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              fontFamily: 'Consolas, monospace',
              color: active
                  ? activeColor
                  : AppTheme.textSecondary.withValues(alpha: 0.35),
            ),
          ),
        ),
      ),
    );
  }

  // ── Build ──
  @override
  Widget build(BuildContext context) {
    final devices = listDevices();
    _sortDevices(devices);

    // Validate current device (pure read — no state mutation)
    if (_selectedDeviceId != null &&
        !devices.any((d) => d.id == _selectedDeviceId)) {
      _selectedDeviceId = devices.isNotEmpty ? devices.first.id : null;
    }
    // NOTE: device connection/isSerial sync is done in _syncDeviceStates(),
    // called from _refreshLog() and _initializeAsync(). Do NOT mutate
    // _deviceStates inside build() — it causes AXTree errors.

    // Fetch log for current device (kept in Rust)
    List<DebugLogEntry> rawLog = [];
    if (_selectedDeviceId != null && _connected) {
      rawLog = debugGetLogWithLimit(
        deviceId: _selectedDeviceId!,
        maxSize: _cs.bufferSize,
      );
    }

    final filteredLog = rawLog.where((e) {
      if (e.direction == 'TX' && !_cs.showTx) return false;
      if (e.direction == 'RX' && !_cs.showRx) return false;
      return true;
    }).toList();

    return Scaffold(

      appBar: AppBar(
        title: const Text('Console'),
        actions: [
          Tooltip(
            message: 'Set buffer size (up to 500 MB)',
            preferBelow: false,
            child: TextButton.icon(
              onPressed: _showBufferSizeDialog,
              icon: const Icon(Icons.storage, size: 18),
              label: Text(
                _formatBufferSize(_cs.bufferSize),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.save_alt),
            onPressed: filteredLog.isNotEmpty ? _exportLog : null,
            tooltip: 'Export Log',
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: filteredLog.isNotEmpty ? _copyLog : null,
            tooltip: 'Copy Log',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: filteredLog.isNotEmpty ? _clearLog : null,
            tooltip: 'Clear Log',
          ),
        ],
      ),
      body: Column(
        children: [
          // Connection bar
          Container(
            padding: const EdgeInsets.all(12),
            color: AppTheme.surfaceVariant,
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedDeviceId,
                    hint: const Text('Select Device'),
                    icon: const SizedBox.shrink(),
                    decoration: const InputDecoration(
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(),
                    ),
                    items: devices.map((d) {
                      final dCs = _deviceStates[d.id];
                      final isConnected =
                          dCs?.connected ??
                          (d.status == DeviceStatus.connected);
                      return DropdownMenuItem(
                        value: d.id,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isConnected
                                    ? AppTheme.success
                                    : AppTheme.error,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                d.name,
                                overflow: TextOverflow.ellipsis,
                                softWrap: false,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (v) {
                      if (v != null) {
                        _selectDevice(v).then((_) {
                          if (mounted) setState(() {});
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Tooltip(
                  message: _connected ? 'Disconnect' : 'Connect',
                  preferBelow: false,
                  child: GestureDetector(
                    onTap: _selectedDeviceId == null ? null : _toggleConnection,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: _connected ? AppTheme.success : AppTheme.error,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _connected ? Icons.link_off : Icons.link,
                            size: 18,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _connected ? 'Disconnect' : 'Connect',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: AppTheme.surface,
            child: Row(
              children: [
                _buildToggleIcon(
                  icon: Icons.schedule,
                  active: _cs.showTimestamp,
                  tooltip: 'Show Timestamp',
                  onTap: () {
                    _cs.showTimestamp = !_cs.showTimestamp;
                    _saveSignalStates();
                    setState(() {});
                  },
                ),
                const SizedBox(width: 4),
                _buildToggleIcon(
                  icon: Icons.data_object,
                  active: _cs.showHex,
                  tooltip: 'Show as HEX',
                  onTap: () {
                    _cs.showHex = !_cs.showHex;
                    _saveSignalStates();
                    setState(() {});
                  },
                ),
                const SizedBox(width: 4),
                _buildToggleIcon(
                  icon: Icons.vertical_align_bottom,
                  active: _cs.autoScroll,
                  tooltip: 'Auto Scroll',
                  onTap: () {
                    _cs.autoScroll = !_cs.autoScroll;
                    _saveSignalStates();
                    setState(() {});
                  },
                ),
                const SizedBox(width: 12),
                _buildDirectionToggle(
                  label: 'Tx',
                  active: _cs.showTx,
                  activeColor: Colors.orange,
                  tooltip: 'Show Tx',
                  onTap: () {
                    _cs.showTx = !_cs.showTx;
                    _saveSignalStates();
                    setState(() {});
                  },
                ),
                const SizedBox(width: 4),
                _buildDirectionToggle(
                  label: 'Rx',
                  active: _cs.showRx,
                  activeColor: Colors.green,
                  tooltip: 'Show Rx',
                  onTap: () {
                    _cs.showRx = !_cs.showRx;
                    _saveSignalStates();
                    setState(() {});
                  },
                ),
                const Spacer(),
                if (_cs.continuousSending)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.blue.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.blue,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${_cs.continuousSendCount}/${_cs.continuousSendTarget}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'Consolas, monospace',
                            color: Colors.blue,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_cs.continuousSending) const SizedBox(width: 12),
                Tooltip(
                  message:
                      'Tx: ${_cs.txPackets} pkts, ${_formatBytes(_cs.txBytes)}',
                  preferBelow: false,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Tx',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'Consolas, monospace',
                          color: Colors.orange.withValues(alpha: 0.8),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _formatBytes(_cs.txBytes),
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'Consolas, monospace',
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _formatRate(_cs.txRate),
                        style: TextStyle(
                          fontSize: 10,
                          fontFamily: 'Consolas, monospace',
                          color: AppTheme.textSecondary.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Tooltip(
                  message:
                      'Rx: ${_cs.rxPackets} pkts, ${_formatBytes(_cs.rxBytes)}',
                  preferBelow: false,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Rx',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'Consolas, monospace',
                          color: Colors.green.withValues(alpha: 0.8),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _formatBytes(_cs.rxBytes),
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'Consolas, monospace',
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _formatRate(_cs.rxRate),
                        style: TextStyle(
                          fontSize: 10,
                          fontFamily: 'Consolas, monospace',
                          color: AppTheme.textSecondary.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Log display — with RepaintBoundary + itemExtent for scroll performance
          Expanded(
            child: RepaintBoundary(
              child: Container(
                color: const Color(0xFF1E1E1E),
                child: filteredLog.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const VcrLogo(size: 64),
                            const SizedBox(height: 16),
                            Text(
                              'No data yet',
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Connect a device and send data',
                              style: TextStyle(
                                color: Colors.grey[700],
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      )
                    : NotificationListener<UserScrollNotification>(
                        onNotification: (n) {
                          if (n.direction != ScrollDirection.idle &&
                              _cs.autoScroll) {
                            _cs.autoScroll = false;
                            setState(() {});
                          }
                          return false;
                        },
                        child: Scrollbar(
                          controller: _scrollController,
                          thumbVisibility: true,
                          interactive: true,
                          thickness: 16.0,
                          radius: const Radius.circular(8),
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(
                              context,
                            ).copyWith(scrollbars: false),
                            child: ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.only(
                                right: 20,
                                top: 8,
                                bottom: 8,
                                left: 8,
                              ),
                              itemCount: filteredLog.length,
                              itemExtent: 22.0,
                              itemBuilder: (context, index) {
                                final entry = filteredLog[index];
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 1),
                                  child: RichText(
                                    text: TextSpan(
                                      style: const TextStyle(
                                        fontFamily: 'Consolas, monospace',
                                        fontSize: 13,
                                        color: Colors.white,
                                      ),
                                      children: [
                                        if (_cs.showTimestamp)
                                          TextSpan(
                                            text:
                                                '[${_formatTimestamp(entry.timestamp)}] ',
                                            style: TextStyle(
                                              color: Colors.grey[500],
                                            ),
                                          ),
                                        TextSpan(
                                          text: '[${entry.direction}] ',
                                          style: TextStyle(
                                            color: _getDirectionColor(
                                              entry.direction,
                                            ),
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        TextSpan(text: _formatData(entry)),
                                      ],
                                    ),
                                    softWrap: false,
                                    overflow: TextOverflow.clip,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ),

          // Quick commands
          Container(
            padding: const EdgeInsets.all(8),
            color: AppTheme.surfaceVariant,
            child: Row(
              children: [
                _buildQuickButton('READ?', 'Read Value'),
                _buildQuickButton('VOLT:DC:NPLC 10', 'Set NPLC'),
                _buildQuickButton('*IDN?', 'Query ID'),
                _buildQuickButton('*RST', 'Reset'),
                _buildQuickButton('*CLS', 'Clear'),
                _buildQuickButton('SYST:ERR?', 'Error?'),
              ],
            ),
          ),

          // Input area
          Container(
            padding: const EdgeInsets.all(12),
            color: AppTheme.surface,
            child: Row(
              children: [
                // Send format
                SizedBox(
                  width: 75,
                  child: DropdownButtonFormField<String>(
                    initialValue: _cs.sendFormat,
                    icon: const SizedBox.shrink(),
                    decoration: _dropdownDecoration(),
                    items: const [
                      DropdownMenuItem(value: 'ASCII', child: Text('Text')),
                      DropdownMenuItem(value: 'HEX', child: Text('HEX')),
                      DropdownMenuItem(value: 'FILE', child: Text('File')),
                    ],
                    onChanged: (v) {
                      _cs.sendFormat = v!;
                      _saveSignalStates();
                      setState(() {});
                      if (v == 'HEX') _sanitizeHexInput();
                      if (v == 'FILE') _sendFile();
                    },
                  ),
                ),
                const SizedBox(width: 6),

                // Encoding (ASCII only)
                if (_cs.sendFormat == 'ASCII')
                  SizedBox(
                    width: 75,
                    child: DropdownButtonFormField<String>(
                      initialValue: _cs.encoding,
                      icon: const SizedBox.shrink(),
                      decoration: _dropdownDecoration(),
                      items: const [
                        DropdownMenuItem(value: 'UTF-8', child: Text('UTF-8')),
                        DropdownMenuItem(value: 'GBK', child: Text('GBK')),
                      ],
                      onChanged: (v) {
                        _cs.encoding = v!;
                        _saveSignalStates();
                        setState(() {});
                      },
                    ),
                  ),
                if (_cs.sendFormat != 'ASCII') const SizedBox(width: 81),

                const SizedBox(width: 6),

                // Line ending
                SizedBox(
                  width: 100,
                  child: DropdownButtonFormField<String>(
                    initialValue: _cs.lineEnding,
                    icon: const SizedBox.shrink(),
                    decoration: _dropdownDecoration(),
                    items: const [
                      DropdownMenuItem(value: 'None', child: Text('None')),
                      DropdownMenuItem(value: 'CR', child: Text('CR \\r')),
                      DropdownMenuItem(value: 'LF', child: Text('LF \\n')),
                      DropdownMenuItem(
                        value: 'CRLF',
                        child: Text('CRLF \\r\\n'),
                      ),
                    ],
                    onChanged: (v) {
                      _cs.lineEnding = v!;
                      _saveSignalStates();
                      setState(() {});
                    },
                  ),
                ),

                const SizedBox(width: 6),

                // Command history
                if (_cs.commandHistory.isNotEmpty)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.history, size: 22),
                    tooltip: 'Command History',
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    onSelected: (cmd) {
                      _inputController.text = cmd;
                      _inputFocusNode.requestFocus();
                    },
                    itemBuilder: (context) => _cs.commandHistory
                        .asMap()
                        .entries
                        .map(
                          (e) => PopupMenuItem<String>(
                            value: e.value,
                            height: 36,
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 24,
                                  child: Text(
                                    '${e.key + 1}',
                                    style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    e.value,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 13,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),

                // Input
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _inputFocusNode,
                    inputFormatters: _cs.sendFormat == 'HEX'
                        ? [_hexFormatter]
                        : null,
                    decoration: InputDecoration(
                      hintText: _cs.sendFormat == 'HEX'
                          ? 'e.g. AA BB CC or AABBCC'
                          : 'Enter command or data...',
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),

                const SizedBox(width: 8),

                // Send / Stop
                if (_cs.continuousSending)
                  ElevatedButton.icon(
                    onPressed: _stopContinuousSend,
                    icon: const Icon(Icons.stop, size: 18),
                    label: Text(
                      'Stop (${_cs.continuousSendCount}/${_cs.continuousSendTarget})',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                  )
                else
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _connected && _selectedDeviceId != null
                            ? _send
                            : null,
                        icon: const Icon(Icons.send, size: 18),
                        label: const Text('Send'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Tooltip(
                        message: 'Continuous Send',
                        preferBelow: false,
                        child: ElevatedButton(
                          onPressed: _connected && _selectedDeviceId != null
                              ? _showContinuousSendDialog
                              : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue.shade700,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 0,
                            ),
                            minimumSize: const Size(36, 36),
                          ),
                          child: const Icon(
                            Icons.repeat,
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickButton(String cmd, String tooltip) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: tooltip,
        child: OutlinedButton(
          onPressed: _connected && _selectedDeviceId != null
              ? () => _sendQuickCommand(cmd)
              : null,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          child: Text(cmd, style: const TextStyle(fontFamily: 'monospace')),
        ),
      ),
    );
  }
}
