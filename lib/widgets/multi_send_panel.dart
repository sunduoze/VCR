import 'dart:async';

import 'dart:convert';

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:gbk_codec/gbk_codec.dart';

import '../app/theme.dart';

import '../models/multi_send_item.dart';

import '../src/rust/api/debug_api.dart';

/// Multi-string send panel for the Console screen.
///
/// Features:
/// - Inline command editing (TextField, persisted controller)
/// - Send button shows label (right-click to edit), max ~10 Chinese chars visual width
/// - HEX / Order / Delay columns
/// - Batch send with order support (0=immediate first, 1-999=ordered)
/// - Auto-saves to %APPDATA%\VCR\multi_send_items.json
/// - Drag-to-reorder via ReorderableListView

class MultiSendPanel extends StatefulWidget {
  final String? deviceId;
  final bool connected;
  final List<MultiSendItem> items;
  final ValueChanged<List<MultiSendItem>> onItemsChanged;
  final String encoding;
  final String lineEnding;

  const MultiSendPanel({
    super.key,
    this.deviceId,
    required this.connected,
    required this.items,
    required this.onItemsChanged,
    this.encoding = 'utf-8',
    this.lineEnding = '\n',
  });

  @override
  State<MultiSendPanel> createState() => _MultiSendPanelState();
}

