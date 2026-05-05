import 'package:flutter/material.dart';
import 'package:vcr/src/rust/api/lua_api.dart';
import 'package:vcr/src/rust/api/debug_api.dart';

class LuaScriptScreen extends StatefulWidget {
  const LuaScriptScreen({super.key});

  @override
  State<LuaScriptScreen> createState() => _LuaScriptScreenState();
}

class _LuaScriptScreenState extends State<LuaScriptScreen> {
  final _scriptController = TextEditingController();
  final _outputController = TextEditingController();
  bool _isRunning = false;
  bool _isPaused = false;

  // Device selection
  List<(String, String)> _devices = []; // (id, name)
  String? _selectedDeviceId;
  bool _isLoadingDevices = false;

  // Script management
  List<String> _scripts = [];
  String? _selectedScript;
  String? _currentScriptName;
  bool _isLoadingScripts = false;

  @override
  void initState() {
    super.initState();
    _loadDevices();
    _loadScripts();
  }

  Future<void> _loadDevices() async {
    setState(() => _isLoadingDevices = true);
    try {
      final devicePairs = await Future.value(debugGetActiveDeviceNames());
      if (!mounted) return;
      setState(() {
        _devices = devicePairs;
        _isLoadingDevices = false;
        // Auto-select first device if none selected
        if (_selectedDeviceId == null && devicePairs.isNotEmpty) {
          _selectedDeviceId = devicePairs.first.$1;
        }
      });
      if (_selectedDeviceId != null) {
        _setLuaDeviceId(_selectedDeviceId!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _outputController.text += 'Failed to load devices: $e\n';
        _isLoadingDevices = false;
      });
    }
  }

  Future<void> _loadScripts() async {
    setState(() => _isLoadingScripts = true);
    try {
      final scripts = await Future.value(luaGetScriptsList());
      if (!mounted) return;
      setState(() {
        _scripts = scripts;
        _isLoadingScripts = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _outputController.text += 'Failed to load scripts: $e\n';
        _isLoadingScripts = false;
      });
    }
  }

  void _onDeviceChanged(String? deviceId) {
    if (deviceId == null) return;
    setState(() => _selectedDeviceId = deviceId);
    _setLuaDeviceId(deviceId);
  }

  void _setLuaDeviceId(String deviceId) {
    try {
      final success = luaSetDeviceId(deviceId: deviceId);
      if (success) {
        setState(() {
          final deviceName = _devices.where((d) => d.$1 == deviceId).fold<String>(deviceId, (prev, d) => d.$2);
          _outputController.text += 'Device set to: $deviceName\n';
        });
      } else {
        setState(() {
          _outputController.text += 'Failed to set device: $deviceId\n';
        });
      }
    } catch (e) {
      setState(() {
        _outputController.text += 'Error setting device: $e\n';
      });
    }
  }

  void _onScriptSelected(String? scriptName) {
    if (scriptName == null) return;
    try {
      final content = luaLoadScript(name: scriptName);
      setState(() {
        _selectedScript = scriptName;
        _currentScriptName = scriptName;
        _scriptController.text = content;
      });
    } catch (e) {
      setState(() {
        _outputController.text += 'Failed to load script $scriptName: $e\n';
      });
    }
  }

  Future<void> _newScript() async {
    final controller = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Script'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Script name',
            hintText: 'my_script',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (result == true && controller.text.isNotEmpty) {
      final name = controller.text.replaceAll('.lua', '');
      setState(() {
        _currentScriptName = name;
        _scriptController.text = '-- $name\n';
        _outputController.text += 'Created new script: $name\n';
      });
    }
  }

  Future<void> _saveScript() async {
    if (_currentScriptName == null) {
      // Ask for name
      final controller = TextEditingController();
      final result = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Save Script'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Script name',
              hintText: 'my_script',
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (result != true || controller.text.isEmpty) return;
      _currentScriptName = controller.text.replaceAll('.lua', '');
    }

    try {
      final success = luaSaveScript(
        name: _currentScriptName!,
        content: _scriptController.text,
      );
      if (success) {
        setState(() {
          _outputController.text += 'Saved: ${_currentScriptName}.lua\n';
        });
        await _loadScripts();
      } else {
        setState(() {
          _outputController.text += 'Failed to save script\n';
        });
      }
    } catch (e) {
      setState(() {
        _outputController.text += 'Error saving: $e\n';
      });
    }
  }

