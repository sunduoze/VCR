import 'package:flutter/material.dart';
import '../app/theme.dart';
import '../app/routes.dart';
import '../screens/home_screen.dart';
import '../screens/device_list_screen.dart';
import '../screens/plot_screen.dart';
import '../screens/debug_console_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/lua_script_screen.dart';

/// VCR Logo widget - used in NavigationRail leading area and other brand placements
class VcrLogo extends StatelessWidget {
  final double size;
  final BorderRadius? borderRadius;

  const VcrLogo({super.key, this.size = 40, this.borderRadius});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(size * 0.2),
      child: Image.asset(
        'assets/images/vcr_logo.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
      ),
    );
  }
}

/// Persistent shell: keeps all 5 tab screens alive via IndexedStack.
/// Switching tabs does NOT destroy or rebuild child screens — state is preserved.
class MainShell extends StatefulWidget {
  final Widget child;
  final int selectedIndex;

  const MainShell({
    super.key,
    required this.child,
    required this.selectedIndex,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  // ── Keep all screens alive (never disposed) ──
  final _screens = const [
    HomeScreen(),
    DeviceListScreen(),
    PlotScreen(),
    DebugConsoleScreen(),
    SettingsScreen(),
    LuaScriptScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: widget.selectedIndex,
            onDestinationSelected: _navigateTo,
            labelType: NavigationRailLabelType.all,
            backgroundColor: AppTheme.surface,
            indicatorColor: AppTheme.primary.withValues(alpha: 0.2),
            selectedIconTheme: const IconThemeData(color: AppTheme.primary),
            unselectedIconTheme: const IconThemeData(
              color: AppTheme.textSecondary,
            ),
            selectedLabelTextStyle: const TextStyle(
              color: AppTheme.primary,
              fontWeight: FontWeight.w500,
            ),
            unselectedLabelTextStyle: const TextStyle(
              color: AppTheme.textSecondary,
            ),
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                children: [
                  const VcrLogo(size: 40),
                  const SizedBox(height: 8),
                  const Text(
                    'VCR V0.0.6',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard),
                label: Text('Dashboard'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.devices_outlined),
                selectedIcon: Icon(Icons.devices),
                label: Text('Devices'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.show_chart_outlined),
                selectedIcon: Icon(Icons.show_chart),
                label: Text('Plot'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.terminal_outlined),
                selectedIcon: Icon(Icons.terminal),
                label: Text('Console'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('Settings'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.code_outlined),
                selectedIcon: Icon(Icons.code),
                label: Text('Lua'),
              ),
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1, color: AppTheme.border),
          // IndexedStack: only the visible child is laid out, but ALL children
          // remain in the widget tree (never disposed/rebuilt). State is kept.
          Expanded(
            child: IndexedStack(
              index: widget.selectedIndex,
              children: _screens,
            ),
          ),
        ],
      ),
    );
  }

  void _navigateTo(int index) {
    if (index == widget.selectedIndex) return;

    // Save Console state before switching away from it
    if (widget.selectedIndex == 3) {
      // Console tab index
      try {
        DebugConsoleScreen.saveCurrentState();
      } catch (e) {
        debugPrint('Failed to save console state: $e');
      }
    }

    final routes = [
      AppRoutes.home,
      AppRoutes.deviceList,
      AppRoutes.dataMonitor,
      AppRoutes.debugConsole,
      AppRoutes.settings,
      AppRoutes.luaScript,
    ];
    Navigator.pushReplacementNamed(context, routes[index]);
  }
}