class _MultiSendPanelState extends State<MultiSendPanel> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, TextEditingController> _cmdControllers = {};
  final Map<String, TextEditingController> _orderControllers = {};
  final Map<String, TextEditingController> _delayControllers = {};
  File? _configFile;

  bool _batchSending = false;
  int _batchSentCount = 0;
  int _batchTotal = 0;
  int _batchLoopCount = 0;

  Timer? _saveDebounce;
  Timer? _batchUiTimer;

  @override
  void initState() {
    super.initState();
    _syncControllers();
    _loadItems();
  }

  @override
  void didUpdateWidget(covariant MultiSendPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items != widget.items) {
      _syncControllers();
    }
  }

  /// Sync controllers with current items: add missing, remove orphaned.
  void _syncControllers() {
    final validIds = widget.items.map((e) => e.id).toSet();

    // Remove orphaned controllers
    final toRemove = <String>[];
    for (final entry in _cmdControllers.entries) {
      if (!validIds.contains(entry.key)) {
        entry.value.dispose();
        toRemove.add(entry.key);
      }
    }
    for (final id in toRemove) {
      _cmdControllers.remove(id);
      _orderControllers.remove(id)?.dispose();
      _delayControllers.remove(id)?.dispose();
    }

    // Add missing controllers
    for (final item in widget.items) {
      _cmdControllers.putIfAbsent(
          item.id, () => TextEditingController(text: item.command));
      _orderControllers.putIfAbsent(
          item.id, () => TextEditingController(text: '${item.order}'));
      _delayControllers.putIfAbsent(
          item.id, () => TextEditingController(text: '${item.delayMs}'));
    }
  }

  Future<void> _loadItems() async {
    final appData = Platform.environment['APPDATA'] ?? '';
    if (appData.isEmpty) return;
    _configFile = File('$appData\\VCR\\multi_send_items.json');
    if (_configFile == null) return;
    try {
      if (await _configFile!.exists()) {
        final raw = await _configFile!.readAsString();
        final jsonList = jsonDecode(raw) as List;
        final loaded = jsonList
            .map((j) => MultiSendItem.fromJson(j as Map<String, dynamic>))
            .toList();
        if (loaded.isNotEmpty && mounted) {
          widget.onItemsChanged(loaded);
          _syncControllers();
        }
      }
    } catch (e) {
      debugPrint('MultiSend: failed to load items: $e');
    }
  }

  void _saveItemsDebounced() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), _saveItems);
  }

  Future<void> _saveItems() async {
    if (_configFile == null) return;
    try {
      final dir = _configFile!.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      final jsonList =
          widget.items.map((item) => item.toJson()).toList();
      await _configFile!.writeAsString(jsonEncode(jsonList));
    } catch (e) {
      debugPrint('MultiSend: failed to save items: $e');
    }
  }

  List<int> _encodeCommand(MultiSendItem item) {
    String text = item.command.trim();
    if (text.isEmpty) return [];
    if (item.isHex) {
      final cleaned = text.replaceAll(RegExp(r'\s+'), '');
      if (cleaned.length % 2 != 0) return [];
      final bytes = <int>[];
      for (int i = 0; i < cleaned.length; i += 2) {
        final byte = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
        if (byte == null) return [];
        bytes.add(byte);
      }
      return bytes;
    }
    // Text mode: append line ending then encode
    final encoded = '$text${widget.lineEnding}';
    if (widget.encoding.toLowerCase() == 'gbk') {
      try {
        return gbk.encode(encoded);
      } catch (_) {
        return utf8.encode(encoded);
      }
    }
    return utf8.encode(encoded);
  }

  void _sendSingle(MultiSendItem item) {
    if (widget.deviceId == null || !widget.connected) return;
    final bytes = _encodeCommand(item);
    if (bytes.isEmpty) return;
    debugSendBytes(deviceId: widget.deviceId!, data: bytes);
  }

  Future<void> _batchSend() async {
    if (widget.deviceId == null || !widget.connected) return;

    final active = widget.items
        .where((e) => e.command.trim().isNotEmpty && e.order != 0)
        .toList();
    if (active.isEmpty) return;

    active.sort((a, b) {
      if (a.order == 0 && b.order == 0) return 0;
      if (a.order == 0) return -1;
      if (b.order == 0) return 1;
      return a.order.compareTo(b.order);
    });

    setState(() {
      _batchSending = true;
      _batchSentCount = 0;
      _batchTotal = active.length;
    });

    // Throttle UI updates to at most every 200ms to avoid chaos
    _batchUiTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() {});
    });

    _batchLoopCount = 0;
    while (_batchSending) {
      _batchLoopCount++;
      for (final item in active) {
        if (!_batchSending) break;
        final bytes = _encodeCommand(item);
        if (bytes.isNotEmpty && widget.deviceId != null) {
          debugSendBytes(deviceId: widget.deviceId!, data: bytes);
        }
        _batchSentCount++;
        final delay = item.delayMs >= 0 ? item.delayMs : 50;
        if (delay > 0) {
          await Future.delayed(Duration(milliseconds: delay));
          if (!mounted) {
            _batchUiTimer?.cancel();
            return;
          }
        }
      }
      _batchSentCount = 0; // Reset for next loop
    }

    _batchUiTimer?.cancel();
    if (mounted) {
      setState(() {
        _batchSending = false;
        _batchLoopCount = 0;
      });
    }
  }

  void _cancelBatch() {
    _batchUiTimer?.cancel();
    setState(() {
      _batchSending = false;
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex -= 1;
    final updated = List<MultiSendItem>.from(widget.items);
    final item = updated.removeAt(oldIndex);
    updated.insert(newIndex, item);
    widget.onItemsChanged(updated);
    _saveItemsDebounced();
    if (mounted) setState(() {});
  }

  String _getButtonText(MultiSendItem item) {
    if (item.label.trim().isNotEmpty) return item.label.trim();
    final text = item.command.trim();
    if (text.isEmpty) return 'Send';
    int visualWidth = 0;
    int truncateAt = text.length;
    for (int i = 0; i < text.length; i++) {
      final code = text.runes.elementAt(i);
      final charWidth = (code > 0x7F || (code >= 0x3000 && code <= 0x9FFF)) ? 2 : 1;
      visualWidth += charWidth;
      if (visualWidth > 20) {
        truncateAt = i;
        break;
      }
      truncateAt = i + 1;
    }
    if (truncateAt < text.length) {
      return '${text.substring(0, truncateAt)}…';
    }
    return text;
  }

  void _editButtonLabel(MultiSendItem item, int index) async {
    final controller = TextEditingController(text: item.label);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Button Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Enter button name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && mounted) {
      final updated = List<MultiSendItem>.from(widget.items);
      updated[index] = MultiSendItem(
        id: item.id,
        label: result,
        command: item.command,
        isHex: item.isHex,
        order: item.order,
        delayMs: item.delayMs,
      );
      widget.onItemsChanged(updated);
      _saveItemsDebounced();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _batchUiTimer?.cancel();
    _saveDebounce?.cancel();
    _scrollController.dispose();
    for (final c in _cmdControllers.values) {
      c.dispose();
    }
    for (final c in _orderControllers.values) {
      c.dispose();
    }
    for (final c in _delayControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          color: AppTheme.surfaceVariant,
          child: Row(
            children: [
              const Text('Multi-Send',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              const Spacer(),
              if (_batchSending) ...[
                SizedBox(
                  width: 80,
                  height: 6,
                  child: LinearProgressIndicator(
                    value: _batchTotal > 0 ? _batchSentCount / _batchTotal : 0,
                    backgroundColor: Colors.grey[700],
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Colors.orange),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _batchTotal > 0
                      ? 'L$_batchLoopCount ${(_batchSentCount * 100 / _batchTotal).toInt()}%'
                      : 'L$_batchLoopCount 0%',
                  style: const TextStyle(fontSize: 11, color: Colors.orange),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 48,
                  height: 24,
                  child: TextButton(
                    onPressed: _cancelBatch,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(48, 24),
                    ),
                    child: const Text('Stop',
                        style: TextStyle(fontSize: 10, color: Colors.red)),
                  ),
                ),
              ] else ...[
                OutlinedButton(
                  onPressed: widget.connected ? _batchSend : null,
                  style: OutlinedButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(0, 32),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                  child: const Text('Send All (∞)'),
                ),
              ],
            ],
          ),
        ),

        // Headers
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          color: AppTheme.surfaceVariant.withAlpha((0.5 * 255).round()),
          child: const Row(children: [
            SizedBox(width: 22),
            SizedBox(width: 30, child: Center(child: Text('HEX', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)))),
            SizedBox(width: 34, child: Center(child: Text('Ord', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)))),
            Expanded(flex: 4, child: Padding(padding: EdgeInsets.only(left: 4), child: Text('Command', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)))),
            SizedBox(width: 54, child: Center(child: Text('Delay(ms)', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold)))),
            SizedBox(width: 72, child: Center(child: Text('Send', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)))),
            SizedBox(width: 20),
          ]),
        ),

        // Rows
        Expanded(
          child: widget.items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.list_alt, size: 40, color: Colors.grey[600]),
                      const SizedBox(height: 8),
                      Text('No items',
                          style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                      const SizedBox(height: 4),
                      Text('Click "+" to add',
                          style: TextStyle(color: Colors.grey[700], fontSize: 11)),
                    ],
                  ),
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  onReorder: _onReorder,
                  itemCount: widget.items.length,
                  itemBuilder: (context, index) {
                    final item = widget.items[index];
                    return _buildRow(item, index, key: ValueKey(item.id));
                  },
                ),
        ),

        // Add/Remove bar
        Container(
          padding: const EdgeInsets.all(6),
          color: AppTheme.surfaceVariant,
          child: Row(children: [
            IconButton(
              onPressed: () {
                final newItem = MultiSendItem(delayMs: 1000);
                final updated = [...widget.items, newItem];
                widget.onItemsChanged(updated);
                _syncControllers();
                _saveItemsDebounced();
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.add, size: 18),
              tooltip: 'Add Row',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
            ),
            IconButton(
              onPressed: widget.items.isEmpty
                  ? null
                  : () {
                      final updated = List<MultiSendItem>.from(widget.items);
                      final removed = updated.removeLast();
                      widget.onItemsChanged(updated);
                      _cmdControllers.remove(removed.id)?.dispose();
                      _orderControllers.remove(removed.id)?.dispose();
                      _delayControllers.remove(removed.id)?.dispose();
                      _saveItemsDebounced();
                      if (mounted) setState(() {});
                    },
              icon: const Icon(Icons.remove, size: 18),
              tooltip: 'Remove Last',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
            ),
            const Spacer(),
            Text('${widget.items.length} items',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
        ),
      ],
    );
  }

  Widget _buildRow(MultiSendItem item, int index, {required Key key}) {
    final cmdCtrl = _cmdControllers[item.id]!;
    final orderCtrl = _orderControllers[item.id]!;
    final delayCtrl = _delayControllers[item.id]!;

    return Container(
      key: key,
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(
                color: AppTheme.border.withAlpha((0.3 * 255).round()))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: Row(children: [
        // Drag handle
        ReorderableDragStartListener(
          index: index,
          child: const SizedBox(
              width: 22, height: 36,
              child: Icon(Icons.drag_handle, size: 14, color: Colors.grey)),
        ),

        // HEX checkbox
        SizedBox(
          width: 30,
          child: Checkbox(
            value: item.isHex,
            onChanged: (v) {
              final updated = List<MultiSendItem>.from(widget.items);
              updated[index] = MultiSendItem(
                id: item.id,
                label: item.label,
                command: item.command,
                isHex: v ?? false,
                order: item.order,
                delayMs: item.delayMs,
              );
              widget.onItemsChanged(updated);
              _saveItemsDebounced();
              if (mounted) setState(() {});
            },
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),

        // Order input
        SizedBox(
          width: 34,
          height: 30,
          child: TextField(
            controller: orderCtrl,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.zero,
              isDense: true,
            ),
            keyboardType: TextInputType.number,
            onChanged: (v) {
              final order = int.tryParse(v) ?? 0;
              final updated = List<MultiSendItem>.from(widget.items);
              updated[index] = MultiSendItem(
                id: item.id,
                label: item.label,
                command: item.command,
                isHex: item.isHex,
                order: order.clamp(0, 999),
                delayMs: item.delayMs,
              );
              widget.onItemsChanged(updated);
              // Keep controller in sync (only if parse result differs from text)
              final expected = '${order.clamp(0, 999)}';
              if (orderCtrl.text != expected) {
                orderCtrl.text = expected;
                orderCtrl.selection = TextSelection.fromPosition(
                    TextPosition(offset: expected.length));
              }
              _saveItemsDebounced();
            },
          ),
        ),

        // Command input
        Expanded(
          flex: 4,
          child: SizedBox(
            height: 30,
            child: TextField(
              controller: cmdCtrl,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                isDense: true,
                hintText: 'Enter command...',
                hintStyle: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
              onChanged: (v) {
                final updated = List<MultiSendItem>.from(widget.items);
                updated[index] = MultiSendItem(
                  id: item.id,
                  label: item.label,
                  command: v,
                  isHex: item.isHex,
                  order: item.order,
                  delayMs: item.delayMs,
                );
                widget.onItemsChanged(updated);
                _saveItemsDebounced();
              },
            ),
          ),
        ),

        // Delay input (ms)
        SizedBox(
          width: 54,
          height: 30,
          child: TextField(
            controller: delayCtrl,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.zero,
              isDense: true,
              hintText: 'ms',
            ),
            keyboardType: TextInputType.number,
            onChanged: (v) {
              final delay = int.tryParse(v) ?? 0;
              final updated = List<MultiSendItem>.from(widget.items);
              updated[index] = MultiSendItem(
                id: item.id,
                label: item.label,
                command: item.command,
                isHex: item.isHex,
                order: item.order,
                delayMs: delay,
              );
              widget.onItemsChanged(updated);
              _saveItemsDebounced();
            },
          ),
        ),

        // Send button
        SizedBox(
          width: 72,
          height: 30,
          child: GestureDetector(
            onSecondaryTap: () => _editButtonLabel(item, index),
            child: ElevatedButton(
              onPressed: widget.connected ? () => _sendSingle(item) : null,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 30),
                backgroundColor: Colors.orange.shade700,
                foregroundColor: Colors.white,
                textStyle: const TextStyle(fontSize: 10),
              ),
              child: Text(
                _getButtonText(item),
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
        ),

        // Delete button
        SizedBox(
          width: 20,
          height: 30,
          child: IconButton(
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.close, size: 14, color: Colors.red),
            onPressed: () {
              final updated = List<MultiSendItem>.from(widget.items);
              final removed = updated.removeAt(index);
              widget.onItemsChanged(updated);
              _cmdControllers.remove(removed.id)?.dispose();
              _orderControllers.remove(removed.id)?.dispose();
              _delayControllers.remove(removed.id)?.dispose();
              _saveItemsDebounced();
              if (mounted) setState(() {});
            },
            constraints: const BoxConstraints(minWidth: 20, minHeight: 30),
            tooltip: 'Remove',
          ),
        ),
      ]),
    );
  }
}
