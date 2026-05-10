import 'dart:async';
import 'package:flutter/material.dart';
import '../app/theme.dart';
import '../widgets/main_shell.dart' show VcrLogo;
import '../widgets/status_indicator.dart';
import '../screens/settings_screen.dart' show AppConfig;
import '../src/rust/api/device_api.dart';
import '../src/rust/core/device/models.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<DeviceInfo> _devices = [];
  bool _loading = true;
  Timer? _autoRefreshTimer;
  List<String> _deviceSortOrder = [];

  @override
  void initState() {
    super.initState();
    _loadSortOrder();
    _loadDevices();
    // Auto-refresh every 3 seconds
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _loadDevices();
    });
  }

  Future<void> _loadSortOrder() async {
    try {
      final config = await AppConfig.load();
      final order = config['deviceSortOrder'] as List?;
      if (order != null) {
        _deviceSortOrder = order.cast<String>();
      }
    } catch (e) {
      debugPrint('Failed to load device sort order: $e');
    }
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    final devices = listDevices();
    // Sort: connected first, then by persisted sort order, then alphabetical
    devices.sort((a, b) {
      final aConn = a.status == DeviceStatus.connected ? 0 : 1;
      final bConn = b.status == DeviceStatus.connected ? 0 : 1;
      if (aConn != bConn) return aConn - bConn;
      final aIdx = _deviceSortOrder.indexOf(a.id);
      final bIdx = _deviceSortOrder.indexOf(b.id);
      final aInOrder = aIdx >= 0 ? aIdx : 999999;
      final bInOrder = bIdx >= 0 ? bIdx : 999999;
      if (aInOrder != bInOrder) return aInOrder - bInOrder;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _loading = false;
    });
  }

  int get _connectedCount => _devices.where((d) => d.status == DeviceStatus.connected).length;
  int get _disconnectedCount => _devices.where((d) => d.status == DeviceStatus.disconnected).length;
  int get _errorCount => _devices.where((d) => d.status == DeviceStatus.error).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadDevices,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Status overview row
                  Row(
                    children: [
                      _buildStatCard(context, 'Connected', '$_connectedCount', Icons.link, AppTheme.success),
                      const SizedBox(width: 16),
                      _buildStatCard(context, 'Disconnected', '$_disconnectedCount', Icons.link_off, AppTheme.textSecondary),
                      const SizedBox(width: 16),
                      _buildStatCard(context, 'Errors', '$_errorCount', Icons.error_outline, AppTheme.error),
                      const SizedBox(width: 16),
                      _buildStatCard(context, 'Total', '${_devices.length}', Icons.devices, AppTheme.primary),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Device status overview
                  Row(
                    children: [
                      Text('Device Status', style: Theme.of(context).textTheme.titleLarge),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _devices.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const VcrLogo(size: 64),
                                const SizedBox(height: 16),
                                Text('No devices configured', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: AppTheme.textSecondary)),
                                const SizedBox(height: 8),
                                Text('Click "Devices" in the sidebar to add devices', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary)),
                              ],
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _loadDevices,
                            child: ListView.builder(
                              itemCount: _devices.length,
                              itemBuilder: (context, index) => _DeviceStatusTile(
                                device: _devices[index],
                                onStatusChanged: _loadDevices,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildStatCard(BuildContext context, String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: color, size: 20),
                  const SizedBox(width: 8),
                  Text(label, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
              const SizedBox(height: 8),
              Text(value, style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceStatusTile extends StatelessWidget {
  final DeviceInfo device;
  final VoidCallback? onStatusChanged;
  const _DeviceStatusTile({required this.device, this.onStatusChanged});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: StatusIndicator(status: device.status),
        title: Text(device.name),
        subtitle: Text(_connTypeLabel(device.connectionType)),
        trailing: const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
        onTap: () async {
          await Navigator.pushNamed(context, '/devices/detail', arguments: device.id);
          onStatusChanged?.call();
        },
      ),
    );
  }

  String _connTypeLabel(ConnectionType t) {
    switch (t) {
      case ConnectionType.serial:
        return 'Serial';
      case ConnectionType.tcp:
        return 'TCP';
      case ConnectionType.usb:
        return 'USB';
      case ConnectionType.ble:
        return 'BLE';
      case ConnectionType.wifi:
        return 'WiFi';
    }
  }
}
