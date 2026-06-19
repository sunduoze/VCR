/// Multi-send item model for the Console multi-string send panel.
class MultiSendItem {
  /// Unique identifier (persisted across saves).
  final String id;

  /// Display label on the send button (editable inline).
  String label;

  /// The actual command string to send.
  String command;

  /// If true, send as HEX (checkbox in the HEX column).
  bool isHex;

  /// Execution order: 0 = no order (send immediately on batch send),
  /// 1–999 = ordered execution (lower number sends first).
  int order;

  /// Delay in milliseconds after sending this item before sending the next.
  int delayMs;

  MultiSendItem({
    String? id,
    this.label = '',
    this.command = '',
    this.isHex = false,
    this.order = 0,
    this.delayMs = 0,
  }) : id = id ?? DateTime.now().millisecondsSinceEpoch.toString();

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'command': command,
        'isHex': isHex,
        'order': order,
        'delayMs': delayMs,
      };

  factory MultiSendItem.fromJson(Map<String, dynamic> json) => MultiSendItem(
        id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
        label: json['label'] as String? ?? '',
        command: json['command'] as String? ?? '',
        isHex: json['isHex'] as bool? ?? false,
        order: json['order'] as int? ?? 0,
        delayMs: json['delayMs'] as int? ?? 0,
      );
}
