import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'chart_isolate.dart';
import 'src/rust/frb_generated.dart';
import 'src/rust/api/device_api.dart';
import 'src/rust/api/virtual_api.dart';
import 'src/rust/api/lua_api.dart';
import 'src/rust/api/debug_api.dart';
import 'core/ffi_bridge.dart';

import 'app/theme.dart';
import 'app/routes.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  // Initialize Rust logger to output to the debug console window
  debugInitLogger();

  // Load and apply saved log settings
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final configFile = File('$exeDir\\VCR\\app_config.json');
    if (await configFile.exists()) {
      final config = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
      
      // Apply log level
      final logLevel = config['logLevel'] as String? ?? 'info';
      debugSetLogLevel(level: logLevel);
      
      // Apply file logging enabled
      final fileLoggingEnabled = config['fileLoggingEnabled'] as bool? ?? true;
      debugSetFileLoggingEnabled(enabled: fileLoggingEnabled);
      
      // Apply log file path
      final logPath = config['logPath'] as String? ?? '';
      if (logPath.isNotEmpty) {
        debugSetLogFilePath(path: logPath);
      }
    }
  } catch (e) {
    debugPrint('Failed to load log settings: $e');
  }

  // Pre-init Lua engine at startup so the Rust module is fully initialized
  // before any UI access. This avoids lazy_static initialization timing issues
  // when debugGetActiveSessions() is first called from LuaScriptScreen.initState().
  try {
    await initLuaEngine();
  } catch (e) {
    debugPrint('Warning: Lua engine pre-init failed: $e');
  }

  // 启动虚拟基础设施（TCP-SCPI服务器 + 虚拟串口COM1/COM2）
  startVirtualInfrastructure();

  // 加载虚拟设备（TCP-SCPI-Demo, Serial-SCPI-Demo）
  loadVirtualDevices();

  // 尝试加载持久化设备；如果没有保存的设备，则加载演示设备
  final loaded = loadPersistedDevices();
  if (loaded == 0) {
    loadDemoDevices();
  }

  // Auto-reconnect: fire-and-forget — don't block UI startup.
  // Connections happen in background; UI starts immediately.
  _autoReconnectIfNeeded();

  // 🚀 P0-1: Start background data pipeline (pyramid ingestion from receive loop)
  // Eliminates Dart→Rust round-trip — data flows: Serial → pipeline → FFI_CH_PYRAMIDS → Dart query
  try {
    FfiBridge.instance.startPipeline();
  } catch (e) {
    debugPrint('[Main] Pipeline start skipped (non-critical): $e');
  }

  // Start Chart Isolate for high-throughput data pipeline
  _startChartIsolate();

  runApp(const MyApp());
}

/// Load app config and auto-reconnect devices that were connected last session.
/// Runs as fire-and-forget from main() — does not delay runApp().
Future<void> _autoReconnectIfNeeded() async {
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final configPath = '$exeDir\\VCR\\app_config.json';
    final file = File(configPath);
    if (!file.existsSync()) return;

    final content = file.readAsStringSync();
    final config = jsonDecode(content) as Map<String, dynamic>;

    // Check if auto-reconnect is enabled
    final autoReconnect = config['autoReconnect'] as bool? ?? false;
    if (!autoReconnect) return;

    // Get list of previously connected device IDs
    final lastConnected = config['lastConnectedDevices'] as List?;
    if (lastConnected == null || lastConnected.isEmpty) return;

    // Attempt to reconnect each device (async — does not block UI)
    for (final id in lastConnected) {
      if (id is String) {
        try {
          await connectDevice(deviceId: id);
        } catch (e) {
          debugPrint('Auto-reconnect failed for device $id: $e');
        }
      }
    }
  } catch (e) {
    debugPrint('Error during auto-reconnect: $e');
  }
}

// Global reference to Chart Isolate (imported from chart_isolate.dart)
// Note: chartIsolatePort is defined in chart_isolate.dart
// ignore: unused_element
Isolate? _chartIsolate;

Future<void> _startChartIsolate() async {
  try {
    final receivePort = ReceivePort();
    _chartIsolate = await Isolate.spawn(chartIsolateEntry, receivePort.sendPort);
    chartIsolatePort = await receivePort.first as SendPort;
    debugPrint('[VCR] Chart Isolate started successfully');
  } catch (e) {
    debugPrint('[VCR] Failed to start Chart Isolate: $e');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      excluding: true,
      child: MaterialApp(
        title: 'VCR V0.0.6',
        theme: AppTheme.darkTheme,
        initialRoute: AppRoutes.home,
        onGenerateRoute: AppRoutes.onGenerateRoute,
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
