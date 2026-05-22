import 'package:flutter/material.dart';
import '../app/theme.dart';
import '../src/rust/core/device/models.dart';

class StatusIndicator extends StatelessWidget {
  final DeviceStatus status;
  final double size;
  const StatusIndicator({super.key, required this.status, this.size = 12});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (status) {
      case DeviceStatus.connected:
        color = AppTheme.success;
        break;
      case DeviceStatus.connecting:
        color = AppTheme.warning;
        break;
      case DeviceStatus.error:
        color = AppTheme.error;
        break;
      case DeviceStatus.disconnected:
        color = AppTheme.textSecondary;
        break;
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: status == DeviceStatus.connected
            ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6)]
            : null,
      ),
    );
  }
}
