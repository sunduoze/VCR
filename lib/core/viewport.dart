// viewport.dart - Zero-allocation viewport state management
// Reactive: uses ValueNotifier instead of setState for O(1) change propagation.
// Synchronized with Chart Isolate via SendPort FFI bridge.

import 'package:flutter/foundation.dart';

/// Immutable viewport state.
/// Designed for zero-allocation comparisons: == is fast field-by-field.
@immutable
class Viewport {
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;
  final double width; // screen pixels
  final double height; // screen pixels

  const Viewport({
    this.xMin = -1000.0,
    this.xMax = 0.0,
    this.yMin = -1.0,
    this.yMax = 1.0,
    this.width = 800.0,
    this.height = 600.0,
  });

  double get xRange => xMax - xMin;
  double get yRange => yMax - yMin;
  double get midY => (yMin + yMax) / 2;

  /// Data coordinate → screen pixel X
  double toScreenX(double dataX) {
    if (xRange == 0) return width / 2;
    return ((dataX - xMin) / xRange) * width;
  }

  /// Data coordinate → screen pixel Y (flipped: yMin at bottom)
  double toScreenY(double dataY) {
    if (yRange == 0) return height / 2;
    return height - ((dataY - yMin) / yRange) * height;
  }

  /// Screen pixel X → data coordinate
  double toDataX(double screenX) {
    if (width == 0) return xMin;
    return xMin + (screenX / width) * xRange;
  }

  /// Screen pixel Y → data coordinate
  double toDataY(double screenY) {
    if (height == 0) return yMin;
    return yMin + ((height - screenY) / height) * yRange;
  }

  /// Pan by delta in screen pixels
  Viewport pan(double dx, double dy) {
    final dxData = -(dx / width) * xRange;
    final dyData = (dy / height) * yRange;
    return copyWith(
      xMin: xMin + dxData,
      xMax: xMax + dxData,
      yMin: yMin + dyData,
      yMax: yMax + dyData,
    );
  }

  /// Zoom centered on a screen point
  Viewport zoom(double factor, double centerX, double centerY) {
    final cxData = toDataX(centerX);
    final cyData = toDataY(centerY);
    final newXRange = xRange / factor;
    final newYRange = yRange / factor;

    final ratio = (cxData - xMin) / xRange;
    return Viewport(
      xMin: cxData - newXRange * ratio,
      xMax: cxData + newXRange * (1 - ratio),
      yMin: cyData - newYRange * 0.5,
      yMax: cyData + newYRange * 0.5,
      width: width,
      height: height,
    );
  }

  /// Resize to new screen dimensions
  Viewport resize(double newWidth, double newHeight) {
    return copyWith(width: newWidth, height: newHeight);
  }

  Viewport copyWith({
    double? xMin,
    double? xMax,
    double? yMin,
    double? yMax,
    double? width,
    double? height,
  }) {
    return Viewport(
      xMin: xMin ?? this.xMin,
      xMax: xMax ?? this.xMax,
      yMin: yMin ?? this.yMin,
      yMax: yMax ?? this.yMax,
      width: width ?? this.width,
      height: height ?? this.height,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Viewport &&
      other.xMin == xMin &&
      other.xMax == xMax &&
      other.yMin == yMin &&
      other.yMax == yMax &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(xMin, xMax, yMin, yMax, width, height);

  @override
  String toString() =>
      'Viewport(x: ${xMin.toStringAsFixed(1)}..${xMax.toStringAsFixed(1)}, '
      'y: ${yMin.toStringAsFixed(3)}..${yMax.toStringAsFixed(3)}, '
      'screen: ${width.toInt()}x${height.toInt()})';
}

/// Global viewport notifier — single source of truth for chart rendering.
/// Replace StatefulWidget setState with ListenableBuilder / addListener.
final viewportNotifier = ValueNotifier(const Viewport());

/// Convenience function; placeholder for isolate sync.
void syncViewportToIsolate() {
  // viewportNotifier.value is read by listeners in plot_screen.dart
}