  Future<void> _deleteScript() async {
    if (_selectedScript == null) return;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Script'),
        content: Text('Delete ${_selectedScript}.lua?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (result == true) {
      try {
        final success = luaDeleteScript(name: _selectedScript!);
        if (success) {
          setState(() {
            _outputController.text += 'Deleted: ${_selectedScript}.lua\n';
            _selectedScript = null;
          });
          await _loadScripts();
        }
      } catch (e) {
        setState(() {
          _outputController.text += 'Error deleting: $e\n';
        });
      }
    }
  }

  void _openScriptsFolder() {
    try {
      final success = luaOpenScriptsFolder();
      if (!success) {
        setState(() {
          _outputController.text += 'Failed to open scripts folder\n';
        });
      }
    } catch (e) {
      setState(() {
        _outputController.text += 'Error opening folder: $e\n';
      });
    }
  }

  Future<void> _runScript() async {
    if (_isRunning) return;
    setState(() => _isRunning = true);
    final script = _scriptController.text;
    try {
      luaClearLogs();
      final result = luaExecuteScript(script: script);
      final logs = luaGetLogs();
      setState(() {
        _outputController.text += '> Running script...\n';
        for (final log in logs) {
          _outputController.text += '$log\n';
        }
        if (result) {
          _outputController.text += '--- Done ---\n';
        } else {
          _outputController.text += 'Execution failed.\n';
        }
      });
    } catch (e) {
      setState(() {
        _outputController.text += 'Error: $e\n';
      });
    } finally {
      setState(() => _isRunning = false);
    }
  }

  void _pauseScript() {
    setState(() {
      _isPaused = !_isPaused;
      _outputController.text += _isPaused ? 'Script paused\n' : 'Script resumed\n';
    });
  }

  void _stopScript() {
    setState(() {
      _isRunning = false;
      _isPaused = false;
      _outputController.text += 'Script stopped\n';
    });
  }

  void _clearOutput() {
    setState(() => _outputController.clear());
  }

  @override
  void dispose() {
    _scriptController.dispose();
    _outputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top toolbar
          Row(
            children: [
              // Device selector
              if (_isLoadingDevices)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                DropdownButton<String>(
                  value: _selectedDeviceId,
                  hint: const Text('Select device'),
                  items: _devices
                      .map((d) => DropdownMenuItem(value: d.$1, child: Text(d.$2)))
                      .toList(),
                  onChanged: _onDeviceChanged,
                ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh devices',
                onPressed: _loadDevices,
              ),
              const SizedBox(width: 16),
              // Script selector
              if (_isLoadingScripts)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                DropdownButton<String>(
                  value: _selectedScript,
                  hint: const Text('Select script'),
                  items: _scripts
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: _onScriptSelected,
                ),
              IconButton(
                icon: const Icon(Icons.folder_open),
                tooltip: 'Open scripts folder',
                onPressed: _openScriptsFolder,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Script management buttons
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: _newScript,
                icon: const Icon(Icons.add),
                label: const Text('New'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _saveScript,
                icon: const Icon(Icons.save),
                label: const Text('Save'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _selectedScript != null ? _deleteScript : null,
                icon: const Icon(Icons.delete),
                label: const Text('Delete'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red[50],
                  foregroundColor: Colors.red,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _loadScripts,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Script editor
          Expanded(
            flex: 3,
            child: TextField(
              controller: _scriptController,
              maxLines: null,
              expands: true,
              decoration: InputDecoration(
                labelText: _currentScriptName != null
                    ? 'Lua Script: ${_currentScriptName}.lua'
                    : 'Lua Script',
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            ),
          ),
          const SizedBox(height: 8),
          // Run controls
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: _isRunning ? null : _runScript,
                icon: _isRunning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: const Text('Run'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _isRunning ? _pauseScript : null,
                icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
                label: Text(_isPaused ? 'Resume' : 'Pause'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _isRunning ? _stopScript : null,
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _clearOutput,
                icon: const Icon(Icons.clear_all),
                label: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Output area
          Expanded(
            flex: 2,
            child: TextField(
              controller: _outputController,
              maxLines: null,
              expands: true,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Output',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
