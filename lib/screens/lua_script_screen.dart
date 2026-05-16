import 'package:flutter/material.dart';
import 'package:vcr/src/rust/api/lua_api.dart';
import 'package:vcr/src/rust/api/debug_api.dart';

// Lua syntax highlighter
class _LuaSyntaxHighlighter {
  static const _keywords = [
    'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for',
    'function', 'goto', 'if', 'in', 'local', 'nil', 'not', 'or',
    'repeat', 'return', 'then', 'true', 'until', 'while',
  ];
  static const _builtins = [
    'print', 'require', 'ipairs', 'pairs', 'pcall', 'type', 'tostring', 'tonumber',
    'string', 'table', 'math', 'os', 'debug',
    'sys', 'api', 'log',
  ];
  static const _keywordColor = Color(0xFFC678DD);     // purple
  static const _builtinColor = Color(0xFFE5C07B);     // yellow
  static const _commentColor = Color(0xFF5C6370);     // gray
  static const _numberColor  = Color(0xFFD19A66);     // orange

  static TextSpan highlight(String text) {
    final spans = <TextSpan>[];
    final buffer = StringBuffer();
    bool inString = false;
    String? stringChar;
    int i = 0;

    void flush([Color? color]) {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(text: buffer.toString(), style: TextStyle(color: color ?? const Color(0xFFABB2BF))));
      buffer.clear();
    }

    for (;;) {
      if (i >= text.length) { flush(); break; }
      final ch = text[i];

      // comment
      if (!inString && ch == '-' && i + 1 < text.length && text[i + 1] == '-') {
        flush();
        int start = i;
        while (i < text.length && text[i] != '\n') i++;
        spans.add(TextSpan(text: text.substring(start, i), style: const TextStyle(color: _commentColor)));
        continue;
      }

      // string start/end
      if (!inString && (ch == '"' || ch == "'")) {
        flush();
        inString = true;
        stringChar = ch;
        buffer.write(ch);
        i++;
        continue;
      }

      if (inString) {
        buffer.write(ch);
        if (ch == '\\' && i + 1 < text.length) { buffer.write(text[++i]); }
        else if (ch == stringChar) { inString = false; }
        i++;
        continue;
      }

      // identifier
      if (RegExp(r'[a-zA-Z_]').hasMatch(ch)) {
        flush();
        int start = i;
        while (i < text.length && RegExp(r'[a-zA-Z0-9_]').hasMatch(text[i])) i++;
        final word = text.substring(start, i);
        Color? color;
        if (_keywords.contains(word)) color = _keywordColor;
        else if (_builtins.contains(word) || word.startsWith('api') || word.startsWith('sys') || word.startsWith('log')) color = _builtinColor;
        spans.add(TextSpan(text: word, style: TextStyle(color: color ?? const Color(0xFFABB2BF))));
        continue;
      }

      // number
      if (RegExp(r'[0-9]').hasMatch(ch)) {
        flush();
        int start = i;
        while (i < text.length && RegExp(r'[0-9.xX]').hasMatch(text[i])) i++;
        spans.add(TextSpan(text: text.substring(start, i), style: const TextStyle(color: _numberColor)));
        continue;
      }

      buffer.write(ch);
      i++;
    }

    return TextSpan(children: spans);
  }
}

// Syntax-highlighted text controller
class _HighlightedTextEditingController extends TextEditingController {
  _HighlightedTextEditingController(String text) : super(text: text);

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    return TextSpan(style: style?.copyWith(fontFamily: 'monospace', fontSize: 14, height: 1.5, color: const Color(0xFFABB2BF)) ?? const TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.5), children: [_LuaSyntaxHighlighter.highlight(text)]);
  }
}

// Line-numbered + syntax-highlighted editor
class _LineNumberEditor extends StatefulWidget {
  final TextEditingController scriptController;
  final ValueChanged<String> onChanged;

  const _LineNumberEditor({ required this.scriptController, required this.onChanged });

  @override
  State<_LineNumberEditor> createState() => _LineNumberEditorState();
}

