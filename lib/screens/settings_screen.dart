import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../app/theme.dart';
import '../src/rust/frb_generated.dart';

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
    } catch (e) {
      debugPrint('Failed to load app config: $e');
    }
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
    } catch (e) {
      debugPrint('Failed to save app config: $e');
    }
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
  int _plotAALevel = 0; // 0=off, 1=2x, 2=4x, 3=8x, 4=16x
  String _logLevel = 'info'; // trace, debug, info, warn, error, off
  String _logPath = ''; // empty = default (next to executable)
  bool _fileLoggingEnabled = true; // enable/disable file logging

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
        _logLevel = config['logLevel'] as String? ?? 'info';
        _logPath = config['logPath'] as String? ?? '';
        _fileLoggingEnabled = config['fileLoggingEnabled'] as bool? ?? true;
      });
    }
  }

  String get _aaLevelLabel {
    switch (_plotAALevel) {
      case 0:
        return 'Off';
      case 1:
        return '2×';
      case 2:
        return '4×';
      case 3:
        return '8×';
      case 4:
        return '16×';
      default:
        return 'Off';
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
                  subtitle: const Text(
                    'Reconnect previously connected devices when app starts',
                  ),
                  value: _autoReconnect,
                  onChanged: _saveAutoReconnect,
                  activeThumbColor: AppTheme.primary,
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
                      onChanged: (v) =>
                          setState(() => _samplingRate = v.round()),
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
                  activeThumbColor: AppTheme.primary,
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
                  activeThumbColor: AppTheme.primary,
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Language'),
                  subtitle: Text(_language == 'zh_CN' ? '简体中文' : 'English'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    setState(
                      () =>
                          _language = _language == 'zh_CN' ? 'en_US' : 'zh_CN',
                    );
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
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  leading: Icon(
                    Icons.info_outline,
                    size: 16,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Debug & Logging
          _SectionHeader(title: 'Debug & Logging'),
          Card(
            child: Column(
              children: [
                // File Logging Toggle
                SwitchListTile(
                  title: const Text('File Logging'),
                  subtitle: const Text('Save logs to file'),
                  value: _fileLoggingEnabled,
                  onChanged: (v) async {
                    setState(() => _fileLoggingEnabled = v);
                    final config = await AppConfig.load();
                    config['fileLoggingEnabled'] = v;
                    await AppConfig.save(config);
                    // Apply to Rust logger
                    try {
                      RustLib.instance.api.crateApiDebugApiDebugSetFileLoggingEnabled(enabled: v);
                    } catch (e) {
                      // ignore
                    }
                  },
                  activeThumbColor: AppTheme.primary,
                ),
                const Divider(height: 1),
                // Log Level
                ListTile(
                  title: const Text('Log Level'),
                  subtitle: Text(_logLevel.toUpperCase()),
                  trailing: DropdownButton<String>(
                    value: _logLevel,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 'trace', child: Text('TRACE')),
                      DropdownMenuItem(value: 'debug', child: Text('DEBUG')),
                      DropdownMenuItem(value: 'info', child: Text('INFO')),
                      DropdownMenuItem(value: 'warn', child: Text('WARN')),
                      DropdownMenuItem(value: 'error', child: Text('ERROR')),
                      DropdownMenuItem(value: 'off', child: Text('OFF')),
                    ],
                    onChanged: (v) async {
                      if (v != null) {
                        setState(() => _logLevel = v);
                        final config = await AppConfig.load();
                        config['logLevel'] = v;
                        await AppConfig.save(config);
                        // Apply to Rust logger
                        try {
                          RustLib.instance.api.crateApiDebugApiDebugSetLogLevel(level: v);
                        } catch (e) {
                          // ignore
                        }
                      }
                    },
                  ),
                ),
                const Divider(height: 1),
                // Log File Path
                ListTile(
                  title: const Text('Log File Path'),
                  subtitle: Text(
                    _logPath.isEmpty ? 'Default (next to executable)' : _logPath,
                    style: const TextStyle(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_logPath.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () async {
                            setState(() => _logPath = '');
                            final config = await AppConfig.load();
                            config['logPath'] = '';
                            await AppConfig.save(config);
                            // Reset to default path
                            try {
                              final exeDir = File(Platform.resolvedExecutable).parent.path;
                              final ts = DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);
                              RustLib.instance.api.crateApiDebugApiDebugSetLogFilePath(path: '$exeDir\\vcr_debug_$ts.log');
                            } catch (e) {
                              // ignore
                            }
                          },
                        ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () => _showLogPathDialog(),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Note'),
                  subtitle: const Text(
                    'TRACE shows all logs including debug traces. '
                    'ERROR shows only errors. Changes apply immediately.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  leading: Icon(
                    Icons.info_outline,
                    size: 16,
                    color: AppTheme.textSecondary,
                  ),
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
                const ListTile(
                  title: Text('Version'),
                  trailing: Text('0.1.0-alpha'),
                ),
                const Divider(height: 1),
                const ListTile(
                  title: Text('Flutter'),
                  trailing: Text('3.41.7'),
                ),
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

  void _showLogPathDialog() {
    final controller = TextEditingController(text: _logPath);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log File Path'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'Leave empty for default path',
                helperText: 'Absolute path or relative to executable',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Examples:\n'
              'C:\\\\Logs\\\\vcr.log (absolute)\\n'
              'logs\\\\mylog.txt (relative)',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final path = controller.text.trim();
              setState(() => _logPath = path);
              final config = await AppConfig.load();
              config['logPath'] = path;
              await AppConfig.save(config);
              // Apply to Rust logger
              try {
                if (path.isNotEmpty) {
                  RustLib.instance.api.crateApiDebugApiDebugSetLogFilePath(path: path);
                } else {
                  final exeDir = File(Platform.resolvedExecutable).parent.path;
                  final ts = DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);
                  RustLib.instance.api.crateApiDebugApiDebugSetLogFilePath(path: '$exeDir\\vcr_debug_$ts.log');
                }
              } catch (e) {
                // ignore
              }
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
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
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(color: AppTheme.primary),
      ),
    );
  }
}
