import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../app/theme.dart';

/// App-wide configuration helper
/// Stores: autoReconnect, lastConnectedDevices, deviceSortOrder
class AppConfig {
  static String get _path {
    final appData = Platform.environment['APPDATA'] ?? '';
    return '$appData\\VCR\\app_config.json';
  }

  static Future<Map<String, dynamic>> load() async {
    try {
      final file = File(_path);
      if (await file.exists()) {
        final content = await file.readAsString();
        return jsonDecode(content) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  static Future<void> save(Map<String, dynamic> config) async {
    try {
      final file = File(_path);
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file.writeAsString(jsonEncode(config));
    } catch (_) {}
  }

  /// Save the IDs of currently connected devices (called on connect/disconnect)
  static Future<void> saveLastConnectedDevices(List<String> deviceIds) async {
    final config = await load();
    config['lastConnectedDevices'] = deviceIds;
    await save(config);
  }

  /// Save device sort order (device IDs in display order)
  static Future<void> saveDeviceSortOrder(List<String> deviceIds) async {
    final config = await load();
    config['deviceSortOrder'] = deviceIds;
    await save(config);
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _autoReconnect = false;
  bool _darkMode = true;
  int _samplingRate = 1000;
  int _bufferSize = 4096;
  String _language = 'zh_CN';
  bool _configLoaded = false;
  int _plotAALevel = 0; // 0=off, 1=2x, 2=4x, 3=8x, 4=16x

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final config = await AppConfig.load();
    if (mounted) {
      setState(() {
        _autoReconnect = config['autoReconnect'] as bool? ?? false;
        _plotAALevel = config['plotAALevel'] as int? ?? 0;
        _configLoaded = true;
      });
    }
  }

  String get _aaLevelLabel {
    switch (_plotAALevel) {
      case 0: return 'Off';
      case 1: return '2×';
      case 2: return '4×';
      case 3: return '8×';
      case 4: return '16×';
      default: return 'Off';
    }
  }

  Future<void> _saveAutoReconnect(bool value) async {
    setState(() => _autoReconnect = value);
    final config = await AppConfig.load();
    config['autoReconnect'] = value;
    await AppConfig.save(config);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Connection settings
          _SectionHeader(title: 'Connection'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Auto Reconnect on Startup'),
                  subtitle: const Text('Reconnect previously connected devices when app starts'),
                  value: _autoReconnect,
                  onChanged: _saveAutoReconnect,
                  activeColor: AppTheme.primary,
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Connection Timeout'),
                  subtitle: const Text('5000 ms'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {},
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Retry Interval'),
                  subtitle: const Text('1000 ms'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {},
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Data acquisition settings
          _SectionHeader(title: 'Data Acquisition'),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Sampling Rate'),
                  subtitle: Text('$_samplingRate Hz'),
                  trailing: SizedBox(
                    width: 200,
                    child: Slider(
                      value: _samplingRate.toDouble(),
                      min: 100,
                      max: 10000,
                      divisions: 99,
                      label: '$_samplingRate Hz',
                      onChanged: (v) => setState(() => _samplingRate = v.round()),
                      activeColor: AppTheme.primary,
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Buffer Size'),
                  subtitle: Text('$_bufferSize samples'),
                  trailing: DropdownButton<int>(
                    value: _bufferSize,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 1024, child: Text('1024')),
                      DropdownMenuItem(value: 2048, child: Text('2048')),
                      DropdownMenuItem(value: 4096, child: Text('4096')),
                      DropdownMenuItem(value: 8192, child: Text('8192')),
                      DropdownMenuItem(value: 16384, child: Text('16384')),
                    ],
                    onChanged: (v) => setState(() => _bufferSize = v!),
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Enable Data Logging'),
                  subtitle: const Text('Save raw data to disk'),
                  value: false,
                  onChanged: (v) {},
                  activeColor: AppTheme.primary,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Appearance
          _SectionHeader(title: 'Appearance'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Dark Mode'),
                  subtitle: const Text('Industrial dark theme'),
                  value: _darkMode,
                  onChanged: (v) => setState(() => _darkMode = v),
                  activeColor: AppTheme.primary,
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Language'),
                  subtitle: Text(_language == 'zh_CN' ? '简体中文' : 'English'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    setState(() => _language = _language == 'zh_CN' ? 'en_US' : 'zh_CN');
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Plot rendering
          _SectionHeader(title: 'Plot Rendering'),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Anti-Aliasing Level'),
                  subtitle: Text(_aaLevelLabel),
                  trailing: DropdownButton<int>(
                    value: _plotAALevel,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('Off')),
                      DropdownMenuItem(value: 1, child: Text('2×')),
                      DropdownMenuItem(value: 2, child: Text('4×')),
                      DropdownMenuItem(value: 3, child: Text('8×')),
                      DropdownMenuItem(value: 4, child: Text('16×')),
                    ],
                    onChanged: (v) async {
                      if (v != null) {
                        setState(() => _plotAALevel = v);
                        final config = await AppConfig.load();
                        config['plotAALevel'] = v;
                        await AppConfig.save(config);
                      }
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Note'),
                  subtitle: Text(
                    'Higher AA improves line smoothness but increases GPU load. '
                    '4× is recommended for most displays.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                  leading: Icon(Icons.info_outline, size: 16, color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // About
          _SectionHeader(title: 'About'),
          Card(
            child: Column(
              children: [
                const ListTile(title: Text('Version'), trailing: Text('0.1.0-alpha')),
                const Divider(height: 1),
                const ListTile(title: Text('Flutter'), trailing: Text('3.41.7')),
                const Divider(height: 1),
                const ListTile(title: Text('Rust'), trailing: Text('1.95.0')),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Open Source Licenses'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showLicensePage(context: context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: AppTheme.primary)),
    );
  }
}