class _LineNumberEditorState extends State<_LineNumberEditor> {
  late _HighlightedTextEditingController _controller;
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = _HighlightedTextEditingController(widget.scriptController.text);
    widget.scriptController.addListener(_onExternalChange);
    _controller.addListener(_onInternalChange);
  }

  void _onExternalChange() {
    if (_controller.text != widget.scriptController.text) {
      final sel = _controller.selection;
      _controller.text = widget.scriptController.text;
      if (sel.isValid && sel.start <= _controller.text.length && sel.end <= _controller.text.length) {
        _controller.selection = sel;
      }
      setState(() {});
    }
  }

  void _onInternalChange() {
    if (widget.scriptController.text != _controller.text) {
      widget.scriptController.text = _controller.text;
    }
    widget.onChanged(_controller.text);
  }

  @override
  void dispose() {
    widget.scriptController.removeListener(_onExternalChange);
    _controller.removeListener(_onInternalChange);
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  int get _lineCount => _controller.text.isEmpty ? 1 : '\n'.allMatches(_controller.text).length + 1;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF282C34), borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.grey)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line numbers
          SizedBox(
            width: 50,
            child: Container(
              color: const Color(0xFF1E2127),
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _lineCount,
                itemBuilder: (context, idx) => SizedBox(
                  height: 21,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('${idx + 1}', style: const TextStyle(fontFamily: 'monospace', fontSize: 14, color: Color(0xFF5C6370)))),
                  ),
                ),
              ),
            ),
          ),
          // Divider
          Container(width: 1, color: const Color(0xFF3E4451)),
          // Editor
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollUpdateNotification) {
                  _scrollController.jumpTo(n.metrics.pixels);
                }
                return false;
              },
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.all(8)),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.5, color: Colors.transparent),
                cursorColor: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LuaScriptScreen extends StatefulWidget {
  const LuaScriptScreen({super.key});

  @override
  State<LuaScriptScreen> createState() => _LuaScriptScreenState();
}

class _LuaScriptScreenState extends State<LuaScriptScreen> {
  final _scriptController = TextEditingController();
  final _outputController = TextEditingController();
  final _debugLogController = TextEditingController();
  bool _isRunning = false;
  bool _isPaused = false;
  int _outputTab = 0; // 0=Output, 1=Debug Log

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


  // 轮询日志的后台任务
  Future<void> _pollLogs(int durationMs) async {
    const pollInterval = 200; // 每200ms检查一次
    final endTime = DateTime.now().add(Duration(milliseconds: durationMs));
    while (DateTime.now().isBefore(endTime) && _isRunning && mounted) {
      await Future.delayed(const Duration(milliseconds: pollInterval));
      if (!mounted) break;
      try {
        final logs = luaGetLogs();
        if (logs.isNotEmpty) {
          setState(() {
            for (final log in logs) {
              final withTimestamp = '[${DateTime.now().toString().substring(11, 19)}] $log';
              _outputController.text += '$withTimestamp\n';
              _debugLogController.text += '$withTimestamp\n';
            }
          });
        }
      } catch (e) {
        // 忽略轮询中的错误
      }
    }
  }

  Future<void> _runScript() async {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
      _outputTab = 1; // 切换到调试日志标签页
    });
    final script = _scriptController.text;
    try {
      luaClearLogs();
      _debugLogController.text = '=== Script started at ${DateTime.now()} ===\n';
      final result = luaExecuteScript(script: script);
      final logs = luaGetLogs();
      setState(() {
        _outputController.text += '> Running script...\n';
        for (final log in logs) {
          _outputController.text += '$log\n';
          _debugLogController.text += '$log\n';
        }
        if (result) {
          _outputController.text += '--- Done ---\n';
          _debugLogController.text += '--- Main script done, polling for async logs... ---\n';
        } else {
          _outputController.text += 'Execution failed.\n';
          _debugLogController.text += 'Execution failed.\n';
        }
      });
      // 等待异步定时器回调完成（最多5秒）
      await _pollLogs(5000);
    } catch (e) {
      setState(() {
        final errMsg = 'Error: $e';
        _outputController.text += '$errMsg\n';
        _debugLogController.text += '$errMsg\n';
      });
    } finally {
      setState(() {
        _isRunning = false;
        _debugLogController.text += '=== Script finished at ${DateTime.now()} ===\n';
      });
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
    setState(() {
      _outputController.clear();
      _debugLogController.clear();
    });
  }

  @override
  void dispose() {
    _scriptController.dispose();
    _outputController.dispose();
    _debugLogController.dispose();
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
          // Script editor with line numbers + syntax highlighting
          Expanded(
            flex: 3,
            child: _LineNumberEditor(
              scriptController: _scriptController,
              onChanged: (text) => setState(() {}),
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
          // Tabbed output area
          Expanded(
            flex: 2,
            child: Column(
              children: [
                // Tab bar
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _outputTab = 0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            color: _outputTab == 0 ? Colors.blue[100] : Colors.grey[200],
                            child: const Text(
                              'Output',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _outputTab = 1),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            color: _outputTab == 1 ? Colors.orange[100] : Colors.grey[200],
                            child: const Text(
                              'Debug Log',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Tab content
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(4)),
                    ),
                    child: _outputTab == 0
                        ? TextField(
                            controller: _outputController,
                            maxLines: null,
                            expands: true,
                            readOnly: true,
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.all(8),
                            ),
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                          )
                        : TextField(
                            controller: _debugLogController,
                            maxLines: null,
                            expands: true,
                            readOnly: true,
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.all(8),
                            ),
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.orange),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
