import 'package:flutter/material.dart';
import '../screens/home_screen.dart';
import '../screens/device_list_screen.dart';
import '../screens/device_detail_screen.dart';
import '../screens/plot_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/debug_console_screen.dart';
import '../screens/lua_script_screen.dart';
import '../screens/gpu_test_screen.dart';
import '../widgets/main_shell.dart';

class AppRoutes {
  static const String home = '/';
  static const String deviceList = '/devices';
  static const String deviceDetail = '/devices/detail';
  static const String dataMonitor = '/monitor';
  static const String settings = '/settings';
  static const String debugConsole = '/debug';
  static const String luaScript = '/lua';
  static const String gpuTest = '/gpu-test';

  /// 根据路由名称获取导航索引
  static int getNavIndex(String? route) {
    switch (route) {
      case home:
        return 0;
      case deviceList:
      case deviceDetail:
        return 1;
      case dataMonitor:
        return 2;
      case debugConsole:
        return 3;
      case settings:
        return 4;
      case luaScript:
        return 5;
      default:
        return 0;
    }
  }

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    final route = settings.name;
    final navIndex = getNavIndex(route);

    switch (route) {
      case home:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => MainShell(
            selectedIndex: navIndex,
            child: const HomeScreen(),
          ),
        );
      case deviceList:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => MainShell(
            selectedIndex: navIndex,
            child: const DeviceListScreen(),
          ),
        );
      case deviceDetail:
        final deviceId = settings.arguments as String?;
        if (deviceId == null) {
          return MaterialPageRoute(
            builder: (_) => MainShell(
              selectedIndex: navIndex,
              child: const Scaffold(
                body: Center(child: Text('设备 ID 缺失')),
              ),
            ),
          );
        }
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => MainShell(
            selectedIndex: navIndex,
            child: DeviceDetailScreen(deviceId: deviceId),
          ),
        );
      case dataMonitor:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => MainShell(
            selectedIndex: navIndex,
            child: const PlotScreen(),
          ),
        );
      case AppRoutes.settings:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => MainShell(
            selectedIndex: navIndex,
            child: const SettingsScreen(),
          ),
        );
      case debugConsole:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => MainShell(
            selectedIndex: navIndex,
            child: DebugConsoleScreen(deviceId: settings.arguments as String?),
          ),
        );
      case luaScript:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => MainShell(
            selectedIndex: navIndex,
            child: const LuaScriptScreen(),
          ),
        );
      case gpuTest:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => const GpuTestScreen(),
        );
      default:
        return MaterialPageRoute(
          builder: (_) => MainShell(
            selectedIndex: 0,
            child: const Scaffold(
              body: Center(child: Text('Page not found')),
            ),
          ),
        );
    }
  }
}
