import 'package:flutter/material.dart';
import '../app/theme.dart';
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
  // ── Local index for setState-based tab switching (no route navigation) ──
  late int _currentIndex;

  // ── Keep all screens alive (never disposed) ──
  final _screens = const [
    DeviceListScreen(),
    PlotScreen(),
    DebugConsoleScreen(),
    SettingsScreen(),
    LuaScriptScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.selectedIndex;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _currentIndex,
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
              index: _currentIndex,
              children: _screens,
            ),
          ),
        ],
      ),
    );
  }

  void _navigateTo(int index) {
    if (index == _currentIndex) return;

    // Save Console state before switching away from it (belt-and-suspenders;
    // IndexedStack keeps state alive, but we also persist to disk for crash safety)
    // Console is now at index 2 (was 3 before Dashboard tab was removed)
    if (_currentIndex == 2) {
      try {
        DebugConsoleScreen.saveCurrentState();
      } catch (e) {
        debugPrint('Failed to save console state: $e');
      }
    }

    setState(() {
      _currentIndex = index;
    });
  }
}
