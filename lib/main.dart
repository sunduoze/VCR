import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'src/rust/frb_generated.dart';
import 'src/rust/api/device_api.dart';
import 'src/rust/api/virtual_api.dart';
import 'src/rust/api/lua_api.dart';
import 'app/theme.dart';
import 'app/routes.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

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

  runApp(const MyApp());
}

/// Load app config and auto-reconnect devices that were connected last session.
/// Runs as fire-and-forget from main() — does not delay runApp().
Future<void> _autoReconnectIfNeeded() async {
  try {
    final appData = Platform.environment['APPDATA'] ?? '';
    final configPath = '$appData\\VCR\\app_config.json';
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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VCR',
      theme: AppTheme.darkTheme,
      initialRoute: AppRoutes.home,
      onGenerateRoute: AppRoutes.onGenerateRoute,
      debugShowCheckedModeBanner: false,
    );
  }
}
